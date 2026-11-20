require 'spec_helper'
require 'action_controller'
require 'rails/railtie'
require 'koderift/rails/railtie'

RSpec.describe Koderift::Rails::Railtie do
  # The hooks the 'koderift.include_controller' initializer registers. on_load
  # runs a hook immediately for a base class that has already loaded, and on
  # its first load otherwise, so the order against the requires above does not
  # matter.
  before(:all) { described_class.include_controller_concern }

  # What each base renders; the action also fires the notifications the
  # instrumentation turns into spans: one SQL query and one Searchkick search.
  def self.widget_controller(base)
    Class.new(base) do
      def self.name
        "#{superclass.name.split('::').last}WidgetsController"
      end

      def index
        ActiveSupport::Notifications.instrument('sql.active_record', sql: 'SELECT 1', name: 'Widget Load') {}
        ActiveSupport::Notifications.instrument('search.searchkick', name: 'Message Search') {}
        render json: { ok: true }
      end

      private

      def current_user
        Struct.new(:id).new(42)
      end
    end
  end

  # Runs one GET through the controller as Rails' router would, and returns
  # the payload of its process_action.action_controller event: what lograge
  # turns into the JSON request line.
  def dispatch(controller, headers = {})
    env = Rack::MockRequest.env_for(
      '/widgets?page=2&password=hunter2',
      { 'HTTP_USER_AGENT' => 'spec-agent', 'REMOTE_ADDR' => '203.0.113.9' }.merge(headers)
    )
    env['action_dispatch.request_id']       = 'req-123'
    env['action_dispatch.parameter_filter'] = [:password]

    payloads = []
    subscriber = ActiveSupport::Notifications.subscribe('process_action.action_controller') do |*args|
      payloads << args.last
    end
    status, = controller.action(:index).call(env)
    expect(status).to eq(200)
    payloads.last
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  def koderift_wraps(controller)
    controller._process_action_callbacks.count { |cb| cb.filter == :koderift_instrument_request }
  end

  it 'hooks both of the controller base classes Rails ships' do
    expect(described_class::CONTROLLER_LOAD_HOOKS).to contain_exactly(:action_controller_base, :action_controller_api)
  end

  {
    'ActionController::Base' => -> { ActionController::Base },
    'ActionController::API'  => -> { ActionController::API }
  }.each do |base_name, base|
    context "a controller inheriting from #{base_name}" do
      let(:controller) { self.class.widget_controller(base.call) }

      it 'includes the controller concern' do
        expect(base.call).to include(Koderift::Rails::Controller)
      end

      it 'adds the request context to the request line' do
        payload = dispatch(controller)

        expect(payload).to include(
          koderift_user_id:    42,
          koderift_request_id: 'req-123',
          koderift_ip:         '203.0.113.9',
          koderift_user_agent: 'spec-agent'
        )
        # config.filter_params drops the password key outright.
        expect(payload[:koderift_params]).to eq('page' => '2')
        expect(payload[:koderift_trace_id]).to be_present
      end

      it "keeps a trace ID sent by the calling service" do
        payload = dispatch(controller, 'HTTP_X_KODERIFT_TRACE_ID' => 'trace-from-upstream')

        expect(payload[:koderift_trace_id]).to eq('trace-from-upstream')
      end

      it 'records the spans, counts and breadcrumbs of what the action did' do
        payload = dispatch(controller)

        expect(payload[:koderift_spans].map { |s| [s[:type], s[:name]] })
          .to contain_exactly(%w[sql SELECT\ 1], %w[search Message])
        expect(payload).to include(
          koderift_query_count:   1,
          koderift_partial_count: 0,
          koderift_search_count:  1
        )
        expect(payload[:koderift_breadcrumbs].map { |b| b[:message] }).to eq(['SELECT 1'])
      end

      it 'wraps each action once when the app also includes the concern itself' do
        controller.include(Koderift::Rails::Controller)

        expect(koderift_wraps(controller)).to eq(1)
      end
    end
  end
end
