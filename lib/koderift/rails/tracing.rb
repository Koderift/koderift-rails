# frozen_string_literal: true

require 'json'
require 'securerandom'
require 'koderift/rails/instrumentation'
require 'koderift/rails/capture'

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
        attr_reader :name, :op, :request_id, :trace_id

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
          @trace_id   = Thread.current[:koderift_trace_id] || SecureRandom.uuid

          @previous_trace_id = Thread.current[:koderift_trace_id]
          @previous_context  = Thread.current[Capture::CONTEXT_KEY]

          Thread.current[:koderift_trace_id]   = @trace_id
          Thread.current[Capture::CONTEXT_KEY] = {
            component:  component,
            action:     action,
            request_id: @request_id
          }

          @started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          @state      = Instrumentation.start_capture
        end

        def finished?
          @finished
        end

        def finish
          return nil if @finished

          @finished   = true
          duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - @started_at) * 1000).round

          Instrumentation.stop_capture(@state)
          result = Instrumentation.build_result(@state)

          Capture.transaction(
            component:   component,
            action:      action,
            message:     "Completed in #{(duration_ms / 1000.0).round(1)}s",
            duration_ms: duration_ms,
            request_id:  @request_id,
            trace_id:    @trace_id,
            result:      result
          )
        rescue StandardError
          nil
        ensure
          Thread.current[:koderift_trace_id]   = @previous_trace_id
          Thread.current[Capture::CONTEXT_KEY] = @previous_context
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
      end

      class << self
        def with_child_span(op: nil, description: nil)
          span    = ChildSpan.new(op: op, description: description)
          started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          begin
            yield span
          ensure
            elapsed = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
            record(span, elapsed)
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

        # Outside a captured unit of work there is no array to append to, so the
        # span is simply not recorded. That is inertness for want of a place to
        # put it, not a stub: inside a request, job or transaction the very same
        # call produces a real span.
        def record(span, duration_ms)
          spans = Thread.current[:koderift_custom_spans]
          return nil unless spans.is_a?(Array)

          name = span.name.to_s
          spans << {
            name:        name.length > MAX_SPAN_NAME ? name[0, MAX_SPAN_NAME] : name,
            duration_ms: duration_ms,
            detail:      span.detail
          }
        rescue StandardError
          nil
        end
      end
    end
  end
end
