# frozen_string_literal: true

begin
  require 'lograge'
rescue LoadError
  # lograge not available — instrumentation will be skipped
end

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

      # Some gems give every object a public `logger` method, usually through a
      # top-level `include` of a module that defines one. data-anonymization
      # 0.9.1 does this, and its logger writes to STDOUT. OrderedOptions reads
      # its keys through method_missing, so a real method always wins, and
      # `config.lograge.logger` returns that gem's logger whether or not the app
      # set one. Lograge.setup copies it into Lograge.logger, and the JSON
      # request line goes wherever it writes instead of to the log the agent
      # tails. Nothing else warns.
      #
      # Called after Lograge.setup. Points Lograge.logger back at the value the
      # app stored in config.lograge.logger. When the app stored none, that is
      # nil, and lograge falls back to Rails.logger as it normally would. Does
      # nothing unless a real method shadows the key and Lograge.logger holds
      # something other than the stored value.
      def self.release_hijacked_logger(app)
        return unless defined?(Lograge)

        options = app.config.lograge
        hijacker = shadowing_logger_method(options)
        return if hijacker.nil?

        configured = options[:logger]
        return if Lograge.logger.equal?(configured)

        Lograge.logger = configured
        log_warning(hijacked_logger_warning(hijacker, configured))
      end

      def self.shadowing_logger_method(options)
        return nil unless options.is_a?(ActiveSupport::OrderedOptions)
        return nil unless options.class.public_method_defined?(:logger)

        options.class.instance_method(:logger)
      end

      def self.hijacked_logger_warning(hijacker, configured)
        owner    = hijacker.owner.name || hijacker.owner.inspect
        location = hijacker.source_location&.join(':')
        source   = location ? "#{owner} (#{location})" : owner
        target   = configured.nil? ? 'Rails.logger' : 'the logger set in config.lograge.logger'

        "[Koderift] #{source} defines a public `logger` method on every object. " \
          'ActiveSupport::OrderedOptions lets that method shadow its own keys, so ' \
          'config.lograge.logger returned that logger, and Koderift JSON request ' \
          'lines went to it instead of the log the Koderift agent tails. Koderift ' \
          "has pointed lograge back at #{target}. ActionController::Base.logger, " \
          "ActiveRecord::Base.logger and Rails' own request lines (Processing by, " \
          'Completed, SQL) are probably redirected to that logger too, and Koderift ' \
          'does not change those. Stop the gem that defines it from loading at ' \
          'boot, for example with `require: false` in the Gemfile.'
      end

      def self.log_warning(message)
        return unless defined?(::Rails) && ::Rails.respond_to?(:logger)

        ::Rails.logger&.warn(message)
      rescue StandardError
        nil
      end

      def self.format_backtrace(exception)
        format_frames(exception&.backtrace)
      end

      # Split out from format_backtrace so a caller holding a raw backtrace
      # array -- Capture, when given an explicit `backtrace:` -- gets the same
      # frame selection instead of a second, subtly different implementation.
      def self.format_frames(backtrace)
        return nil unless backtrace.is_a?(Array) && backtrace.any?

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
