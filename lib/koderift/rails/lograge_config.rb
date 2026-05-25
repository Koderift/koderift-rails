# frozen_string_literal: true

module Koderift
  module Rails
    module LogrageConfig
      MAX_FRAMES     = 50
      LEADING_FRAMES = 10

      def self.apply(app)
        return unless defined?(Lograge)

        app.config.lograge.enabled                = true
        app.config.lograge.keep_original_rails_log = true
        app.config.lograge.formatter              = Lograge::Formatters::Json.new

        app.config.lograge.custom_options = lambda do |event|
          exceptions = event.payload[:exception_object]

          {
            user_id:       event.payload[:koderift_user_id],
            host:          event.payload[:koderift_host],
            db:            event.payload[:db_runtime]&.round(2),
            exception:     event.payload[:exception]&.join(': '),
            request_id:    event.payload[:koderift_request_id],
            trace_id:      event.payload[:koderift_trace_id],
            ip:            event.payload[:koderift_ip],
            user_agent:    event.payload[:koderift_user_agent],
            allocations:   event.payload[:allocations],
            error_cause:   exceptions&.cause&.message,
            stack_trace:   format_backtrace(exceptions),
            referer:       event.payload[:koderift_referer],
            breadcrumbs:   event.payload[:koderift_breadcrumbs],
            params:        event.payload[:koderift_params],
            spans:         event.payload[:koderift_spans],
            query_count:   event.payload[:koderift_query_count],
            partial_count: event.payload[:koderift_partial_count],
            search_count:  event.payload[:koderift_search_count]
          }.compact
        end
      end

      def self.format_backtrace(exception)
        return nil unless exception&.backtrace&.any?

        backtrace = exception.backtrace

        leading = backtrace.first(LEADING_FRAMES)

        rest = backtrace[LEADING_FRAMES..]&.select { |l| l.include?('/app/') } || []

        frames = (leading + rest).first(MAX_FRAMES)

        if frames.size < MAX_FRAMES
          non_app_rest = backtrace[LEADING_FRAMES..]&.reject { |l| l.include?('/app/') } || []
          frames = (frames + non_app_rest).first(MAX_FRAMES)
        end

        frames.join("\n").presence
      rescue StandardError
        nil
      end
    end
  end
end
