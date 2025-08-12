# frozen_string_literal: true

module Koderift
  module Rails
    module LogrageConfig
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
            ip:            event.payload[:koderift_ip],
            user_agent:    event.payload[:koderift_user_agent],
            allocations:   event.payload[:allocations],
            error_cause:   exceptions&.cause&.message,
            referer:       event.payload[:koderift_referer],
            breadcrumbs:   event.payload[:koderift_breadcrumbs],
            params:        event.payload[:koderift_params],
            slow_partials: event.payload[:koderift_slow_partials],
            query_stats:   event.payload[:koderift_query_stats]
          }.compact
        end
      end
    end
  end
end
