# frozen_string_literal: true

require 'json'
require 'koderift/rails/trace_context'
require 'koderift/rails/instrumentation'
require 'koderift/rails/scope'

module Koderift
  module Rails
    # Sidekiq server middleware that wraps each job in Instrumentation.capture
    # and writes a single JSON line to Rails.logger. The koderift-agent picks
    # this up via the existing Rails log tailer — the "job_class" key
    # distinguishes it from Lograge request lines.
    class SidekiqMiddleware
      def call(worker, job, queue)
        config = Koderift::Rails.configuration
        return yield unless config.enabled && config.project_token.present?

        started_at_ms = TraceContext.now_ms
        trace_frame   = start_trace(job, started_at_ms)
        trace         = trace_fields(trace_frame)

        begin
          result = Instrumentation.capture(started_at_ms: started_at_ms) { yield }
          duration_ms = (TraceContext.now_ms - started_at_ms).round
          emit_job_log(worker, job, queue, result, duration_ms, trace, error: nil)
          result
        rescue StandardError => e
          duration_ms = (TraceContext.now_ms - started_at_ms).round
          empty_result = { spans: [], query_count: 0, partial_count: 0,
                           search_count: 0, breadcrumbs: [] }
          emit_job_log(worker, job, queue, empty_result, duration_ms, trace, error: e)
          raise
        ensure
          if trace_frame
            # Clears the trace and context, or, for a job run with
            # perform_inline inside another unit, hands that unit back its own.
            TraceContext::Current.pop(trace_frame)
          else
            Thread.current[:koderift_trace_id] = nil
            Thread.current[:koderift_context]  = nil
          end
          # Sidekiq reuses threads across jobs; see the same reset in Controller.
          Koderift::Rails::Scope.reset!
        end
      end

      private

      # Continues the trace the client middleware stored on the job, else the
      # legacy trace ID key, else starts one (TraceContext.from_job).
      #
      # Ambient context for manual captures made anywhere inside the job.
      # The jid stands in for a request id: it is what correlates a capture
      # with the job's own log line, and what carries this job's spans into
      # log_spans (IngestLogBatchJob drops spans on a row with no request id).
      def start_trace(job, started_at_ms)
        context = {
          component:  job_name(job),
          action:     'perform',
          request_id: job['jid'].to_s
        }
        trace = TraceContext.from_job(job)

        TraceContext::Current.push(
          kind:           :job,
          trace_id:       trace[:trace_id],
          parent_span_id: trace[:parent_span_id],
          flags:          trace[:flags],
          context:        context,
          started_at_ms:  started_at_ms
        )
      rescue StandardError
        Thread.current[:koderift_context] = context
        nil
      end

      def trace_fields(frame)
        return { trace_id: Thread.current[:koderift_trace_id] } unless frame

        {
          trace_id:       frame.trace_id,
          span_id:        frame.root_span_id,
          parent_span_id: frame.parent_span_id,
          started_at:     frame.started_at
        }
      end

      # The name Sidekiq's own JobLogger logs the job under. For ActiveJob,
      # job['class'] is the adapter's wrapper (Sidekiq::ActiveJob::Wrapper,
      # ActiveJob::QueueAdapters::SidekiqAdapter::JobWrapper) for every job, and
      # job['wrapped'] is the job itself. Matching Sidekiq also lets the agent
      # pair this line with Sidekiq's "done" line for the same attempt.
      def job_name(job)
        (job['wrapped'] || job['class']).to_s
      end

      def emit_job_log(_worker, job, queue, result, duration_ms, trace, error:)
        config = Koderift::Rails.configuration

        level = if error
          'error'
        elsif duration_ms >= config.slow_job_threshold_ms
          'slow'
        else
          'info'
        end

        payload = {
          job_class:    job_name(job),
          jid:          job['jid'].to_s,
          queue:        queue.to_s,
          status:       error ? 500 : 200,
          duration:     duration_ms,
          level:        level,
          trace_id:       trace[:trace_id],
          span_id:        trace[:span_id],
          parent_span_id: trace[:parent_span_id],
          started_at:     trace[:started_at],
          spans:        result[:spans],
          query_count:  result[:query_count],
          search_count: result[:search_count],
          breadcrumbs:  result[:breadcrumbs]
        }

        if error
          payload[:exception] = "#{error.class}: #{error.message}"
          bt = error.backtrace&.first(20)&.join("\n")
          payload[:stack_trace] = bt if bt && !bt.empty?
        end

        ::Rails.logger.info(payload.compact.to_json)
      rescue StandardError => e
        ::Rails.logger.warn("[KoderiftSidekiqMiddleware] emit failed: #{e.message}")
      end
    end
  end
end
