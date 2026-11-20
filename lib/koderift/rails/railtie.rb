# frozen_string_literal: true

require 'rails/railtie'

module Koderift
  module Rails
    class Railtie < ::Rails::Railtie
      # Configure Lograge after the app initializers have run
      # (so the user's initializer sets up Koderift.configure first)
      initializer 'koderift.configure_lograge', after: :load_config_initializers do |app|
        next unless Koderift::Rails.configuration.enabled

        require 'koderift/rails/lograge_config'
        Koderift::Rails::LogrageConfig.apply(app)

        # Lograge.setup runs in lograge's own after_initialize hook, which is
        # registered when lograge is first required. That has happened by now,
        # because lograge_config requires it. Hooks run in registration order,
        # so registering this one here makes it run after Lograge.setup.
        app.config.after_initialize do |application|
          Koderift::Rails::LogrageConfig.release_hijacked_logger(application)
        end
      end

      # ActionController::API is a second base class, not a subclass of
      # ActionController::Base. Hooking only Base left every API controller --
      # all of an API-only app, or an app's JSON API namespace -- without the
      # around_action: lograge still wrote the request line, but with no spans,
      # breadcrumbs, params, trace ID or user, so its trace showed the whole
      # request as unexplained Ruby time.
      CONTROLLER_LOAD_HOOKS = %i[action_controller_base action_controller_api].freeze

      def self.include_controller_concern
        CONTROLLER_LOAD_HOOKS.each do |hook|
          ActiveSupport.on_load(hook) do
            require 'koderift/rails/controller'
            include Koderift::Rails::Controller
          end
        end
      end

      initializer 'koderift.include_controller', after: :load_config_initializers do
        next unless Koderift::Rails.configuration.enabled

        Koderift::Rails::Railtie.include_controller_concern
      end

      # Make koderift_rum_meta_tag available in all views
      initializer 'koderift.helpers', after: :load_config_initializers do
        next unless Koderift::Rails.configuration.enabled

        ActiveSupport.on_load(:action_view) do
          require 'koderift/rails/rum_helper'
          include Koderift::Rails::RumHelper
        end
      end

      # Capture uncaught rake task failures. Rake is loaded before the Rails
      # environment under `bundle exec rake` / `bin/rails <task>`, so the
      # constant is present by the time initializers run; under a web server it
      # is not, and the guard makes this a no-cost skip.
      initializer 'koderift.rake_integration', after: :load_config_initializers do
        next unless Koderift::Rails.configuration.enabled
        next unless defined?(::Rake::Application)

        require 'koderift/rails/rake_integration'
        unless ::Rake::Application.include?(Koderift::Rails::RakeIntegration)
          ::Rake::Application.prepend(Koderift::Rails::RakeIntegration)
        end
      end

      # Register Sidekiq server middleware lazily when Sidekiq is present.
      initializer 'koderift.sidekiq_middleware', after: :load_config_initializers do
        next unless Koderift::Rails.configuration.enabled

        ActiveSupport.on_load(:after_initialize) do
          if defined?(Sidekiq) && Sidekiq.respond_to?(:configure_server)
            require 'koderift/rails/sidekiq_middleware'
            Sidekiq.configure_server do |sidekiq_config|
              sidekiq_config.server_middleware do |chain|
                chain.add Koderift::Rails::SidekiqMiddleware
              end
            end
          end
        end
      end
    end
  end
end
