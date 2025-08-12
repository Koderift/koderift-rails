# frozen_string_literal: true

require 'koderift/rails/version'
require 'koderift/rails/configuration'
require 'koderift/rails/railtie' if defined?(::Rails::Railtie)

module Koderift
  module Rails
    class << self
      def configuration
        @configuration ||= Configuration.new
      end

      def configure
        yield configuration
      end

      def reset!
        @configuration = Configuration.new
      end
    end
  end
end
