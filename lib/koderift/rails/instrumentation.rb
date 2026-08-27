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

        # Single-model search: fired by Model.search(...)
        # payload: { name: "Admin10 Search", query: {...} }
        search_sub = ActiveSupport::Notifications.subscribe('search.searchkick') do |*args|
          event    = ActiveSupport::Notifications::Event.new(*args)
          payload  = event.payload
          duration = (payload[:duration] || event.duration).round

          index = payload[:name].to_s.sub(/\s*Search\z/i, '').strip
          index = 'unknown' if index.blank?

          search_queries << { index: index, duration_ms: duration }
        end

        # Multi search: fired by Searchkick.multi_search([...])
        # payload: { name: "Multi Search", body: "..." }
        # Duration covers the entire batch — record as a single entry.
        multi_search_sub = ActiveSupport::Notifications.subscribe('multi_search.searchkick') do |*args|
          event    = ActiveSupport::Notifications::Event.new(*args)
          duration = event.duration.round

          search_queries << { index: 'multi_search', duration_ms: duration }
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
          ActiveSupport::Notifications.unsubscribe(multi_search_sub)
          Thread.current[:koderift_external_calls]  = nil
          Thread.current[:koderift_external_config] = nil
        end

        spans = []

        partials.each_with_index do |p, i|
          spans << { type: 'partial', name: p[:partial], duration_ms: p[:duration_ms], sequence: i }
        end

        queries.each_with_index do |q, i|
          spans << { type: 'sql', name: q[:sql], duration_ms: q[:duration_ms], sequence: i }
        end

        search_queries.each_with_index do |s, i|
          spans << { type: 'search', name: s[:index], duration_ms: s[:duration_ms], sequence: i }
        end

        external_calls.each_with_index do |c, i|
          spans << {
            type:        'http',
            name:        "#{c[:host]}#{c[:endpoint]}",
            duration_ms: c[:duration_ms],
            detail:      { method: c[:method], status: c[:status], trace_id: c[:trace_id] }.compact.to_json,
            sequence:    i
          }
        end

        {
          spans:         spans,
          query_count:   queries.size,
          partial_count: partials.size,
          search_count:  search_queries.size,
          breadcrumbs:   breadcrumbs.last(config.max_breadcrumbs)
        }
      end

      def self.rails_root_prefix
        defined?(::Rails) && ::Rails.respond_to?(:root) && ::Rails.root ? ::Rails.root.to_s : ''
      end
    end

    # Installed once when the gem loads (see the prepend at the bottom of this
    # file). Writes to the thread-local external_calls array set by
    # Instrumentation.capture; outside of a capture block it is a pass-through.
    #
    # CONTRACT: exactly one entry per LOGICAL outbound call. Net::HTTP#request
    # re-enters itself whenever it is called on a session that is not started:
    #
    #   def request(req, body = nil, &block)
    #     unless started?
    #       start { req['connection'] ||= 'close'; return request(req, body, &block) }
    #     end
    #
    # (net-http-0.9.1 lib/net/http.rb:2399-2405). Both frames run this prepended
    # patch, so one call was recorded twice. That branch also forces
    # `Connection: close` and start's ensure closes the socket, so an affected
    # call site double-counts on EVERY call, not intermittently.
    module NetHttpPatch
      def request(req, *args, &block)
        calls    = Thread.current[:koderift_external_calls]
        config   = Thread.current[:koderift_external_config]
        trace_id = Thread.current[:koderift_trace_id]

        req['X-Koderift-Trace-ID'] = trace_id if trace_id

        # Nothing below this line may run before the pass-through return: the
        # spec stand-in defines only #request, and the header injection must
        # still happen when instrumentation is not capturing.
        return super(req, *args, &block) unless calls && config

        # The stdlib recursion re-invokes with the SAME req object, so request
        # identity separates "my own re-entry" from a genuinely different call
        # issued while this one is in flight. Do NOT use `started?` (it keeps
        # the inner frame, which cannot see connection setup, and the stand-in
        # does not define it) and do NOT use an object ivar (one Net::HTTP
        # shared across threads would silently lose most of its spans).
        in_flight = (Thread.current[:koderift_http_in_flight] ||= [])
        return super(req, *args, &block) if in_flight.any? { |r| r.equal?(req) }

        in_flight << req
        start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        begin
          response = super(req, *args, &block)
        ensure
          # Strictly LIFO: the inner frame returns above without pushing, and
          # push/pop are paired in one begin/ensure. The ensure also covers a
          # raise (Net::OpenTimeout, ECONNREFUSED, a raising response block) --
          # without it one failure would silence every later call on this thread.
          in_flight.pop
        end
        duration = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time) * 1000).round

        host    = address.to_s
        ignored = ['127.0.0.1', 'localhost', '[::1]'].include?(host) ||
                  config.external_call_ignore_hosts.any? { |h| host.include?(h) }

        unless ignored
          raw_path = req.path.to_s.split('?').first.to_s
          segments = raw_path.split('/').reject(&:empty?).first(2)
          endpoint = segments.empty? ? '/' : '/' + segments.join('/')

          calls << {
            host: host, endpoint: endpoint, method: req.method.to_s.upcase,
            status: response.code.to_i, duration_ms: duration, trace_id: trace_id
          }
        end

        response
      end
    end
  end
end

require 'net/http'
Net::HTTP.prepend(Koderift::Rails::NetHttpPatch)
