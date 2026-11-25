# frozen_string_literal: true

require 'time'
require 'active_support/core_ext/string/filters'
require 'koderift/rails/frame_stack'
require 'koderift/rails/trace_context'
require 'koderift/rails/breadcrumb'

module Koderift
  module Rails
    module Instrumentation
      # One unit of work's collections. The frame is also the owner token the
      # subscription callbacks check: ActiveSupport::Notifications subscribers
      # are process-wide, so without that check every unit in flight recorded
      # every other thread's SQL, partials and searches as its own.
      class CaptureFrame
        include FrameStack::Member

        attr_reader :config, :partials, :queries, :search_queries, :breadcrumbs,
                    :custom_spans, :external_calls, :started_at_ms

        def initialize(config:, started_at_ms:, restore_outside:)
          @config          = config
          @started_at_ms   = started_at_ms
          @restore_outside = restore_outside
          @partials        = []
          @queries         = []
          @search_queries  = []
          @breadcrumbs     = []
          @custom_spans    = []
          @external_calls  = []
        end

        # Whole milliseconds from the unit's start to a CLOCK_MONOTONIC time in
        # float milliseconds. Nil for a time outside the unit, so a clock
        # mix-up leaves start_ms out rather than emitting a wrong value.
        def offset_ms(mono_ms)
          return nil unless mono_ms.is_a?(Numeric)

          offset = mono_ms - @started_at_ms
          return nil if offset < -1.0 || mono_ms > TraceContext.now_ms + 1.0

          offset.negative? ? 0 : offset.round
        rescue StandardError
          nil
        end
      end

      # Published for the same reason external_calls always was: code that runs
      # somewhere else entirely -- the Net::HTTP patch, Koderift.add_breadcrumb,
      # Koderift.with_child_span -- has no other way to find the collection
      # belonging to the unit of work currently in flight on this thread.
      CAPTURES = FrameStack.new(
        :koderift_capture_frames,
        %i[koderift_breadcrumbs koderift_custom_spans koderift_external_calls koderift_external_config]
      ) do |frame|
        [frame.breadcrumbs, frame.custom_spans, frame.external_calls, frame.config]
      end

      # A start time this many times larger than the monotonic clock in seconds
      # is in milliseconds. Rails 7.1.0-7.1.3 replays load_async events with
      # millisecond times where seconds are expected.
      MILLISECOND_START_FACTOR = 100

      # Subscribes to Rails notifications during a request to capture
      # partial render times, SQL query times, and breadcrumbs.
      # Returns a hash of captured data to be merged into the log payload.
      def self.capture(restore_outside: false, started_at_ms: nil)
        state = start_capture(restore_outside: restore_outside, started_at_ms: started_at_ms)
        begin
          yield
        ensure
          stop_capture(state)
        end
        build_result(state)
      end

      # capture's three phases, exposed separately so a unit of work that is
      # NOT a block runs through the same subscriptions rather than a parallel
      # implementation. Tracing::Transaction is that caller: it has to be
      # started and finished by two separate calls to mirror Sentry's
      # start_transaction / finish, which a block-shaped API cannot express.
      #
      # restore_outside: when this is the outermost frame, put back what the
      # thread held before instead of clearing it (transactions). Requests and
      # jobs clear.
      #
      # monotonic_subscribe, not subscribe: the start time a subscriber is handed
      # is then CLOCK_MONOTONIC seconds on every supported Rails. Event#time is
      # not used for start_ms because it changed units inside 7.1 (milliseconds
      # up to 7.1.3, seconds from 7.1.4).
      def self.start_capture(restore_outside: false, started_at_ms: nil)
        config = Koderift::Rails.configuration
        frame  = CaptureFrame.new(
          config:          config,
          started_at_ms:   started_at_ms || TraceContext.now_ms,
          restore_outside: restore_outside
        )

        partial_sub = ActiveSupport::Notifications.monotonic_subscribe('render_partial.action_view') do |*args|
          record_partial(frame, args) if current_frame.equal?(frame)
        end

        query_sub = ActiveSupport::Notifications.monotonic_subscribe('sql.active_record') do |*args|
          record_query(frame, args) if current_frame.equal?(frame)
        end

        # Single-model search: fired by Model.search(...)
        # payload: { name: "Admin10 Search", query: {...} }
        search_sub = ActiveSupport::Notifications.monotonic_subscribe('search.searchkick') do |*args|
          record_search(frame, args) if current_frame.equal?(frame)
        end

        # Multi search: fired by Searchkick.multi_search([...])
        # payload: { name: "Multi Search", body: "..." }
        # Duration covers the entire batch — record as a single entry.
        multi_search_sub = ActiveSupport::Notifications.monotonic_subscribe('multi_search.searchkick') do |*args|
          record_multi_search(frame, args) if current_frame.equal?(frame)
        end

        CAPTURES.push(frame)

        {
          config:         config,
          partials:       frame.partials,
          queries:        frame.queries,
          search_queries: frame.search_queries,
          breadcrumbs:    frame.breadcrumbs,
          custom_spans:   frame.custom_spans,
          external_calls: frame.external_calls,
          subscriptions:  [partial_sub, query_sub, search_sub, multi_search_sub],
          frame:          frame
        }
      end

      def self.stop_capture(state)
        state[:subscriptions].each do |sub|
          ActiveSupport::Notifications.unsubscribe(sub)
        end
        state
      ensure
        CAPTURES.pop(state[:frame]) if state.is_a?(Hash) && state[:frame]
      end

      # build_result that never raises: nil when the result can't be built.
      # A bug here must not fail the request or job it describes, nor
      # replace the exception that is already on its way out of one. With
      # nil the line goes out without spans or counts.
      def self.result_for(state)
        state ? build_result(state) : nil
      rescue StandardError
        nil
      end

      def self.build_result(state)
        spans = []

        state[:partials].each_with_index do |p, i|
          spans << with_span_fields({ type: 'partial', name: p[:partial], duration_ms: p[:duration_ms], sequence: i }, p)
        end

        state[:queries].each_with_index do |q, i|
          spans << with_span_fields({ type: 'sql', name: q[:sql], duration_ms: q[:duration_ms], sequence: i }, q)
        end

        state[:search_queries].each_with_index do |s, i|
          spans << with_span_fields({ type: 'search', name: s[:index], duration_ms: s[:duration_ms], sequence: i }, s)
        end

        state[:external_calls].each_with_index do |c, i|
          spans << with_span_fields({
            type:        'http',
            name:        "#{c[:host]}#{c[:endpoint]}",
            duration_ms: c[:duration_ms],
            detail:      { method: c[:method], status: c[:status], trace_id: c[:trace_id] }.compact.to_json,
            sequence:    i
          }, c)
        end

        state[:custom_spans].each_with_index do |c, i|
          spans << with_span_fields({
            type:        'custom',
            name:        c[:name],
            duration_ms: c[:duration_ms],
            detail:      c[:detail],
            sequence:    i
          }.compact, c)
        end

        {
          spans:         spans,
          query_count:   state[:queries].size,
          partial_count: state[:partials].size,
          search_count:  state[:search_queries].size,
          breadcrumbs:   Breadcrumbs.capped(state[:breadcrumbs])
        }
      end

      def self.current_frame
        CAPTURES.top
      end

      # Whether that capture is still running on this thread.
      def self.capturing?(frame)
        CAPTURES.include?(frame)
      end

      def self.clear_captures!
        CAPTURES.clear!
      end

      # The trace keys every span carries, appended after the existing ones.
      # parent_span_id is left out when the parent is the line's own root span,
      # which is most spans: a missing parent means the root. A span recorded
      # without an ID (a hash pushed straight onto a collection) gets one here,
      # so every emitted span has a span_id.
      def self.with_span_fields(span, entry)
        span[:span_id]        = entry[:span_id] || TraceContext.new_span_id
        span[:parent_span_id] = entry[:parent_span_id] if entry[:parent_span_id]
        span[:start_ms]       = entry[:start_ms] if entry[:start_ms]
        span
      rescue StandardError
        span
      end

      # Trace keys for an entry recorded now: a new span ID, the enclosing
      # with_child_span (if any) as parent, and the start offset.
      def self.span_fields(start_ms, span_id: nil)
        fields = { span_id: span_id || TraceContext.new_span_id }
        parent = TraceContext::Current.enclosing_span_id
        fields[:parent_span_id] = parent if parent
        fields[:start_ms]       = start_ms if start_ms
        fields
      rescue StandardError
        {}
      end

      # The callbacks below run inside the instrumented code's own call, and
      # ActiveSupport re-raises a subscriber's exception there (7.1+), so a
      # bug here would fail the host app's SQL query or render. Each one
      # swallows its own errors.
      def self.record_partial(frame, args)
        event      = ActiveSupport::Notifications::Event.new(*args)
        payload    = event.payload
        timing     = event_timing(frame, args, event)
        duration   = (payload[:duration] || timing[:duration]).round
        identifier = payload[:identifier].to_s
                                         .sub(rails_root_prefix, '')
                                         .sub(%r{\A/app/views/}, '')

        frame.partials << { partial: identifier, duration_ms: duration }.merge(span_fields(timing[:start_ms]))
        frame.breadcrumbs << {
          type:        'render',
          message:     identifier,
          duration_ms: duration,
          timestamp:   Time.now.utc.iso8601
        }
      rescue StandardError
        nil
      end

      def self.record_query(frame, args)
        event   = ActiveSupport::Notifications::Event.new(*args)
        payload = event.payload
        return if payload[:name].to_s.match?(/\A(CACHE|SCHEMA)/)

        timing   = event_timing(frame, args, event)
        duration = (payload[:duration] || timing[:duration]).round
        sql      = payload[:sql].to_s.squish.truncate(300)

        frame.queries << { sql: sql, duration_ms: duration }.merge(span_fields(timing[:start_ms]))
        frame.breadcrumbs << {
          type:        'sql',
          message:     sql,
          duration_ms: duration,
          timestamp:   Time.now.utc.iso8601
        }
      rescue StandardError
        nil
      end

      def self.record_search(frame, args)
        event    = ActiveSupport::Notifications::Event.new(*args)
        payload  = event.payload
        timing   = event_timing(frame, args, event)
        duration = (payload[:duration] || timing[:duration]).round

        index = payload[:name].to_s.sub(/\s*Search\z/i, '').strip
        index = 'unknown' if index.blank?

        frame.search_queries << { index: index, duration_ms: duration }.merge(span_fields(timing[:start_ms]))
      rescue StandardError
        nil
      end

      def self.record_multi_search(frame, args)
        event    = ActiveSupport::Notifications::Event.new(*args)
        timing   = event_timing(frame, args, event)
        duration = timing[:duration].round

        frame.search_queries << { index: 'multi_search', duration_ms: duration }.merge(span_fields(timing[:start_ms]))
      rescue StandardError
        nil
      end

      # The event's duration and its start offset, from the raw start argument
      # (CLOCK_MONOTONIC seconds under monotonic_subscribe). On Rails
      # 7.1.0-7.1.3 a replayed load_async event arrives in milliseconds, which
      # also inflates its duration a thousandfold; both are corrected, but only
      # when the corrected start actually falls inside this unit.
      def self.event_timing(frame, args, event)
        duration = event.duration
        start    = args[1]
        return { duration: duration, start_ms: nil } unless start.is_a?(Numeric)

        start = start.to_f
        if start > Process.clock_gettime(Process::CLOCK_MONOTONIC) * MILLISECOND_START_FACTOR
          offset = frame.offset_ms(start)
          return { duration: duration, start_ms: nil } unless offset

          return { duration: duration && duration / 1000.0, start_ms: offset }
        end

        { duration: duration, start_ms: frame.offset_ms(start * 1000.0) }
      rescue StandardError
        { duration: event.duration, start_ms: nil }
      end

      def self.rails_root_prefix
        defined?(::Rails) && ::Rails.respond_to?(:root) && ::Rails.root ? ::Rails.root.to_s : ''
      end
    end

    # Installed once when the gem loads (see the prepend at the bottom of this
    # file). Writes to the thread-local external_calls array set by
    # Instrumentation.capture; outside of a capture block it is a pass-through
    # that still propagates the trace.
    #
    # CONTRACT: exactly one entry per LOGICAL outbound call. Net::HTTP#request
    # re-enters itself whenever it is called on a session that is not started:
    #
    #   def request(req, body = nil, &block)
    #     unless started?
    #       start { req['connection'] ||= 'close'; return request(req, body, &block) }
    #     end
    #
    # (net-http-0.9.1 lib/net/http.rb:2399-2405). Both frames run this prepended
    # patch, so one call was recorded twice. That branch also forces
    # `Connection: close` and start's ensure closes the socket, so an affected
    # call site double-counts on EVERY call, not intermittently.
    module NetHttpPatch
      OWN_TRACEPARENT = :@koderift_traceparent
      LOOPBACK_HOSTS  = ['127.0.0.1', 'localhost', '[::1]'].freeze

      def request(req, *args, &block)
        # The stdlib recursion re-invokes with the SAME req object, so request
        # identity separates "my own re-entry" from a genuinely different call
        # issued while this one is in flight. The outer frame has already set
        # the headers and will record the call. This check runs whether or not
        # a capture is active, so the inner frame never mints a second span ID
        # for the same call. Do NOT use `started?` (it keeps the inner frame,
        # which cannot see connection setup, and the spec stand-ins do not all
        # define it) and do NOT use an object ivar (one Net::HTTP shared across
        # threads would silently lose most of its spans).
        in_flight = (Thread.current[:koderift_http_in_flight] ||= [])
        return super(req, *args, &block) if in_flight.any? { |r| r.equal?(req) }

        calls    = Thread.current[:koderift_external_calls]
        config   = Thread.current[:koderift_external_config]
        trace_id = Thread.current[:koderift_trace_id]

        req['X-Koderift-Trace-ID'] = trace_id if trace_id

        # Whether this call will be recorded is known before it is made: the
        # host is fixed at Net::HTTP.new and the ignore list is configuration.
        # `address` is only read while capturing; the pass-through stand-in in
        # the specs does not define it.
        host    = calls && config ? NetHttpPatch.host_of(self) : nil
        record  = host ? !NetHttpPatch.ignored_host?(host, config) : false
        span_id = NetHttpPatch.propagate(req, trace_id, record)

        in_flight << req
        start_ms = TraceContext.now_ms
        begin
          response = super(req, *args, &block)
        ensure
          # Strictly LIFO: the inner frame returns above without pushing, and
          # push/pop are paired in one begin/ensure. The ensure also covers a
          # raise (Net::OpenTimeout, ECONNREFUSED, a raising response block) --
          # without it one failure would silence every later call on this thread.
          in_flight.pop
        end
        return response unless record

        duration = (TraceContext.now_ms - start_ms).round
        raw_path = req.path.to_s.split('?').first.to_s
        segments = raw_path.split('/').reject(&:empty?).first(2)
        endpoint = segments.empty? ? '/' : '/' + segments.join('/')

        calls << {
          host: host, endpoint: endpoint, method: req.method.to_s.upcase,
          status: response.code.to_i, duration_ms: duration, trace_id: trace_id
        }.merge(NetHttpPatch.span_fields(span_id, start_ms))

        response
      end

      def self.host_of(http)
        http.address.to_s
      rescue StandardError
        nil
      end

      def self.ignored_host?(host, config)
        LOOPBACK_HOSTS.include?(host) ||
          config.external_call_ignore_hosts.any? { |h| host.include?(h) }
      rescue StandardError
        false
      end

      # Sets the outbound trace headers and returns the HTTP span's ID when the
      # call will be recorded (nil otherwise).
      #
      # X-Koderift-Traceparent is the gem's own copy of the context, always
      # written: APM instrumentation (OpenTelemetry, Datadog, New Relic)
      # rewrites `traceparent` but never touches it, so a Koderift app
      # downstream can still nest under this exact span.
      #
      # `traceparent` itself is written only if absent, or if it is the value
      # this patch wrote on this same request object earlier (a request
      # reused for a retry). One set by anyone else is never overwritten.
      #
      # The parent ID sent is the HTTP span's own ID when the span will be
      # recorded, else the span open around the call, so a downstream line
      # points at a span that exists. A call that raises records nothing, so
      # its downstream may name a parent no span carries.
      def self.propagate(req, trace_id, record)
        return nil unless TraceContext.valid_trace_id?(trace_id)

        current = TraceContext::Current.current_span_id
        span_id = if record || current.nil?
                    TraceContext.new_span_id
                  else
                    current
                  end
        header  = TraceContext::Current.traceparent(span_id)
        return nil unless header

        req[TraceContext::KODERIFT_TRACEPARENT] = header

        existing = req['traceparent']
        if existing.nil? || existing == req.instance_variable_get(OWN_TRACEPARENT)
          req['traceparent'] = header
          req.instance_variable_set(OWN_TRACEPARENT, header)

          tracestate = TraceContext::Current.tracestate
          req['tracestate'] = tracestate if tracestate && req['tracestate'].nil?
        end

        record ? span_id : nil
      rescue StandardError
        nil
      end

      def self.span_fields(span_id, start_ms)
        frame = Instrumentation.current_frame
        Instrumentation.span_fields(frame && frame.offset_ms(start_ms), span_id: span_id)
      rescue StandardError
        {}
      end
    end
  end
end

require 'net/http'
Net::HTTP.prepend(Koderift::Rails::NetHttpPatch)
