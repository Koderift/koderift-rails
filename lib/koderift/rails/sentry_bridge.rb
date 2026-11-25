# frozen_string_literal: true

require 'securerandom'
require 'koderift/rails/trace_context'
require 'koderift/rails/rescue_context'

module Koderift
  module Rails
    # For apps that run sentry-ruby as well as this gem: puts the keys Koderift
    # pairs on into Sentry's error events, so an error reported both ways
    # counts once and an SDK error can link to the Koderift trace.
    #
    # Koderift pairs an SDK event with a log line by one key, the first
    # non-empty of the `jid`, `provider_job_id` and `request_id` tags, plus the
    # raised class. This adds, only when absent and never past 50 tags:
    #
    # * `request_id`: the gem's request ID, or the rake run ID;
    # * `koderift_trace_id` / `koderift_span_id`: the gem's W3C trace and span.
    #
    # Nothing here requires sentry-ruby or references ::Sentry outside a method
    # body. Apps without sentry-ruby, and apps where it is loaded but not
    # initialised, never install anything.
    #
    # Which unit an event belongs to, first rule that applies:
    #
    # 1. A unit live on this thread whose request ID is the event's key, or
    #    any live unit when the event has no key. This is what the gem's own
    #    capture line at the same point carries. Inside a controller's
    #    rescue_from handler the request counts as live (RescueContext).
    # 2. A job key (jid, provider_job_id): the job that last finished on this
    #    thread, when its jid is the key and Sentry reports on the hub that
    #    job ran on. sentry-sidekiq reports from Sidekiq's error handlers,
    #    after the gem's middleware has finished, and gives every attempt its
    #    own hub, so a retry that failed before reaching the gem's middleware
    #    is not taken for the attempt before it.
    # 3. A request key: the request in the Rack env Sentry is reporting, when
    #    its request ID is the key and no other request is live on this
    #    fiber. sentry-rails reports from Rack middleware, after the
    #    controller has finished; the env still holds the trace and span the
    #    controller logged. A request that failed before the controller ran
    #    has none, and gets nothing.
    # 4. No key and no live unit, in a rake run: the rake run ID.
    #
    # Rules 2 and 3 never supply a key: an event whose key names another unit
    # gets nothing. The finished job is held in Thread.current, the same
    # per-thread (and per-fiber) storage the gem keeps its trace in, so
    # concurrent Sidekiq threads never see each other's; a request is read
    # from its own env.
    module SentryBridge
      # Koderift keeps an SDK event's first 50 tags (ErrorEvent::MAX_TAGS).
      MAX_TAGS = 50

      REQUEST_ID_TAG = 'request_id'
      TRACE_ID_TAG   = 'koderift_trace_id'
      SPAN_ID_TAG    = 'koderift_span_id'

      CONTEXT_KEY      = :koderift_context
      CLOSED_JID       = :koderift_closed_jid
      CLOSED_TRACE_ID  = :koderift_closed_trace_id
      CLOSED_SPAN_ID   = :koderift_closed_span_id
      CLOSED_HUB_ID    = :koderift_closed_hub_id

      # Where Controller leaves the request's trace (request.env).
      ENV_REQUEST_ID = 'action_dispatch.request_id'
      ENV_TRACE_ID   = 'koderift.trace_id'
      ENV_SPAN_ID    = 'koderift.span_id'

      # `jobs:work[2]` is the task `jobs:work`.
      TASK_ARGS_RE = /\[.*\z/m.freeze

      INSTALL_MUTEX = Mutex.new
      RAKE_MUTEX    = Mutex.new

      @installed   = false
      @added       = false
      @gave_up     = false
      @rake_run_id = nil

      # sentry-ruby drops an event whose processor raises (7.x returns nil from
      # safe_dispatch_callback; 5.x's Client#capture_event rescues and returns
      # nil), so the rescue here is what keeps an internal error from losing
      # the app's event. The event always comes back.
      PROCESSOR = lambda do |event, hint|
        begin
          SentryBridge.process(event, hint)
        rescue StandardError
          nil
        end
        event
      end

      class << self
        def installed?
          @installed ? true : false
        end

        # Installed, and the gem itself is on: enabled, a project token, and
        # config.sentry_bridge. Read on every use, so switching any of them
        # off later stops the tags, the rake run ID and the recording.
        def active?
          @installed ? configured? : false
        rescue StandardError
          false
        end

        # Registers the processor once Sentry is initialised. Called after the
        # app's initializers and again, cheaply, at the start of each request,
        # job and rake failure, in case Sentry is initialised later (Puma's
        # on_worker_boot, a Sidekiq configure_server block, a task body).
        #
        # Never more than one processor is registered. If something clears
        # Sentry's list (Sentry::TestHelper#teardown_sentry_test does), the
        # next call adds it back; if an add does not stick, or raises, it
        # gives up for good rather than trying on every request.
        def install_if_ready
          return true if @installed && registered?

          install unless @gave_up
          installed?
        rescue StandardError
          installed?
        end

        # @api private
        def process(event, _hint)
          return unless active? && error_event?(event)

          tags = event.tags
          return unless tags.is_a?(Hash)

          room = MAX_TAGS - tags.size
          return unless room.positive?

          # The key Koderift will pair this event on: the first non-empty of
          # the jid, provider_job_id and request_id tags, as String or Symbol.
          job_key = key_value(tags, 'jid', :jid) || key_value(tags, 'provider_job_id', :provider_job_id)
          key     = job_key || key_value(tags, 'request_id', :request_id)
          thread  = Thread.current
          handler = RescueContext.current
          context = handler ? RescueContext.context : thread[CONTEXT_KEY]
          live    = context.is_a?(Hash) ? present_string(context[:request_id]) : nil

          if context.is_a?(Hash) && (key.nil? || key == live)
            request_id = live
            if handler
              # A rescue_from handler: the request has closed, and the trace
              # and span are the ones its request line carries.
              trace_id = RescueContext.trace_id(handler)
              span_id  = RescueContext.span_id(handler)
            else
              trace_id = TraceContext::Current.trace_id
              span_id  = TraceContext::Current.current_span_id
            end
          elsif job_key
            return unless job_key == thread[CLOSED_JID]

            hub_id = current_hub_id
            return unless hub_id && hub_id == thread[CLOSED_HUB_ID]

            request_id = job_key
            trace_id   = thread[CLOSED_TRACE_ID]
            span_id    = thread[CLOSED_SPAN_ID]
          elsif key
            # A request live on this fiber that the key does not name: Sentry's
            # scope holds another request's env (a reused thread's stale hub, or
            # a hub shared across fibers). Only the controller's context has
            # :controller_instance, so a capture inside a transaction still
            # reads its request's env.
            return if context.is_a?(Hash) && context.key?(:controller_instance)

            env = reported_rack_env
            return unless env.is_a?(Hash) && env[ENV_REQUEST_ID] == key

            request_id = key
            trace_id   = env[ENV_TRACE_ID]
            span_id    = env[ENV_SPAN_ID]
          elsif !context
            request_id = rake_run_id
            return unless request_id
          else
            return
          end

          # Everything is decided before anything is written, so an error part
          # way through cannot leave the event half-tagged.
          add_request = request_id && !tag?(tags, REQUEST_ID_TAG, :request_id) ? true : false
          room -= 1 if add_request

          valid_trace = TraceContext.valid_trace_id?(trace_id)
          add_trace   = room.positive? && valid_trace && !tag?(tags, TRACE_ID_TAG, :koderift_trace_id)
          room -= 1 if add_trace

          # A span only makes sense next to its own trace, so never beside a
          # trace tag the app set itself.
          own_trace = add_trace || (valid_trace && (tags[TRACE_ID_TAG] || tags[:koderift_trace_id]) == trace_id)
          add_span  = room.positive? && own_trace && TraceContext.valid_span_id?(span_id) &&
                      !tag?(tags, SPAN_ID_TAG, :koderift_span_id)
          return unless add_request || add_trace || add_span

          tags = writable_tags(event, tags)
          tags[REQUEST_ID_TAG] = request_id if add_request
          tags[TRACE_ID_TAG]   = trace_id   if add_trace
          tags[SPAN_ID_TAG]    = span_id    if add_span
          nil
        end

        # Called from SidekiqMiddleware's ensure as the job closes. The jid is
        # the job's request ID, on its line and in sentry-sidekiq's tag. Only
        # strings the job already holds, and the Sentry hub's object ID, are
        # kept: nothing is allocated.
        def record_closed_job(job, trace)
          return unless @installed && active?

          jid = job.is_a?(Hash) ? job['jid'] : nil
          return unless trace.is_a?(Hash)

          hub_id = current_hub_id # first, so a failure leaves no half record
          thread = Thread.current
          thread[CLOSED_JID]      = present_string(jid.nil? ? nil : jid.to_s)
          thread[CLOSED_TRACE_ID] = trace[:trace_id]
          thread[CLOSED_SPAN_ID]  = trace[:span_id]
          thread[CLOSED_HUB_ID]   = hub_id
          nil
        rescue StandardError
          nil
        end

        # One UUID per rake process while the bridge is active, nil otherwise.
        #
        # Rails boots inside the :environment task, after Rake has read its
        # command line and before any task body runs, so per process is per
        # top-level invocation. A process whose top-level task list is empty
        # is not a rake run (sentry-ruby loads rake in every process). A run
        # that includes a long-lived worker task (config.rake_worker_tasks)
        # gets none: one ID for weeks of unrelated errors would let Koderift
        # pair errors that are not the same occurrence.
        def rake_run_id
          return nil unless active?

          memo = @rake_run_id
          if memo.nil?
            memo = RAKE_MUTEX.synchronize do
              @rake_run_id = compute_rake_run_id if @rake_run_id.nil?
              @rake_run_id
            end
          end
          memo || nil
        rescue StandardError
          nil
        end

        # Specs only. Sentry's own processor list is left alone.
        def reset_for_tests!
          INSTALL_MUTEX.synchronize do
            @installed = false
            @added     = false
            @gave_up   = false
          end
          RAKE_MUTEX.synchronize { @rake_run_id = nil }
          thread = Thread.current
          [CLOSED_JID, CLOSED_TRACE_ID, CLOSED_SPAN_ID, CLOSED_HUB_ID].each { |key| thread[key] = nil }
        end

        private

        def configured?
          config = Koderift::Rails.configuration
          token  = config.project_token
          config.enabled && config.sentry_bridge && !token.nil? && !token.to_s.empty? ? true : false
        end

        # The `Sentry = Koderift` shim the migration guide makes possible has
        # no add_global_event_processor, so it never counts as Sentry. A
        # Sentry constant still waiting to be autoloaded (an app's own
        # app/models/sentry.rb under Zeitwerk) is not sentry-ruby, which
        # defines its module when required, and is left unloaded.
        def sentry_ready?
          return false unless defined?(::Sentry)
          return false if Object.autoload?(:Sentry)

          sentry = ::Sentry
          sentry.respond_to?(:add_global_event_processor) &&
            sentry.respond_to?(:initialized?) && sentry.initialized? ? true : false
        end

        # sentry_ready? first: without sentry-ruby it is one constant check.
        def install
          return unless sentry_ready? && configured?

          INSTALL_MUTEX.synchronize do
            unless @installed && registered?
              begin
                unless registered?
                  ::Sentry.add_global_event_processor(&PROCESSOR)
                  @added = true
                end
              rescue StandardError
                @added = false
              end

              if registered?
                @installed = true
              else
                @installed = false
                @gave_up   = true
              end
            end
          end
        end

        def registered?
          list = processor_list
          list.nil? ? (@added ? true : false) : list.include?(PROCESSOR)
        end

        def processor_list
          return nil unless defined?(::Sentry::Scope) && ::Sentry::Scope.respond_to?(:global_event_processors)

          list = ::Sentry::Scope.global_event_processors
          list.is_a?(Array) ? list : nil
        end

        # Error and message events only. Koderift reads nothing else from an
        # envelope, and check-ins skip Sentry's own tag merge.
        def error_event?(event)
          defined?(::Sentry::ErrorEvent) && event.is_a?(::Sentry::ErrorEvent) ? true : false
        end

        # The hub Sentry is capturing on, by identity. object_id is a counter
        # since Ruby 2.7, never reused, so no hub is ever held on to. On a
        # thread with no hub yet, Sentry gives it one, as any Sentry call there
        # would; nil on a thread that has closed Sentry.
        def current_hub_id
          return nil unless ::Sentry.respond_to?(:get_current_hub)

          hub = ::Sentry.get_current_hub
          hub && hub.object_id
        rescue StandardError
          nil
        end

        # The env Sentry's Rack middleware set on the scope it is reporting
        # with (Sentry::Rack::CaptureExceptions, which sentry-rails uses).
        # Scope#dup keeps the same env object, so the capture's own scope and
        # the hub's current scope agree.
        def reported_rack_env
          return nil unless ::Sentry.respond_to?(:get_current_scope)

          scope = ::Sentry.get_current_scope
          scope.respond_to?(:rack_env) ? scope.rack_env : nil
        end

        # Written out rather than looped: this runs on every Sentry event, and
        # a loop allocated on each call.
        def key_value(tags, string_key, symbol_key)
          value = tags[string_key]
          value = tags[symbol_key] if value.nil?
          return nil if value.nil?

          value = value.to_s unless value.is_a?(String)
          value.empty? ? nil : value
        end

        def tag?(tags, string_key, symbol_key)
          tags.key?(string_key) || tags.key?(symbol_key)
        end

        # Scope#apply_to_event gives every event its own tags hash, so writing
        # in place never reaches the scope. A frozen one is replaced instead.
        def writable_tags(event, tags)
          return tags unless tags.frozen?

          copy = tags.dup
          event.tags = copy
          copy
        end

        def present_string(value)
          value.is_a?(String) && !value.empty? ? value : nil
        end

        def compute_rake_run_id
          return false unless defined?(::Rake) && ::Rake.respond_to?(:application)

          tasks = ::Rake.application.top_level_tasks
          return false unless tasks.is_a?(Array) && !tasks.empty?

          workers = Array(Koderift::Rails.configuration.rake_worker_tasks).map(&:to_s)
          return false if tasks.any? { |task| workers.include?(task.to_s.sub(TASK_ARGS_RE, '')) }

          SecureRandom.uuid
        rescue StandardError
          false
        end
      end
    end
  end
end
