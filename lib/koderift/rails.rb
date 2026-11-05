# frozen_string_literal: true

require 'koderift/rails/version'
require 'koderift/rails/configuration'
require 'koderift/rails/instrumentation'
require 'koderift/rails/lograge_config'
require 'koderift/rails/event'
require 'koderift/rails/breadcrumb'
require 'koderift/rails/scope'
require 'koderift/rails/capture'
require 'koderift/rails/tracing'
require 'koderift/rails/controller'
require 'koderift/rails/rum_helper'
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
        Capture.reset_rate_limiter!
        Scope.reset!
        Breadcrumbs.clear
      end

      # ---------------------------------------------------------------- capture

      def capture_exception(error, **options, &block)
        Capture.exception(error, **options, &block)
      end

      def capture_message(text, **options, &block)
        Capture.message(text, **options, &block)
      end

      def capture_event(event)
        Capture.event(event)
      end

      def last_event_id
        Capture.last_event_id
      end

      def initialized?
        Capture.initialized?
      end

      def exception_captured?(error)
        Capture.exception_captured?(error)
      end

      # ------------------------------------------------------------------ scope

      def get_current_scope
        Scope.current
      end

      def configure_scope
        yield Scope.current if block_given?
        Scope.current
      end

      def with_scope
        Scope.push
        begin
          yield Scope.current
        ensure
          Scope.pop
        end
      end

      def set_user(user)
        Scope.current.set_user(user)
      end

      def set_tags(tags)
        Scope.current.set_tags(tags)
      end

      def set_tag(key, value)
        Scope.current.set_tag(key, value)
      end

      def set_extras(extras)
        Scope.current.set_extras(extras)
      end

      def set_extra(key, value)
        Scope.current.set_extra(key, value)
      end

      def set_context(key, value)
        Scope.current.set_context(key, value)
      end

      def add_breadcrumb(crumb)
        Breadcrumbs.add(crumb)
      end

      # ---------------------------------------------------------------- tracing

      def start_transaction(name: nil, op: nil, &block)
        Tracing.start_transaction(name: name, op: op, &block)
      end

      def with_child_span(op: nil, description: nil, &block)
        Tracing.with_child_span(op: op, description: description, &block)
      end
    end
  end

  # Sentry-shaped constant, so `Sentry::Breadcrumb.new(...)` becomes
  # `Koderift::Breadcrumb.new(...)` under the same find-and-replace that
  # rewrites the method calls.
  Breadcrumb = Rails::Breadcrumb

  # The migration surface. An app instrumented with Sentry swaps the namespace
  # and keeps its call sites, including the idiom this API was built for:
  #
  #   event_id = Koderift.capture_exception(error)&.event_id
  #
  # Delegators are written out rather than metaprogrammed so the signatures are
  # greppable and `method(:capture_exception).parameters` tells the truth.
  class << self
    def capture_exception(error, **options, &block)
      Rails.capture_exception(error, **options, &block)
    end

    def capture_message(text, **options, &block)
      Rails.capture_message(text, **options, &block)
    end

    def capture_event(event)
      Rails.capture_event(event)
    end

    def last_event_id
      Rails.last_event_id
    end

    def initialized?
      Rails.initialized?
    end

    def exception_captured?(error)
      Rails.exception_captured?(error)
    end

    def get_current_scope
      Rails.get_current_scope
    end

    def configure_scope(&block)
      Rails.configure_scope(&block)
    end

    def with_scope(&block)
      Rails.with_scope(&block)
    end

    def set_user(user)
      Rails.set_user(user)
    end

    def set_tags(tags)
      Rails.set_tags(tags)
    end

    def set_tag(key, value)
      Rails.set_tag(key, value)
    end

    def set_extras(extras)
      Rails.set_extras(extras)
    end

    def set_extra(key, value)
      Rails.set_extra(key, value)
    end

    def set_context(key, value)
      Rails.set_context(key, value)
    end

    def add_breadcrumb(crumb)
      Rails.add_breadcrumb(crumb)
    end

    def start_transaction(name: nil, op: nil, &block)
      Rails.start_transaction(name: name, op: op, &block)
    end

    def with_child_span(op: nil, description: nil, &block)
      Rails.with_child_span(op: op, description: description, &block)
    end

    def configure(&block)
      Rails.configure(&block)
    end

    def configuration
      Rails.configuration
    end
  end
end
