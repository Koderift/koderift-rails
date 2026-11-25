# frozen_string_literal: true

require 'json'
require 'securerandom'
require 'koderift/rails/trace_context'
require 'koderift/rails/instrumentation'
require 'koderift/rails/capture'
require 'koderift/rails/rescue_context'

module Koderift
  module Rails
    # Sentry-compatible custom instrumentation, backed by the span pipeline the
    # gem already has. A child span becomes a `custom` span in log_spans and
    # renders in the APM trace next to the SQL, partial and HTTP spans.
    module Tracing
      TRANSACTION_KEY = :koderift_transaction
      MAX_SPAN_NAME   = 2_000

      # Handed to a with_child_span block. set_data and set_description are
      # real: they shape the span's detail and name in the emitted trace.
      class ChildSpan
        attr_reader :op, :description

        def initialize(op: nil, description: nil)
          @op          = op
          @description = description
          @data        = {}
        end

        def set_data(key, value)
          @data[key.to_s] = value
          self
        end

        def set_description(value)
          @description = value
          self
        end

        def name
          [@description, @op].map(&:to_s).reject(&:empty?).first || 'custom'
        end

        def detail
          payload = @data.dup
          payload['op'] = @op.to_s unless @op.to_s.empty?
          payload.empty? ? nil : JSON.generate(payload)
        rescue StandardError
          nil
        end
      end

      # A unit of work that is neither an HTTP request nor a Sidekiq job — the
      # nightly rake task case. It runs through Instrumentation's subscriptions
      # exactly as those two do, so its SQL, HTTP and custom spans reach the
      # APM trace view.
      class Transaction
        attr_reader :name, :op, :request_id, :trace_id, :span_id, :parent_span_id

        def initialize(name:, op: nil)
          @name     = name.to_s
          @op       = op
          @finished = false

          # A transaction MUST carry a request_id.
          # IngestLogBatchJob#build_span_rows does `next if request_id.blank?`,
          # so without one every span collected here is dropped before it
          # reaches log_spans — the trace would arrive empty, with no error
          # anywhere to explain why.
          @request_id = SecureRandom.uuid

          # Inside a request or job this joins that trace as a child of the
          # span open there; otherwise it starts a new one. (start_transaction
          # finishes a transaction already open on the thread before starting
          # this one, as it did before 2.2.)
          # Its frames restore what the thread held before when it finishes,
          # and a transaction finished after the unit it began in has ended
          # (an abandoned non-block one) finds its frames gone and restores
          # nothing.
          @started_at_ms = TraceContext.now_ms
          trace          = TraceContext.continue_current
          @trace_id       = trace[:trace_id]
          @parent_span_id = trace[:parent_span_id]
          @frame          = push_frame(trace)
          @span_id        = @frame && @frame.root_span_id
          @started_at     = @frame && @frame.started_at

          @state = Instrumentation.start_capture(restore_outside: true, started_at_ms: @started_at_ms)
        end

        def finished?
          @finished
        end

        def finish
          return nil if @finished

          @finished   = true
          duration_ms = (TraceContext.now_ms - @started_at_ms).round

          Instrumentation.stop_capture(@state)
          result = Instrumentation.build_result(@state)

          Capture.transaction(
            component:      component,
            action:         action,
            message:        "Completed in #{(duration_ms / 1000.0).round(1)}s",
            duration_ms:    duration_ms,
            request_id:     @request_id,
            trace_id:       @trace_id,
            span_id:        @span_id,
            parent_span_id: @parent_span_id,
            started_at:     @started_at,
            result:         result,
            detached:       finished_in_another_handler?
          )
        rescue StandardError
          nil
        ensure
          TraceContext::Current.pop(@frame)
          Tracing.clear_current(self)
        end

        def component
          part = @name.split('#').first.to_s
          part.empty? ? 'transaction' : part
        end

        def action
          part = @name.split('#')[1].to_s
          return part unless part.empty?

          op = @op.to_s
          op.empty? ? 'call' : op
        end

        private

        # An abandoned transaction (its frames dropped at the end of the unit
        # it began in) finished from a later request's rescue_from handler.
        # Its line must not take that request's user, path or scope.
        def finished_in_another_handler?
          return false unless @frame && RescueContext.current

          !TraceContext::Current::STACK.include?(@frame)
        rescue StandardError
          false
        end

        def push_frame(trace)
          TraceContext::Current.push(
            kind:            :transaction,
            trace_id:        trace[:trace_id],
            parent_span_id:  trace[:parent_span_id],
            flags:           trace[:flags],
            tracestate:      trace[:tracestate],
            context:         { component: component, action: action, request_id: @request_id },
            started_at_ms:   @started_at_ms,
            restore_outside: true
          )
        rescue StandardError
          nil
        end
      end

      class << self
        def with_child_span(op: nil, description: nil)
          span    = ChildSpan.new(op: op, description: description)
          started = TraceContext.now_ms
          opened  = open_span
          begin
            yield span
          ensure
            close_span(opened)
            elapsed = (TraceContext.now_ms - started).round
            record(span, elapsed, opened, started)
          end
        end

        # Returns the Transaction when called without a block, so
        # `txn = Koderift.start_transaction(name: '...')` / `txn.finish` works
        # as it does in Sentry. PREFER the block form: it finishes in an ensure,
        # and an abandoned transaction leaves four ActiveSupport::Notifications
        # subscribers attached to the process. Starting a new transaction
        # finishes an abandoned one on the same thread, which bounds that leak
        # to one, but does not make it free.
        def start_transaction(name: nil, op: nil)
          previous = Thread.current[TRANSACTION_KEY]
          previous.finish if previous.is_a?(Transaction) && !previous.finished?

          transaction = Transaction.new(name: name || op.to_s, op: op)
          Thread.current[TRANSACTION_KEY] = transaction
          return transaction unless block_given?

          begin
            yield transaction
          ensure
            transaction.finish
          end
        end

        def current_transaction
          Thread.current[TRANSACTION_KEY]
        end

        def clear_current(transaction)
          return unless Thread.current[TRANSACTION_KEY].equal?(transaction)

          Thread.current[TRANSACTION_KEY] = nil
        end

        private

        # The span's ID goes on the open-span stack of the trace frame in force
        # when it starts, so SQL, HTTP calls and child spans inside the block
        # name it as their parent. The stack array itself is remembered: if a
        # transaction is started inside the block and is still open when the
        # block ends, the ID is still removed from the right stack. The
        # capture in force is remembered too, so the span is recorded on the
        # line of the unit it was opened in.
        def open_span
          span_id = TraceContext.new_span_id
          opened  = { span_id: span_id, capture: Instrumentation.current_frame }
          frame   = TraceContext::Current.frame
          return opened unless frame

          stack  = frame.span_stack
          parent = stack.last
          stack.push(span_id)
          opened.merge(parent_span_id: parent, stack: stack)
        rescue StandardError
          nil
        end

        def close_span(opened)
          stack = opened && opened[:stack]
          return unless stack

          index = stack.rindex(opened[:span_id])
          stack.delete_at(index) if index
        rescue StandardError
          nil
        end

        # Outside a captured unit of work there is no array to append to, so the
        # span is simply not recorded. That is inertness for want of a place to
        # put it, not a stub: inside a request, job or transaction the very same
        # call produces a real span.
        #
        # The span goes on the line of the unit it was opened in while that
        # unit is still running, even if a transaction started inside the
        # block is still open. If that unit has already ended (a transaction
        # finished inside the block), the span goes on the line of the unit
        # running now, under the span open there, rather than onto a line that
        # has already been written.
        def record(span, duration_ms, opened, started)
          opened_in = opened && opened[:capture]
          if opened_in && Instrumentation.capturing?(opened_in)
            capture = opened_in
            parent  = opened[:parent_span_id]
          else
            capture = Instrumentation.current_frame
            parent  = TraceContext::Current.enclosing_span_id
          end
          return nil unless capture

          name  = span.name.to_s
          entry = {
            name:        name.length > MAX_SPAN_NAME ? name[0, MAX_SPAN_NAME] : name,
            duration_ms: duration_ms,
            detail:      span.detail,
            span_id:     (opened && opened[:span_id]) || TraceContext.new_span_id
          }
          entry[:parent_span_id] = parent if parent
          start_ms = capture.offset_ms(started)
          entry[:start_ms] = start_ms if start_ms
          capture.custom_spans << entry
        rescue StandardError
          nil
        end
      end
    end
  end
end
