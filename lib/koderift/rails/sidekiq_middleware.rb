# frozen_string_literal: true

require 'json'
require 'securerandom'
require 'koderift/rails/instrumentation'

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
        end
      end

      private

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
          job_class:    job['class'].to_s,
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
