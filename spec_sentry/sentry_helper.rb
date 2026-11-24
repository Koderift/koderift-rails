# frozen_string_literal: true

# The sentry-ruby suite:
#
#   bundle exec rspec spec_sentry
#
# It is kept apart from spec/ because once sentry-ruby is loaded, ::Sentry
# stays defined for the rest of the process, and the main suite has to show
# that the gem works, and changes nothing, without it.
KODERIFT_SENTRY_SUITE = true

require_relative '../spec/spec_helper'
require 'logger'
require 'stringio'
require 'rails'
require 'action_controller'
require 'rails/railtie'
require 'koderift/rails/railtie'
require 'sentry-ruby'

outside = RSpec.configuration.files_to_run.reject { |path| path.include?('/spec_sentry/') }
unless outside.empty?
  abort "spec_sentry loads sentry-ruby, so it must run on its own (not with #{outside.first})"
end

module SentryBridgeHelpers
  DSN = 'http://0a1b2c3d4e5f60718293a4b5c6d7e8f9@localhost:3100/42'

  def init_sentry(**overrides)
    Sentry.init do |config|
      config.dsn                         = DSN
      config.transport.transport_class   = Sentry::DummyTransport
      config.background_worker_threads   = 0
      # sdk_logger from 6.0; 5.x calls it logger.
      config.respond_to?(:sdk_logger=) ? config.sdk_logger = ::Logger.new(nil) : config.logger = ::Logger.new(nil)
      config.auto_session_tracking       = false
      config.send_client_reports         = false
      config.send_modules                = false
      config.enabled_patches             = []
      overrides.each { |key, value| config.public_send("#{key}=", value) }
    end
  end

  def sentry_events
    Sentry.get_main_hub.current_client.transport.events
  end

  def bridge_processors
    Sentry::Scope.global_event_processors.count { |p| p.equal?(Koderift::Rails::SentryBridge::PROCESSOR) }
  end

  def koderift_tags(event)
    event.tags.select { |key, _| %w[request_id koderift_trace_id koderift_span_id].include?(key.to_s) }
              .transform_keys(&:to_s)
  end

  def configure_koderift(token: 'test-token', **options)
    Koderift::Rails.configure do |config|
      config.project_token = token
      config.enabled       = true
      options.each { |key, value| config.public_send("#{key}=", value) }
    end
  end

  # Collects what the gem writes through the real ::Rails.logger.
  def collect_gem_lines
    lines  = []
    logger = Object.new
    %i[debug info warn error fatal].each do |severity|
      logger.define_singleton_method(severity) { |message = nil| lines << [severity, message.to_s]; true }
    end
    allow(::Rails).to receive(:logger).and_return(logger)
    lines
  end

  def json_lines(lines)
    lines.map(&:last).select { |line| line.start_with?('{') }.map { |line| JSON.parse(line) }
  end

  # The payloads lograge turns into request lines, from every thread.
  def collect_request_payloads
    payloads   = Queue.new
    subscriber = ActiveSupport::Notifications.subscribe('process_action.action_controller') do |*args|
      payloads << args.last
    end
    yield
    list = []
    list << payloads.pop until payloads.empty?
    list
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  def rack_env(request_id, path = '/widgets')
    env = Rack::MockRequest.env_for(path)
    env['action_dispatch.request_id'] = request_id
    env
  end
end

RSpec.configure do |config|
  config.include SentryBridgeHelpers

  config.before do
    Sentry.close if Sentry.initialized?
    Sentry::Scope.global_event_processors.clear
    Koderift::Rails::SentryBridge.reset_for_tests!
  end

  config.after do
    Sentry.close if Sentry.initialized?
    Sentry::Scope.global_event_processors.clear
    Koderift::Rails::SentryBridge.reset_for_tests!
  end
end
