# frozen_string_literal: true

module Koderift
  module Rails
    class Configuration
      # Required: identifies which project this app reports to.
      # Set from an environment variable in the initializer.
      attr_accessor :project_token

      # Lambda called with the controller instance to get the current user.
      # Default tries common patterns. Override if your app is different.
      # Example: ->(controller) { controller.current_user }
      attr_accessor :current_user

      # Parameters to filter from captured request params.
      attr_accessor :filter_params

      # Maximum number of breadcrumbs to capture per request.
      attr_accessor :max_breadcrumbs

      # Maximum number of slow partials to capture per request.
      attr_accessor :max_slow_partials

      # Maximum number of slow queries to capture per request.
      attr_accessor :max_slow_queries

      # Whether to enable the instrumentation. Set to false to disable
      # without removing the gem.
      attr_accessor :enabled

      def initialize
        @project_token     = nil
        @current_user      = default_current_user
        @filter_params     = %w[
          password password_confirmation
          token secret authenticity_token
          credit_card cvv ssn
        ]
        @max_breadcrumbs   = 20
        @max_slow_partials = 5
        @max_slow_queries  = 5
        @enabled           = true
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
