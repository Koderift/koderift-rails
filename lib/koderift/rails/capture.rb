# frozen_string_literal: true

require 'json'
require 'time'
require 'koderift/rails/event'
require 'koderift/rails/scope'
require 'koderift/rails/breadcrumb'
require 'koderift/rails/lograge_config'

module Koderift
  module Rails
    # Emits a manually reported error, message or transaction as one JSON line
    # on Rails.logger, which the koderift-agent tails and parses. See
    # LogAgent::Parser#parse_capture_line for the reading end.
    module Capture
      MAX_MESSAGE     = 2_000
      MAX_EXCEPTION   = 1_000
      MAX_ERROR_CAUSE = 1_000
      MAX_CONTEXT     = 4_500

      DEFAULT_MESSAGE_CLASS = 'Koderift::Message'

      # Keys that must not appear ANYWHERE in the emitted JSON, at any depth.
      #
      # LogAgent::Parser dispatches on `"controller":`, `"method":` and
      # `"job_class":` occurring anywhere in the line — the regexes are
      # /\A\{.*"controller":/ and friends, not anchored to the top level. So a
      # caller's `tags: { controller: 'x' }` would make an OLDER agent parse the
      # whole capture as a Lograge request line: status 0, duration 0,
      # log_source 'rails'. That silently corrupts the customer's APM
      # throughput, p95 and Apdex, which is far worse than losing one tag.
      # This is also why the payload says `component` and `http_method` rather
      # than `controller` and `method`.
      RESERVED_KEYS = %w[controller method job_class].freeze

      # The shape ErrorFingerprint::EXCEPTION_CLASS_RE accepts as a class. A
      # token that does not match cannot be grouped — the platform pins it to
      # UnknownError, collapsing unrelated errors into one — so a bad token is
      # replaced rather than emitted.
      CLASS_TOKEN_RE = /\A[A-Z][A-Za-z0-9_]*(?:::[A-Z][A-Za-z0-9_]*)*\z/.freeze

      # Sentry's levels on the left, the platform's on the right. A level
      # outside LogAnalyticsQueryService::LOG_LEVELS would produce rows the Log
      # Explorer's level filter cannot select, so :debug and :warning fold
      # rather than pass through.
      LEVELS = {
        'debug' => 'info', 'info' => 'info', 'warning' => 'warn',
        'warn' => 'warn', 'error' => 'error', 'fatal' => 'fatal'
      }.freeze

      # Only these reach the Errors page: error_group_stats filters
      # `level IN ('error','fatal')`. capture_message therefore only synthesises
      # a grouping class at these levels — at :warn/:info the row would carry an
      # exception that nothing could ever group.
      GROUPING_LEVELS = %w[error fatal].freeze

      LOGGER_METHODS = {
        'fatal' => :fatal, 'error' => :error, 'warn' => :warn, 'info' => :info
      }.freeze

      CAPTURED_IVAR  = :@koderift_captured
      LAST_EVENT_KEY = :koderift_last_event_id
      CONTEXT_KEY    = :koderift_context

      # Fixed-window counter shared by every thread in the process.
      #
      # A capture_exception inside a hot loop or a retrying job can emit
      # thousands of lines, and raw log lines are the billing source of truth
      # for a customer's storage quota. Drops are never silent: one warn line
      # when a window starts dropping, one more naming the count when it rolls
      # over.
      class RateLimiter
        WINDOW_SECONDS = 60

        def initialize
          @mutex        = Mutex.new
          @window_start = nil
          @count        = 0
          @dropped      = 0
        end

        # Returns [allowed, warning_or_nil]. The warning is returned rather than
        # logged here so the caller can log it OUTSIDE this mutex — the logger
        # takes a lock of its own, and taking them in a fixed order here would
        # be one more place to get lock ordering wrong.
        def allow(limit)
          limit = limit.to_i if limit
          return [true, nil] if limit.nil? || limit <= 0

          now     = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          warning = nil

          @mutex.synchronize do
            if @window_start.nil? || (now - @window_start) >= WINDOW_SECONDS
              if @dropped.positive?
                warning = "[Koderift] rate limit dropped #{@dropped} capture(s) " \
                          "in the last #{WINDOW_SECONDS}s"
              end
              @window_start = now
              @count        = 0
              @dropped      = 0
            end

            if @count < limit
              @count += 1
              return [true, warning]
            end

            @dropped += 1
            if @dropped == 1
              warning = "[Koderift] capture rate limit of #{limit}/min reached — " \
                        'dropping further captures this minute ' \
                        '(set config.max_captures_per_minute to raise or nil to disable)'
            end
          end

          [false, warning]
        end
      end

      class << self
        # ---------------------------------------------------------------- API

        def exception(error, message: nil, level: :error, tags: nil, extra: nil,
                      user: nil, contexts: nil, fingerprint: nil, backtrace: nil,
                      hint: nil, component: nil, action: nil, user_id: nil, &block)
          return nil unless error.is_a?(Exception)

          Scope.with_temporary(block) do
            token    = class_token(fingerprint || Scope.current.fingerprint)
            natural  = "#{error.class}: #{error.message}"
            exc      = truncate(token ? "#{token}: #{natural}" : natural, MAX_EXCEPTION)
            frames   = backtrace ? LogrageConfig.format_frames(Array(backtrace))
                                 : LogrageConfig.format_backtrace(error)

            dispatch(
              level: level, exception: exc, message: message || natural,
              stack_trace: frames, error_cause: error.cause&.message,
              error: error, tags: tags, extra: extra, user: user,
              contexts: contexts, component: component, action: action,
              user_id: user_id, hint: hint
            )
          end
        rescue StandardError => e
          swallow(e)
        end

        def message(text, level: :info, name: nil, fingerprint: nil, tags: nil,
                    extra: nil, user: nil, contexts: nil, backtrace: nil, hint: nil,
                    component: nil, action: nil, user_id: nil, &block)
          Scope.with_temporary(block) do
            normalised = normalise_level(level)
            exc = nil

            if GROUPING_LEVELS.include?(normalised)
              token = class_token(fingerprint || name || Scope.current.fingerprint) ||
                      DEFAULT_MESSAGE_CLASS
              exc = truncate("#{token}: #{text}", MAX_EXCEPTION)
            end

            dispatch(
              level: level, exception: exc, message: text,
              stack_trace: backtrace ? LogrageConfig.format_frames(Array(backtrace)) : nil,
              error_cause: nil, error: nil, tags: tags, extra: extra, user: user,
              contexts: contexts, component: component, action: action,
              user_id: user_id, hint: hint
            )
          end
        rescue StandardError => e
          swallow(e)
        end

        # Re-emits an Event returned by an earlier capture, keeping its
        # event_id so the two lines correlate rather than looking unrelated.
        def event(evt)
          return nil unless evt.is_a?(Event)

          dispatch(
            level: evt.level, exception: evt.exception, message: evt.message,
            stack_trace: nil, error_cause: nil, error: nil, tags: nil, extra: nil,
            user: nil, contexts: nil, component: nil, action: nil, user_id: nil,
            hint: nil, event_id: evt.event_id
          )
        rescue StandardError => e
          swallow(e)
        end

        # Emits a finished transaction (see Tracing::Transaction#finish). Not
        # sampled: sample_rate is Sentry's ERROR sample rate, and silently
        # dropping units of work would make the APM view lie about throughput.
        def transaction(component:, action:, message:, duration_ms:, request_id:,
                        trace_id:, result:, level: 'info')
          return nil unless initialized?

          allowed, warning = rate_limiter.allow(configuration.max_captures_per_minute)
          log_warning(warning)
          return nil unless allowed

          event_id   = Event.generate_id
          normalised = normalise_level(level)

          payload = base_payload(
            event_id: event_id, level: normalised, exception: nil, message: message,
            stack_trace: nil, error_cause: nil, tags: nil, extra: nil, user: nil,
            contexts: nil, component: component, action: action, user_id: nil
          ).merge(
            duration:      duration_ms,
            spans:         result[:spans],
            query_count:   result[:query_count],
            partial_count: result[:partial_count],
            search_count:  result[:search_count]
          )

          payload[:request_id]  = request_id
          payload[:trace_id]    = trace_id
          payload[:breadcrumbs] = result[:breadcrumbs] if result[:breadcrumbs]

          emit(payload.compact, normalised)
          Event.new(event_id: event_id, level: normalised, message: message,
                    exception: nil, timestamp: Time.now.utc.iso8601)
        rescue StandardError => e
          swallow(e)
        end

        def initialized?
          config = configuration
          config.enabled && !config.project_token.to_s.empty?
        end

        def last_event_id
          Thread.current[LAST_EVENT_KEY]
        end

        def exception_captured?(error)
          return false unless error.is_a?(Exception)

          error.instance_variable_defined?(CAPTURED_IVAR)
        rescue StandardError
          false
        end

        def rate_limiter
          @rate_limiter ||= RateLimiter.new
        end

        def reset_rate_limiter!
          @rate_limiter = RateLimiter.new
        end

        # ------------------------------------------------------------ internal

        private

        def configuration
          Koderift::Rails.configuration
        end

        def dispatch(level:, exception:, message:, stack_trace:, error_cause:, error:,
                     tags:, extra:, user:, contexts:, component:, action:, user_id:,
                     hint:, event_id: nil)
          return nil unless initialized?

          if error
            return nil if excluded?(error)
            return nil if exception_captured?(error)
          end

          return nil unless sampled?

          allowed, warning = rate_limiter.allow(configuration.max_captures_per_minute)
          log_warning(warning)
          return nil unless allowed

          event_id ||= Event.generate_id
          normalised = normalise_level(level)

          payload = base_payload(
            event_id: event_id, level: normalised, exception: exception,
            message: message, stack_trace: stack_trace, error_cause: error_cause,
            tags: tags, extra: extra, user: user, contexts: contexts,
            component: component, action: action, user_id: user_id
          )

          crumbs = Breadcrumbs.current
          payload[:breadcrumbs] = crumbs unless crumbs.empty?

          payload = run_before_send(payload.compact, hint)
          return nil if payload.nil?

          return nil unless emit(payload, normalised)

          mark_captured(error) if error
          Thread.current[LAST_EVENT_KEY] = event_id

          Event.new(event_id: event_id, level: normalised, message: message.to_s,
                    exception: exception, timestamp: Time.now.utc.iso8601)
        end

        # `koderift_capture` is deliberately the FIRST key: it lets the agent's
        # marker regex match on the shortest possible prefix, and it keeps the
        # line self-identifying for anyone reading the raw log.
        def base_payload(event_id:, level:, exception:, message:, stack_trace:,
                         error_cause:, tags:, extra:, user:, contexts:,
                         component:, action:, user_id:)
          scope   = Scope.current
          ambient = Thread.current[CONTEXT_KEY] || {}

          merged_user = scope.user.merge(stringify(user))

          {
            koderift_capture: 1,
            level:            level,
            exception:        presence(exception),
            message:          truncate(message.to_s, MAX_MESSAGE),
            stack_trace:      presence(stack_trace),
            error_cause:      presence(truncate(error_cause.to_s, MAX_ERROR_CAUSE)),
            component:        presence(component || scope.component || ambient[:component]),
            action:           presence(action || scope.action || ambient[:action]),
            request_id:       presence(ambient[:request_id]),
            trace_id:         presence(Thread.current[:koderift_trace_id]),
            user_id:          presence(resolve_user_id(user_id, merged_user, ambient)),
            path:             presence(ambient[:path]),
            http_method:      presence(ambient[:http_method]),
            context:          build_context(event_id, scope, tags, extra,
                                            contexts, merged_user)
          }
        end

        def build_context(event_id, scope, tags, extra, contexts, merged_user)
          merged_tags     = scope.tags.merge(stringify(tags))
          merged_extra    = scope.extras.merge(stringify(extra))
          merged_contexts = scope.contexts.merge(stringify(contexts))

          context = { 'event_id' => event_id }
          context['tags']     = merged_tags     unless merged_tags.empty?
          context['extra']    = merged_extra    unless merged_extra.empty?
          context['contexts'] = merged_contexts unless merged_contexts.empty?
          context['user']     = merged_user     unless merged_user.empty?

          fit(scrub(context))
        end

        # Removes reserved keys and anything matching config.filter_params, at
        # every depth — a password nested three hashes deep is still a password,
        # and a reserved key nested three hashes deep still breaks old agents.
        def scrub(value)
          case value
          when Hash
            value.each_with_object({}) do |(k, v), out|
              key = k.to_s
              next if RESERVED_KEYS.include?(key)
              next if filtered_key?(key)

              out[key] = scrub(v)
            end
          when Array
            value.map { |v| scrub(v) }
          else
            value
          end
        end

        def filtered_key?(key)
          configuration.filter_params.any? { |f| key.match?(/#{Regexp.escape(f)}/i) }
        rescue StandardError
          false
        end

        # Drops KEYS to fit the budget, never characters. Truncating serialised
        # JSON would leave the log line unparseable, and the agent parses the
        # line as one unit — so an oversized context would not lose its tail,
        # it would lose the entire capture.
        def fit(context)
          return context if JSON.generate(context).bytesize <= MAX_CONTEXT

          reduced = { 'event_id' => context['event_id'], 'truncated' => true }
          return reduced unless context['tags']

          with_tags = reduced.merge('tags' => context['tags'])
          JSON.generate(with_tags).bytesize <= MAX_CONTEXT ? with_tags : reduced
        rescue StandardError
          { 'event_id' => context['event_id'] }
        end

        def resolve_user_id(explicit, merged_user, ambient)
          return explicit.to_s unless explicit.nil?
          return merged_user['id'].to_s unless merged_user['id'].nil?

          controller = ambient[:controller_instance]
          return nil unless controller

          user = begin
            configuration.current_user.call(controller)
          rescue StandardError
            nil
          end
          user.respond_to?(:id) ? user.id.to_s : nil
        rescue StandardError
          nil
        end

        def excluded?(error)
          excluded = configuration.excluded_exceptions
          return false if excluded.nil? || excluded.empty?

          ancestors = error.class.ancestors.map { |a| a.name.to_s }
          excluded.any? { |name| ancestors.include?(name.to_s) }
        rescue StandardError
          false
        end

        def sampled?
          rate = configuration.sample_rate.to_f
          return true  if rate >= 1.0
          return false if rate <= 0.0

          Kernel.rand < rate
        end

        # A raising before_send emits the ORIGINAL payload rather than dropping
        # it. A bug in a user callback must not silently blind their error
        # reporting — that failure would look exactly like "nothing went wrong".
        def run_before_send(payload, hint)
          callback = configuration.before_send
          return payload unless callback.respond_to?(:call)

          result = callback.call(payload, hint)
          result.is_a?(Hash) ? result : nil
        rescue StandardError => e
          log_warning("[Koderift] before_send raised #{e.class}: #{e.message} — " \
                      'emitting the capture unmodified')
          payload
        end

        def emit(payload, level)
          logger = rails_logger
          return false unless logger

          logger.public_send(LOGGER_METHODS.fetch(level, :info), JSON.generate(payload))
          true
        rescue StandardError
          false
        end

        def mark_captured(error)
          error.instance_variable_set(CAPTURED_IVAR, true)
        rescue StandardError
          nil
        end

        def class_token(value)
          return nil if value.nil?

          parts = Array(value).map(&:to_s).reject(&:empty?)
          return nil if parts.empty?
          return parts.first if parts.size == 1 && CLASS_TOKEN_RE.match?(parts.first)

          token = camelize(parts.join('_'))
          CLASS_TOKEN_RE.match?(token) ? token : nil
        end

        def camelize(str)
          str.gsub(/[^A-Za-z0-9_]+/, '_')
             .split('_')
             .reject(&:empty?)
             .map { |w| w[0].upcase + w[1..-1].to_s }
             .join
        end

        def normalise_level(level)
          LEVELS.fetch(level.to_s.downcase, 'error')
        end

        def stringify(hash)
          return {} unless hash.respond_to?(:each_pair)

          hash.each_with_object({}) { |(k, v), out| out[k.to_s] = v }
        end

        def truncate(value, limit)
          str = value.to_s
          str.length > limit ? str[0, limit] : str
        end

        def presence(value)
          str = value.to_s
          str.empty? ? nil : value
        end

        def rails_logger
          return nil unless defined?(::Rails) && ::Rails.respond_to?(:logger)

          ::Rails.logger
        end

        def log_warning(message)
          return if message.nil?

          rails_logger&.warn(message)
        rescue StandardError
          nil
        end

        # A capture must never take down the code it is reporting from. The
        # whole point is that it sits in a rescue block that was already
        # handling a bad day.
        def swallow(error)
          log_warning("[Koderift] capture failed: #{error.class}: #{error.message}")
          nil
        end
      end
    end
  end
end
