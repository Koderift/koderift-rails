# frozen_string_literal: true

require 'time'
require 'active_support/core_ext/string/filters'

module Koderift
  module Rails
    module Instrumentation
      # Subscribes to Rails notifications during a request to capture
      # partial render times, SQL query times, and breadcrumbs.
      # Returns a hash of captured data to be merged into the log payload.
      def self.capture
        partials       = []
        queries        = []
        search_queries = []
        breadcrumbs    = []
        config         = Koderift::Rails.configuration

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

        search_sub = ActiveSupport::Notifications.subscribe('search.searchkick') do |*args|
          event    = ActiveSupport::Notifications::Event.new(*args)
          payload  = event.payload
          duration = (payload[:duration] || event.duration).round
          # payload[:name] is "<ModelName> Search" (e.g. "Admin10 Search")
          # or just "Search" when no model is associated.
          index    = payload[:name].to_s.sub(/\s*Search\z/i, '').strip
          index    = 'unknown' if index.empty?

          search_queries << {
            index:       index,
            duration_ms: duration
          }
        end

        external_calls = []
        Thread.current[:koderift_external_calls]  = external_calls
        Thread.current[:koderift_external_config] = config

        begin
          yield
        ensure
          ActiveSupport::Notifications.unsubscribe(partial_sub)
          ActiveSupport::Notifications.unsubscribe(query_sub)
          ActiveSupport::Notifications.unsubscribe(search_sub)
          Thread.current[:koderift_external_calls]  = nil
          Thread.current[:koderift_external_config] = nil
        end

        top_partials = partials.sort_by { |p| -p[:duration_ms] }
                               .first(config.max_slow_partials)
        top_queries  = queries.sort_by { |q| -q[:duration_ms] }
                              .first(config.max_slow_queries)
        top_search   = search_queries.sort_by { |q| -q[:duration_ms] }
                                     .first(config.max_slow_queries)
        top_external = external_calls.sort_by { |c| -c[:duration_ms] }
                                     .first(config.max_external_calls)

        {
          slow_partials:  top_partials,
          query_stats:    {
            slow_queries:  top_queries,
            query_count:   queries.size,
            partial_count: partials.size
          },
          search_stats:   {
            slow_queries: top_search,
            query_count:  search_queries.size
          },
          external_calls: top_external,
          breadcrumbs:    breadcrumbs.last(config.max_breadcrumbs)
        }
      end

      def self.rails_root_prefix
        defined?(::Rails) && ::Rails.respond_to?(:root) && ::Rails.root ? ::Rails.root.to_s : ''
      end
    end

    # Installed once when the gem loads. Writes to the thread-local
    # external_calls array set by Instrumentation.capture; outside of a
    # capture block the patch is a no-op pass-through.
    module NetHttpPatch
      def request(req, *args, &block)
        calls    = Thread.current[:koderift_external_calls]
        config   = Thread.current[:koderift_external_config]
        trace_id = Thread.current[:koderift_trace_id]

        req['X-Koderift-Trace-ID'] = trace_id if trace_id

        return super(req, *args, &block) unless calls && config

        start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        response   = super(req, *args, &block)
        duration   = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time) * 1000).round

        host    = address.to_s
        ignored = ['127.0.0.1', 'localhost', '[::1]'].include?(host) ||
                  config.external_call_ignore_hosts.any? { |h| host.include?(h) }

        unless ignored
          raw_path = req.path.to_s.split('?').first.to_s
          segments = raw_path.split('/').reject(&:empty?).first(2)
          endpoint = segments.empty? ? '/' : '/' + segments.join('/')

          calls << {
            host:        host,
            endpoint:    endpoint,
            method:      req.method.to_s.upcase,
            status:      response.code.to_i,
            duration_ms: duration,
            trace_id:    trace_id
          }
        end

        response
      end
    end
  end
end

require 'net/http'
Net::HTTP.prepend(Koderift::Rails::NetHttpPatch)
