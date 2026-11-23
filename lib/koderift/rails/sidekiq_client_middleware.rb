# frozen_string_literal: true

require 'koderift/rails/trace_context'

module Koderift
  module Rails
    # Sidekiq client middleware: carries the enqueuing unit's trace into the
    # job, so a request and the jobs it enqueues share one trace and each job
    # names the span that enqueued it as its parent.
    #
    # Registered for clients in every process, including Sidekiq servers,
    # because jobs enqueue jobs.
    class SidekiqClientMiddleware
      def call(_job_class, job, _queue, _redis_pool = nil)
        inject(job)
        yield
      end

      private

      # Keys already on the job are never replaced. A retry, a scheduled job
      # moved onto its queue by the poller, or a job someone gave a trace by
      # hand all keep the trace they were enqueued with.
      #
      # koderift_trace_id is still written alongside koderift_traceparent
      # because servers running gem versions before 2.2 read only that key.
      def inject(job)
        return unless job.is_a?(Hash)
        return if job.key?('koderift_traceparent') || job.key?('koderift_trace_id')

        trace_id = TraceContext::Current.trace_id
        return if trace_id.nil? || trace_id.to_s.empty?

        traceparent = TraceContext::Current.traceparent
        job['koderift_traceparent'] = traceparent if traceparent
        job['koderift_trace_id']    = trace_id
      rescue StandardError
        nil
      end
    end
  end
end
