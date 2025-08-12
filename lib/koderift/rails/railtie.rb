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
      end

      # Include the controller concern into ActionController::Base
      initializer 'koderift.include_controller', after: :load_config_initializers do
        next unless Koderift::Rails.configuration.enabled

        ActiveSupport.on_load(:action_controller_base) do
          require 'koderift/rails/controller'
          include Koderift::Rails::Controller
        end
      end
    end
  end
end
