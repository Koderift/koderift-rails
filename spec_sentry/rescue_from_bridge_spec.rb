# frozen_string_literal: true

require_relative 'sentry_helper'
require 'koderift/rails/sidekiq_middleware'

# A rescue_from handler that reports both ways, the way most Rails apps report
# handled errors. sentry-rails never reports a rescue_from-handled exception
# itself, so Sentry's event is the handler's own Sentry.capture_exception. It
# must share the gem capture's request_id, so Koderift counts the pair once,
# and its koderift_* tags must be the capture's trace and span.
RSpec.describe 'the sentry-ruby bridge in rescue_from handlers' do
  before(:all) { Koderift::Rails::Railtie.include_controller_concern }

  let!(:gem_lines) { collect_gem_lines }

  # The Railtie installs the bridge once the app has booted; a request whose
  # hook never runs would not install it on its own.
  before do
    configure_koderift
    init_sentry
    Koderift::Rails::SentryBridge.install_if_ready
  end

  let(:controller) do
    Class.new(ActionController::Base) do
      define_singleton_method(:name) { 'RescueBridgeController' }

      prepend_before_action { raise ArgumentError, 'raised before the hook' if action_name == 'prehook' }
      rescue_from StandardError, with: :report_and_render

      def boom
        nil.upcase
      end

      def prehook; end

      def tagged
        raise KeyError, 'tagged by the app'
      end

      private

      def report_and_render(error)
        Koderift.capture_exception(error)
        if action_name == 'tagged'
          Sentry.capture_exception(error, tags: { 'request_id' => 'another-request' })
        else
          Sentry.capture_exception(error)
        end
        head 500
      end
    end
  end

  # Through Sentry's Rack middleware, as sentry-rails installs it: Sentry's
  # event then carries the env's request_id itself.
  def through_sentry_rack(action, request_id)
    collect_request_payloads do
      Sentry::Rack::CaptureExceptions.new(controller.action(action)).call(rack_env(request_id))
    end.last
  end

  # Without the middleware: Sentry's event has no request_id of its own.
  def without_rack(action, request_id)
    collect_request_payloads { controller.action(action).call(rack_env(request_id)) }.last
  end

  def gem_capture
    json_lines(gem_lines).find { |line| line['koderift_capture'] }
  end

  describe 'with the request_id Sentry takes from the Rack env' do
    it "pairs: the same request_id, and Sentry's koderift tags are the capture's trace and span" do
      payload = through_sentry_rack(:boom, 'req-77')
      event   = sentry_events.last
      capture = gem_capture

      expect(sentry_events.size).to eq(1)
      expect(event.tags[:request_id]).to eq('req-77')
      expect(capture['request_id']).to eq('req-77')
      expect(capture['exception']).to start_with('NoMethodError: ')
      expect(event.exception.values.last.type).to eq('NoMethodError')

      expect(capture['trace_id']).to eq(payload[:koderift_trace_id])
      expect(capture['span_id']).to eq(payload[:koderift_span_id])
      expect(event.tags['koderift_trace_id']).to eq(capture['trace_id'])
      expect(event.tags['koderift_span_id']).to eq(capture['span_id'])
    end

    it 'pairs when the exception was raised before the hook: request_id only, on both' do
      payload = through_sentry_rack(:prehook, 'req-78')
      event   = sentry_events.last
      capture = gem_capture

      expect(event.tags[:request_id]).to eq('req-78')
      expect(capture['request_id']).to eq('req-78')
      expect(capture).not_to include('trace_id', 'span_id')
      expect(payload[:koderift_trace_id]).to be_nil
      expect(koderift_tags(event).keys).to eq(['request_id'])
    end

    it 'adds nothing to an event whose own request_id names another request' do
      through_sentry_rack(:tagged, 'req-79')
      event = sentry_events.last

      expect(event.tags['request_id']).to eq('another-request')
      expect(event.tags).not_to include('koderift_trace_id', 'koderift_span_id')
      expect(gem_capture['request_id']).to eq('req-79')
    end
  end

  describe 'with no request_id on the Sentry event (no Rack middleware)' do
    it "gives it the request's ID, trace and span, the capture's" do
      payload = without_rack(:boom, 'req-80')
      event   = sentry_events.last
      capture = gem_capture

      expect(koderift_tags(event)).to eq(
        'request_id'        => 'req-80',
        'koderift_trace_id' => payload[:koderift_trace_id],
        'koderift_span_id'  => payload[:koderift_span_id]
      )
      expect(capture.slice('request_id', 'trace_id', 'span_id')).to eq(
        'request_id' => 'req-80',
        'trace_id'   => payload[:koderift_trace_id],
        'span_id'    => payload[:koderift_span_id]
      )
    end

    it 'gives it the request ID only when the hook never ran' do
      without_rack(:prehook, 'req-81')

      expect(koderift_tags(sentry_events.last)).to eq('request_id' => 'req-81')
      expect(gem_capture['request_id']).to eq('req-81')
    end
  end

  # sentry-sidekiq tags every event in a job with its jid, and Koderift pairs
  # on the jid first, so a handler in a controller a job dispatches keeps the
  # job's context, as before 2.3.1.
  it 'pairs a handler in a controller run inside a Sidekiq job by the jid' do
    job = { 'class' => 'WarmCacheJob', 'jid' => 'jid-90' }
    Koderift::Rails::SidekiqMiddleware.new.call(nil, job, 'default') do
      Sentry.with_scope do |scope|
        scope.set_tags(jid: 'jid-90', queue: 'default')
        Sentry::Rack::CaptureExceptions.new(controller.action(:boom)).call(rack_env('req-in-job'))
      end
    end
    event   = sentry_events.last
    capture = gem_capture

    expect(event.tags[:jid]).to eq('jid-90')
    expect(capture['request_id']).to eq('jid-90')
    expect(event.tags['koderift_trace_id']).to eq(capture['trace_id'])
    expect(event.tags['koderift_span_id']).to eq(capture['span_id'])
  end

  it 'leaves nothing on the thread, so a later keyless event gets no tags' do
    without_rack(:boom, 'req-82')
    Sentry.capture_message('after the request')

    expect(koderift_tags(sentry_events.last)).to eq({})
    expect(Thread.current[:koderift_rescue_view]).to be_nil
  end
end
