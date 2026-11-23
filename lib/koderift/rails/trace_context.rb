# frozen_string_literal: true

require 'securerandom'
require 'time'
require 'koderift/rails/frame_stack'

module Koderift
  module Rails
    # W3C Trace Context (https://www.w3.org/TR/trace-context/, the Level 1
    # Recommendation) plus the two other ways a trace reaches this gem: Sentry's
    # `sentry-trace` header and the gem's own headers.
    #
    # Everything at module level is a pure function and never raises: a
    # malformed header is ignored and the unit of work starts a new trace.
    module TraceContext
      DEFAULT_FLAGS = '01'

      TRACEPARENT_RE  = /\A([0-9a-f]{2})-([0-9a-f]{32})-([0-9a-f]{16})-([0-9a-f]{2})(-.*)?\z/.freeze
      SENTRY_TRACE_RE = /\A([0-9a-f]{32})-([0-9a-f]{16})(?:-([01]))?\z/.freeze
      LEGACY_RE       = /\A(?:\h{8}-\h{4}-\h{4}-\h{4}-\h{12}|\h{32})\z/.freeze
      TRACE_ID_RE     = /\A[0-9a-f]{32}\z/.freeze
      SPAN_ID_RE      = /\A[0-9a-f]{16}\z/.freeze
      TRACESTATE_RE   = /\A[\x20-\x7e]*\z/.freeze

      ZERO_TRACE_ID = ('0' * 32).freeze
      ZERO_SPAN_ID  = ('0' * 16).freeze

      MAX_HEADER          = 512
      MAX_TRACESTATE      = 512
      MAX_TRACESTATE_ITEM = 128

      KODERIFT_TRACEPARENT = 'X-Koderift-Traceparent'
      LEGACY_TRACE_HEADER  = 'X-Koderift-Trace-ID'

      class << self
        def new_trace_id
          SecureRandom.hex(16)
        end

        def new_span_id
          SecureRandom.hex(8)
        end

        def new_context
          { trace_id: new_trace_id, parent_span_id: nil, flags: DEFAULT_FLAGS, tracestate: nil }
        end

        def valid_trace_id?(value)
          value.is_a?(String) && TRACE_ID_RE.match?(value) && value != ZERO_TRACE_ID
        end

        def valid_span_id?(value)
          value.is_a?(String) && SPAN_ID_RE.match?(value) && value != ZERO_SPAN_ID
        end

        # Lowercase hex only (the spec forbids uppercase). Version ff is
        # invalid. Version 00 is exactly 55 characters. A higher version is
        # read by its first four fields, and anything after the flags must
        # start with a dash. Only the sampled bit of the flags is kept: Level 1
        # says unknown flags are zeroed before they are sent on.
        def parse_traceparent(value)
          return nil unless value.is_a?(String) && value.bytesize <= MAX_HEADER

          match = TRACEPARENT_RE.match(value.strip)
          return nil unless match

          version, trace_id, span_id, flags, rest = match.captures
          return nil if version == 'ff'
          return nil if version == '00' && rest
          return nil unless valid_trace_id?(trace_id) && valid_span_id?(span_id)

          { trace_id: trace_id, parent_span_id: span_id, flags: sampled_flags(flags) }
        rescue StandardError
          nil
        end

        # Returns nil when either ID is invalid, so a non-hex trace ID that
        # older code put on the thread never becomes a malformed header.
        def format_traceparent(trace_id, span_id, flags = DEFAULT_FLAGS)
          return nil unless valid_trace_id?(trace_id) && valid_span_id?(span_id)

          flags = DEFAULT_FLAGS unless flags.is_a?(String) && /\A[0-9a-f]{2}\z/.match?(flags)
          "00-#{trace_id}-#{span_id}-#{flags}"
        rescue StandardError
          nil
        end

        # `<trace id>-<span id>[-<sampled>]`. A missing sampled flag is
        # Sentry's "decide later"; it is treated as sampled.
        def parse_sentry_trace(value)
          return nil unless value.is_a?(String) && value.bytesize <= MAX_HEADER

          match = SENTRY_TRACE_RE.match(value.strip)
          return nil unless match

          trace_id, span_id, sampled = match.captures
          return nil unless valid_trace_id?(trace_id) && valid_span_id?(span_id)

          { trace_id: trace_id, parent_span_id: span_id, flags: sampled == '0' ? '00' : DEFAULT_FLAGS }
        rescue StandardError
          nil
        end

        # The trace ID gem versions before 2.2 sent: a UUID. Dashed or not, any
        # case, it becomes 32 lowercase hex. Anything else is not a trace ID.
        def normalise_legacy(value)
          return nil unless value.is_a?(String) && value.bytesize <= MAX_HEADER

          stripped = value.strip
          return nil unless LEGACY_RE.match?(stripped)

          id = stripped.delete('-').downcase
          valid_trace_id?(id) ? id : nil
        rescue StandardError
          nil
        end

        # Vendors that receive tracestate must pass it on. Kept as received
        # when it is printable ASCII within 512 characters; longer values are
        # cut the way the spec allows, dropping entries over 128 characters
        # and then entries from the end.
        def parse_tracestate(value)
          return nil unless value.is_a?(String) && value.bytesize <= MAX_HEADER * 8

          stripped = value.strip
          return nil if stripped.empty? || !TRACESTATE_RE.match?(stripped)
          return stripped if stripped.length <= MAX_TRACESTATE

          entries = stripped.split(',').map(&:strip).reject(&:empty?)
          entries = entries.reject { |e| e.length > MAX_TRACESTATE_ITEM }
          entries.pop while entries.any? && entries.join(',').length > MAX_TRACESTATE
          entries.empty? ? nil : entries.join(',')
        rescue StandardError
          nil
        end

        # Precedence: X-Koderift-Traceparent (our own copy, which APM
        # instrumentation never rewrites), traceparent, sentry-trace, the
        # legacy X-Koderift-Trace-ID, then a new trace.
        #
        # A Koderift trace ID wins whenever it disagrees, because nothing but
        # this gem sets it. A caller on a version before 2.2 sends only the
        # legacy header, and if it also runs Sentry or an APM, that tool's
        # sentry-trace or traceparent arrives too, carrying a different trace.
        # The legacy ID is then used, with no parent (that header carries
        # none), so the trace still links. When the two agree, the W3C or
        # Sentry parent is kept.
        #
        # tracestate belongs to the incoming traceparent, so it is kept only
        # when the trace chosen is that header's trace.
        def incoming(source)
          return new_context if source.nil?

          koderift = parse_traceparent(header(source, KODERIFT_TRACEPARENT))
          w3c      = parse_traceparent(header(source, 'traceparent'))
          foreign  = w3c || parse_sentry_trace(header(source, 'sentry-trace'))
          legacy   = koderift ? nil : normalise_legacy(header(source, LEGACY_TRACE_HEADER))

          context = if koderift
                      koderift
                    elsif legacy && (foreign.nil? || foreign[:trace_id] != legacy)
                      { trace_id: legacy, parent_span_id: nil, flags: DEFAULT_FLAGS }
                    else
                      foreign
                    end
          return new_context unless context

          tracestate = nil
          if w3c && w3c[:trace_id] == context[:trace_id]
            tracestate = parse_tracestate(header(source, 'tracestate'))
          end
          context.merge(tracestate: tracestate)
        rescue StandardError
          new_context
        end

        # The trace a Sidekiq job continues: the traceparent the client
        # middleware stored, then the legacy trace ID key, then a new trace.
        def from_job(job)
          return new_context unless job.is_a?(Hash)

          context = parse_traceparent(job['koderift_traceparent'])
          unless context
            legacy  = normalise_legacy(job['koderift_trace_id'])
            context = { trace_id: legacy, parent_span_id: nil, flags: DEFAULT_FLAGS } if legacy
          end
          context ? context.merge(tracestate: nil) : new_context
        rescue StandardError
          new_context
        end

        # A transaction joins the trace already on the thread, as a child of
        # the span open there; otherwise it starts one.
        def continue_current
          trace_id = Current.trace_id
          return new_context if trace_id.nil? || trace_id.to_s.empty?

          {
            trace_id:       trace_id,
            parent_span_id: Current.current_span_id,
            flags:          Current.flags || DEFAULT_FLAGS,
            tracestate:     Current.tracestate
          }
        rescue StandardError
          new_context
        end

        def now_ms
          Process.clock_gettime(Process::CLOCK_MONOTONIC, :float_millisecond)
        end

        private

        def sampled_flags(flags)
          (flags.to_i(16) & 1) == 1 ? '01' : '00'
        end

        # ActionDispatch::Http::Headers maps `traceparent` to HTTP_TRACEPARENT
        # itself; a bare Rack env needs the HTTP_ form; a plain hash may use
        # either.
        def header(source, name)
          value = source[name]
          value = source["HTTP_#{name.upcase.tr('-', '_')}"] if value.nil?
          value.is_a?(String) ? value : nil
        rescue StandardError
          nil
        end
      end

      # The trace state of one unit of work.
      class Frame
        include FrameStack::Member

        attr_reader :kind, :trace_id, :root_span_id, :parent_span_id, :flags,
                    :tracestate, :span_stack, :started_at_ms, :started_at, :context

        def initialize(kind:, trace_id:, parent_span_id:, flags:, tracestate:, context:,
                       started_at_ms:, started_at:, restore_outside:)
          @kind            = kind
          @trace_id        = trace_id
          @root_span_id    = TraceContext.new_span_id
          @parent_span_id  = parent_span_id
          @flags           = flags || DEFAULT_FLAGS
          @tracestate      = tracestate
          @context         = context
          @span_stack      = []
          @started_at_ms   = started_at_ms || TraceContext.now_ms
          @started_at      = (started_at || Time.now).utc.iso8601(3)
          @restore_outside = restore_outside
        end
      end

      # The thread's trace state. The trace ID itself stays published in
      # Thread.current[:koderift_trace_id], which Capture and NetHttpPatch read,
      # and the ambient capture context in Thread.current[:koderift_context].
      # Only frames write those two keys.
      module Current
        STACK = FrameStack.new(:koderift_trace_frames, %i[koderift_trace_id koderift_context]) do |frame|
          [frame.trace_id, frame.context]
        end

        class << self
          def push(kind:, trace_id:, parent_span_id: nil, flags: nil, tracestate: nil,
                   context: nil, started_at_ms: nil, started_at: nil, restore_outside: false)
            STACK.push(Frame.new(
              kind: kind, trace_id: trace_id, parent_span_id: parent_span_id,
              flags: flags, tracestate: tracestate, context: context,
              started_at_ms: started_at_ms, started_at: started_at,
              restore_outside: restore_outside
            ))
          end

          def pop(frame)
            frame ? STACK.pop(frame) : false
          end

          def frame
            STACK.top
          end

          def clear!
            STACK.clear!
          end

          def trace_id
            Thread.current[:koderift_trace_id]
          end

          # The innermost open span: a with_child_span block, else the unit's
          # root span. What a job, a downstream request or a nested
          # transaction names as its parent.
          def current_span_id
            f = frame
            f && (f.span_stack.last || f.root_span_id)
          end

          # The innermost open with_child_span, or nil when the unit's root is
          # the parent. Spans inside a line leave parent_span_id out in that
          # case: missing means the root.
          def enclosing_span_id
            f = frame
            f && f.span_stack.last
          end

          def flags
            f = frame
            f && f.flags
          end

          def tracestate
            f = frame
            f && f.tracestate
          end

          def traceparent(span_id = current_span_id)
            TraceContext.format_traceparent(trace_id, span_id, flags || DEFAULT_FLAGS)
          end
        end
      end
    end
  end
end
