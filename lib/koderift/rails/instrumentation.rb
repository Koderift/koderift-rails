# frozen_string_literal: true

require 'active_support/core_ext/string/filters'

module Koderift
  module Rails
    module Instrumentation
      # Subscribes to Rails notifications during a request to capture
      # partial render times, SQL query times, and breadcrumbs.
      # Returns a hash of captured data to be merged into the log payload.
      def self.capture
        partials    = []
        queries     = []
        breadcrumbs = []
        config      = Koderift::Rails.configuration

        partial_sub = ActiveSupport::Notifications.subscribe('render_partial.action_view') do |*args|
          event      = ActiveSupport::Notifications::Event.new(*args)
          payload    = event.payload
          duration   = (payload[:duration] || event.duration).round
          identifier = payload[:identifier].to_s
                              .sub(rails_root_prefix, '')
                              .sub(%r{\A/app/views/}, '')

          partials << { partial: identifier, duration_ms: duration }
          breadcrumbs << {
            type:        'render',
            message:     identifier,
            duration_ms: duration,
            timestamp:   Time.now.utc.iso8601
          }
        end

        query_sub = ActiveSupport::Notifications.subscribe('sql.active_record') do |*args|
          event   = ActiveSupport::Notifications::Event.new(*args)
          payload = event.payload
          next if payload[:name].to_s.match?(/\A(CACHE|SCHEMA)/)

          duration = (payload[:duration] || event.duration).round
          sql      = payload[:sql].to_s.squish.truncate(300)

          queries << { sql: sql, duration_ms: duration }
          breadcrumbs << {
            type:        'sql',
            message:     sql,
            duration_ms: duration,
            timestamp:   Time.now.utc.iso8601
          }
        end

        begin
          yield
        ensure
          ActiveSupport::Notifications.unsubscribe(partial_sub)
          ActiveSupport::Notifications.unsubscribe(query_sub)
        end

        top_partials = partials.sort_by { |p| -p[:duration_ms] }
                               .first(config.max_slow_partials)
        top_queries  = queries.sort_by { |q| -q[:duration_ms] }
                              .first(config.max_slow_queries)

        {
          slow_partials: top_partials,
          query_stats:   {
            slow_queries:  top_queries,
            query_count:   queries.size,
            partial_count: partials.size
          },
          breadcrumbs: breadcrumbs.last(config.max_breadcrumbs)
        }
      end

      def self.rails_root_prefix
        defined?(::Rails) && ::Rails.respond_to?(:root) && ::Rails.root ? ::Rails.root.to_s : ''
      end
    end
  end
end
