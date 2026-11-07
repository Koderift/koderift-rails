# frozen_string_literal: true

module Koderift
  module Rails
    class Configuration
      # Required: identifies which project this app reports to.
      # Set from an environment variable in the initializer.
      attr_accessor :project_token

      # Public token for Browser RUM, rendered into page HTML by
      # koderift_rum_meta_tag. It can only send browser RUM data, so it is safe
      # to publish (and to commit). Copy it from your project's Log Analytics
      # setup page in Koderift; it starts with "rum_". Never set it to
      # project_token: that is the log agent's ingest secret, and anyone who
      # reads it from your page source can send log lines to your project.
      attr_accessor :rum_token

      # Lambda called with the controller instance to get the current user.
      # Default tries common patterns. Override if your app is different.
      # Example: ->(controller) { controller.current_user }
      attr_accessor :current_user

      # Parameters to filter from captured request params.
      attr_accessor :filter_params

      # Maximum number of breadcrumbs to capture per request.
      attr_accessor :max_breadcrumbs

      # Hosts to exclude from external call tracking (e.g. internal services,
      # localhost, known noise). Always excludes 127.0.0.1 and localhost.
      attr_accessor :external_call_ignore_hosts

      # Whether to enable the instrumentation. Set to false to disable
      # without removing the gem.
      attr_accessor :enabled

      # Whether to enable Browser RUM. Set to false for API-only apps.
      # Defaults to true — the meta tag is harmless if rum.js is not loaded.
      attr_accessor :rum_enabled

      # Fraction of sessions to capture (0.0–1.0). Default 0.1 (10%).
      # Passed to rum.js so sampling happens client-side.
      attr_accessor :rum_sampling_rate

      # Threshold in milliseconds above which a Sidekiq job is marked 'slow'
      # in the emitted log payload. Default 30_000 (30 seconds).
      attr_accessor :slow_job_threshold_ms

      # Ceiling on manual captures (Koderift.capture_exception and friends) per
      # minute, per process. A capture in a hot loop or a retrying job can emit
      # thousands of lines, and raw log lines are the billing source of truth
      # for log storage quota. Set to nil to disable the cap. Drops are always
      # announced on the log -- never silent.
      attr_accessor :max_captures_per_minute

      # Fraction of manual captures to emit (0.0-1.0). Sentry's `sample_rate`.
      # Applies to captures only, never to transactions: silently dropping
      # units of work would make the APM view understate throughput.
      attr_accessor :sample_rate

      # Called with (payload_hash, hint) before a capture is emitted. Return the
      # hash (optionally modified) to emit it, or nil to drop it. Sentry's
      # `before_send`. If this callback itself raises, the ORIGINAL payload is
      # emitted and a warning logged -- a bug in the callback must not silently
      # blind error reporting.
      attr_accessor :before_send

      # Exception class names (as strings) that manual captures ignore, matched
      # against the full ancestor chain. Sentry's `excluded_exceptions`.
      # Defaults to empty: unlike Sentry we never capture automatically, so
      # every call is something the application asked for explicitly.
      attr_accessor :excluded_exceptions

      def initialize
        @project_token     = nil
        @rum_token         = nil
        @current_user      = default_current_user
        @filter_params     = %w[
          password password_confirmation
          token secret authenticity_token
          credit_card cvv ssn
        ]
        @max_breadcrumbs            = 20
        @external_call_ignore_hosts = []
        @enabled                    = true
        @rum_enabled                = true
        @rum_sampling_rate          = 0.1
        @slow_job_threshold_ms      = 30_000
        @max_captures_per_minute    = 100
        @sample_rate                = 1.0
        @before_send                = nil
        @excluded_exceptions        = []
      end

      def valid?
        project_token.present?
      end

      private

      def default_current_user
        lambda do |controller|
          # Try common patterns — override in initializer if different
          if controller.respond_to?(:current_user, true)
            controller.send(:current_user)
          end
        rescue StandardError
          nil
        end
      end
    end
  end
end
