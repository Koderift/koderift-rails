# frozen_string_literal: true

require 'json'
require 'securerandom'
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

        trace_id = job['koderift_trace_id'].to_s
        trace_id = SecureRandom.uuid if trace_id.empty?
        Thread.current[:koderift_trace_id] = trace_id

        # Ambient context for manual captures made anywhere inside the job.
        # The jid stands in for a request id: it is what correlates a capture
        # with the job's own log line, and what carries this job's spans into
        # log_spans (IngestLogBatchJob drops spans on a row with no request id).
        Thread.current[:koderift_context] = {
          component:  job_name(job),
          action:     'perform',
          request_id: job['jid'].to_s
        }

        start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        begin
          result = Instrumentation.capture { yield }
          duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time) * 1000).round
          emit_job_log(worker, job, queue, result, duration_ms, trace_id, error: nil)
          result
        rescue StandardError => e
          duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time) * 1000).round
          empty_result = { spans: [], query_count: 0, partial_count: 0,
                           search_count: 0, breadcrumbs: [] }
          emit_job_log(worker, job, queue, empty_result, duration_ms, trace_id, error: e)
          raise
        ensure
          Thread.current[:koderift_trace_id] = nil
          Thread.current[:koderift_context]  = nil
          # Sidekiq reuses threads across jobs; see the same reset in Controller.
          Koderift::Rails::Scope.reset!
        end
      end

      private

      # The name Sidekiq's own JobLogger logs the job under. For ActiveJob,
      # job['class'] is the adapter's wrapper (Sidekiq::ActiveJob::Wrapper,
      # ActiveJob::QueueAdapters::SidekiqAdapter::JobWrapper) for every job, and
      # job['wrapped'] is the job itself. Matching Sidekiq also lets the agent
      # pair this line with Sidekiq's "done" line for the same attempt.
      def job_name(job)
        (job['wrapped'] || job['class']).to_s
      end

      def emit_job_log(_worker, job, queue, result, duration_ms, trace_id, error:)
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
          trace_id:     trace_id,
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
