require 'spec_helper'
require 'action_controller'
require 'rails/railtie'
require 'koderift/rails/railtie'

# Trace context on a real controller dispatch: which incoming header wins,
# what the request line carries, how its spans nest, what an outbound call
# from the action sends, and that nothing is left on the thread afterwards.
RSpec.describe 'request trace context' do
  before(:all) { Koderift::Rails::Railtie.include_controller_concern }

  let(:trace_id) { '4bf92f3577b34da6a3ce929d0e0e4736' }
  let(:span_id)  { '00f067aa0ba902b7' }

  # A started Net::HTTP stand-in that keeps the request it was handed.
  let(:http) do
    Class.new do
      attr_reader :address, :last_request

      def initialize
        @address = 'api.example.com'
      end

      def started?
        true
      end

      def request(req, _body = nil, &_block)
        @last_request = req
        Net::HTTPResponse.new('1.1', '200', 'OK')
      end
    end.tap { |c| c.prepend(Koderift::Rails::NetHttpPatch) }.new
  end

  let(:controller) do
    outbound = http
    Class.new(ActionController::Base) do
      define_singleton_method(:name) { 'TraceWidgetsController' }
      define_method(:outbound) { outbound }

      def index
        ActiveSupport::Notifications.instrument('sql.active_record', sql: 'SELECT outside', name: 'Load') {}
        sleep 0.002
        Koderift.with_child_span(op: 'work') do
          sleep 0.002
          ActiveSupport::Notifications.instrument('sql.active_record', sql: 'SELECT inside', name: 'Load') {}
        end
        render json: { ok: true }
      end

      def call_out
        outbound.request(Net::HTTP::Get.new('/v1/things'))
        render json: { ok: true }
      end

      def boom
        Koderift.with_child_span(op: 'open') { raise 'boom' }
      end
    end
  end

  def env_for(headers)
    env = Rack::MockRequest.env_for('/widgets', headers)
    env['action_dispatch.request_id'] = 'req-123'
    env
  end

  # The payload of process_action.action_controller, which lograge turns into
  # the request line.
  def dispatch(headers = {}, action: :index)
    payloads   = []
    subscriber = ActiveSupport::Notifications.subscribe('process_action.action_controller') do |*args|
      payloads << args.last
    end
    status, = controller.action(action).call(env_for(headers))
    expect(status).to eq(200)
    payloads.last
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  # What lograge would write for that payload.
  def lograge_line(payload)
    options = ActiveSupport::OrderedOptions.new
    app     = Struct.new(:config).new(Struct.new(:lograge).new(options))
    Koderift::Rails::LogrageConfig.apply(app)
    options.custom_options.call(Struct.new(:payload).new(payload))
  end

  def published_state
    %i[koderift_trace_id koderift_context koderift_breadcrumbs koderift_custom_spans
       koderift_external_calls koderift_external_config koderift_trace_frames
       koderift_capture_frames].map { |key| Thread.current[key] }
  end

  describe 'which incoming header wins' do
    it 'continues a traceparent: the request line carries its trace ID and parent' do
      line = lograge_line(dispatch({ 'HTTP_TRACEPARENT' => "00-#{trace_id}-#{span_id}-01" }))

      expect(line[:trace_id]).to eq(trace_id)
      expect(line[:parent_span_id]).to eq(span_id)
      expect(line[:span_id]).to match(/\A[0-9a-f]{16}\z/)
      expect(line[:span_id]).not_to eq(span_id)
      expect(line[:started_at]).to match(/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z\z/)
    end

    it 'continues a sentry-trace header when there is no traceparent' do
      line = lograge_line(dispatch({ 'HTTP_SENTRY_TRACE' => "#{trace_id}-#{span_id}-1" }))

      expect(line).to include(trace_id: trace_id, parent_span_id: span_id)
    end

    it "prefers the gem's own X-Koderift-Traceparent to a traceparent an APM rewrote" do
      line = lograge_line(dispatch({
        'HTTP_X_KODERIFT_TRACEPARENT' => "00-#{trace_id}-#{span_id}-01",
        'HTTP_TRACEPARENT'            => '00-cccccccccccccccccccccccccccccccc-dddddddddddddddd-01'
      }))

      expect(line).to include(trace_id: trace_id, parent_span_id: span_id)
    end

    it 'follows an older Koderift caller over the Sentry trace it also sends' do
      line = lograge_line(dispatch({
        'HTTP_SENTRY_TRACE'        => 'cccccccccccccccccccccccccccccccc-dddddddddddddddd-1',
        'HTTP_X_KODERIFT_TRACE_ID' => '4bf92f35-77b3-4da6-a3ce-929d0e0e4736'
      }))

      expect(line[:trace_id]).to eq(trace_id)
      expect(line).not_to have_key(:parent_span_id)
    end

    it 'normalises a legacy UUID header, with no parent' do
      line = lograge_line(dispatch({ 'HTTP_X_KODERIFT_TRACE_ID' => '4bf92f35-77b3-4da6-a3ce-929d0e0e4736' }))

      expect(line[:trace_id]).to eq(trace_id)
      expect(line).not_to have_key(:parent_span_id)
    end

    it 'starts a new 32-hex trace when nothing usable arrives' do
      [{}, { 'HTTP_TRACEPARENT' => 'garbage' }, { 'HTTP_X_KODERIFT_TRACE_ID' => 'trace-from-upstream' }].each do |headers|
        line = lograge_line(dispatch(headers))

        expect(line[:trace_id]).to match(/\A[0-9a-f]{32}\z/)
        expect(line).not_to have_key(:parent_span_id)
      end
    end
  end

  describe 'spans' do
    let(:spans) { dispatch[:koderift_spans] }

    it 'nests a query inside with_child_span under that span, and leaves the parent out for the root' do
      custom  = spans.find { |s| s[:type] == 'custom' }
      inside  = spans.find { |s| s[:name] == 'SELECT inside' }
      outside = spans.find { |s| s[:name] == 'SELECT outside' }

      expect(inside[:parent_span_id]).to eq(custom[:span_id])
      expect(outside).not_to have_key(:parent_span_id)
      expect(custom).not_to have_key(:parent_span_id)
    end

    it 'gives every span a unique ID and a start offset in real order' do
      expect(spans.map { |s| s[:span_id] }.uniq.size).to eq(spans.size)

      starts = %w[SELECT\ outside work SELECT\ inside].map do |name|
        spans.find { |s| s[:name] == name }[:start_ms]
      end
      expect(starts).to all(be_a(Integer))
      expect(starts).to eq(starts.sort)
      expect(starts.first).to be < starts.last
    end
  end

  describe 'an outbound call from the action' do
    it 'sends traceparent naming the HTTP span, and our own copy of it' do
      payload = dispatch({ 'HTTP_TRACEPARENT' => "00-#{trace_id}-#{span_id}-01", 'HTTP_TRACESTATE' => 'rojo=1' },
                         action: :call_out)
      sent      = http.last_request
      http_span = payload[:koderift_spans].find { |s| s[:type] == 'http' }

      expect(sent['traceparent']).to eq("00-#{trace_id}-#{http_span[:span_id]}-01")
      expect(sent['X-Koderift-Traceparent']).to eq(sent['traceparent'])
      expect(sent['X-Koderift-Trace-ID']).to eq(trace_id)
      expect(sent['tracestate']).to eq('rojo=1')
      expect(http_span).not_to have_key(:parent_span_id)
    end
  end

  it 'leaves nothing on the thread after an action that raises' do
    expect { controller.action(:boom).call(env_for({})) }.to raise_error('boom')

    expect(published_state).to all(be_nil)
  end
end
