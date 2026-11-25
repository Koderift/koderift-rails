# frozen_string_literal: true

require 'spec_helper'
require 'action_controller'
require 'rails/railtie'
require 'koderift/rails/railtie'
require 'koderift/rails/sidekiq_middleware'
require 'koderift/rails/sidekiq_client_middleware'
require 'concurrent'
require 'timeout'

class RescueFromSpecWrapperError < StandardError; end
class RescueFromSpecSecondError < StandardError; end
RescueFromSpecUser = Struct.new(:id)

# ActionController::Rescue runs a rescue_from handler after the gem's
# around_action has finished. A capture in the handler must still carry the
# request (RescueContext), the request line must not change, and nothing may
# be left on the thread for the next request.
RSpec.describe 'captures in rescue_from handlers' do
  include_context 'a captured log'
  before(:all) { Koderift::Rails::Railtie.include_controller_concern }

  after do
    txn = Koderift::Rails::Tracing.current_transaction
    txn.finish if txn && !txn.finished?
    Koderift::Rails::Tracing.clear_current(txn) if txn
    Koderift::Rails.reset!
  end

  # Every thread key the gem writes, the rescue view's included.
  RESCUE_SPEC_THREAD_KEYS = %i[
    koderift_trace_id koderift_context koderift_breadcrumbs koderift_custom_spans
    koderift_external_calls koderift_external_config koderift_trace_frames
    koderift_capture_frames koderift_scope_stack koderift_rescue_view
    koderift_rescue_view_below koderift_rescue_view_context koderift_rescue_view_crumbs
  ].freeze

  def thread_state(thread = Thread.current)
    RESCUE_SPEC_THREAD_KEYS.map { |key| [key, thread[key]] }.to_h
  end

  def sql(text)
    ActiveSupport::Notifications.instrument('sql.active_record', sql: text, name: 'Load') {}
  end

  def env_for(request_id, path: '/widgets', method: 'GET', headers: {})
    env = Rack::MockRequest.env_for(path, headers.merge(method: method))
    env['action_dispatch.request_id'] = request_id
    env
  end

  # Dispatches and returns [status, the process_action payload lograge
  # turns into the request line]. An exception that escapes is returned
  # rather than raised.
  def dispatch(klass, action, request_id = 'req-1', **env_options)
    payloads   = []
    subscriber = ActiveSupport::Notifications.subscribe('process_action.action_controller') do |*args|
      payloads << args.last
    end
    begin
      status, = klass.action(action).call(env_for(request_id, **env_options))
    rescue StandardError => e
      status = e
    end
    [status, payloads.last]
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  def lograge_line(payload)
    options = ActiveSupport::OrderedOptions.new
    app     = Struct.new(:config).new(Struct.new(:lograge).new(options))
    Koderift::Rails::LogrageConfig.apply(app)
    options.custom_options.call(Struct.new(:payload).new(payload))
  end

  def captures
    capture_lines.map { |(_, line)| JSON.parse(line) }
  end

  def capture(message)
    captures.find { |c| c['message'] == message || c['exception'].to_s.include?(message) }
  end

  # The fields an in-action capture carries for this request.
  def expect_request_context(cap, line, request_id:, component:, action:, path: '/widgets', method: 'GET')
    expect(cap).to include(
      'request_id'  => request_id,
      'component'   => component,
      'action'      => action,
      'path'        => path,
      'http_method' => method
    )
    expect(cap['trace_id']).to match(/\A[0-9a-f]{32}\z/)
    expect(cap['trace_id']).to eq(line[:trace_id])
    expect(cap['span_id']).to eq(line[:span_id])
  end

  # A Base controller whose handler reports and renders, as most apps do.
  let(:widgets) do
    Class.new(ActionController::Base) do
      define_singleton_method(:name) { 'RescueWidgetsController' }

      rescue_from ArgumentError, with: :report_and_render

      def boom
        ActiveSupport::Notifications.instrument('sql.active_record', sql: 'SELECT widgets', name: 'Load') {}
        raise ArgumentError, 'bad widget'
      end

      def ok
        ActiveSupport::Notifications.instrument('sql.active_record', sql: 'SELECT ok', name: 'Load') {}
        Koderift.capture_message('in action', level: :error)
        render json: { ok: true }
      end

      private

      def current_user
        RescueFromSpecUser.new(42)
      end

      def report_and_render(error)
        Koderift.capture_exception(error)
        render json: { handled: true }, status: 422
      end
    end
  end

  # ------------------------------------------------------------------ test 1

  describe 'a handler on the controller' do
    it 'carries the request ID, trace, root span, path, method, component, action and user' do
      status, payload = dispatch(widgets, :boom)
      line = lograge_line(payload)

      expect(status).to eq(422)
      expect_request_context(capture('bad widget'), line,
                             request_id: 'req-1', component: 'RescueWidgetsController', action: 'boom')
      expect(capture('bad widget')['user_id']).to eq('42')
    end

    it 'carries what is the same as a capture inside the action' do
      dispatch(widgets, :ok, 'req-ok')
      in_action = capture('in action')
      dispatch(widgets, :boom, 'req-ok')
      handler = capture('bad widget')

      keys = %w[request_id component action path http_method user_id]
      expect(handler.slice(*keys)).to eq(in_action.slice(*keys).merge('action' => 'boom'))
    end

    it "keeps the scope the action had: Koderift.set_user and tags from a callback" do
      scoped = Class.new(widgets) do
        define_singleton_method(:name) { 'ScopedWidgetsController' }
        before_action do
          Koderift.set_user(id: 7, email: 'seven@example.com')
          Koderift.set_tag(:tenant, 'acme')
        end
      end

      dispatch(scoped, :boom)
      cap = capture('bad widget')

      expect(cap['user_id']).to eq('7')
      expect(cap['context']['tags']).to eq('tenant' => 'acme')
      expect(cap['context']['user']).to include('id' => 7)
    end

    it 'leaves capture_message in a handler the same way' do
      messenger = Class.new(widgets) do
        define_singleton_method(:name) { 'MessageWidgetsController' }
        rescue_from(KeyError) do |_e|
          Koderift.capture_message('handled key', level: :error)
          head 404
        end
        def missing
          {}.fetch(:nope)
        end
      end

      _, payload = dispatch(messenger, :missing)
      expect_request_context(capture('handled key'), lograge_line(payload),
                             request_id: 'req-1', component: 'MessageWidgetsController', action: 'missing')
    end
  end

  # ------------------------------------------------------------------ test 2

  describe 'where the handler is defined' do
    it 'on a parent controller: the component is the subclass' do
      child = Class.new(widgets) do
        define_singleton_method(:name) { 'ChildWidgetsController' }
        def child_boom
          raise ArgumentError, 'child widget'
        end
      end

      _, payload = dispatch(child, :child_boom)
      expect_request_context(capture('child widget'), lograge_line(payload),
                             request_id: 'req-1', component: 'ChildWidgetsController', action: 'child_boom')
    end

    it 'in a concern' do
      concern = Module.new do
        extend ActiveSupport::Concern

        included do
          rescue_from(KeyError) do |error|
            Koderift.capture_exception(error)
            head 422
          end
        end
      end
      klass = Class.new(ActionController::Base) do
        define_singleton_method(:name) { 'ConcernWidgetsController' }
        include concern
        def boom
          raise KeyError, 'from a concern'
        end
      end

      _, payload = dispatch(klass, :boom)
      expect_request_context(capture('from a concern'), lograge_line(payload),
                             request_id: 'req-1', component: 'ConcernWidgetsController', action: 'boom')
    end

    it 'on ActionController::API' do
      api = Class.new(ActionController::API) do
        define_singleton_method(:name) { 'Api::RescueWidgetsController' }
        rescue_from(ArgumentError) do |error|
          Koderift.capture_exception(error)
          render json: { error: 'bad' }, status: 422
        end
        def boom
          raise ArgumentError, 'api widget'
        end

        private

        def current_user
          RescueFromSpecUser.new(9)
        end
      end

      status, payload = dispatch(api, :boom)
      expect(status).to eq(422)
      expect_request_context(capture('api widget'), lograge_line(payload),
                             request_id: 'req-1', component: 'Api::RescueWidgetsController', action: 'boom')
      expect(capture('api widget')['user_id']).to eq('9')
    end
  end

  # ------------------------------------------------------------------ test 3

  describe 'nothing reaches the next request on the thread' do
    let(:reraiser) do
      Class.new(widgets) do
        define_singleton_method(:name) { 'ReraiseWidgetsController' }
        rescue_from(KeyError) do |error|
          Koderift.set_tag(:from_handler, 'alice')
          Koderift.add_breadcrumb("alice's handler crumb")
          Koderift.capture_exception(error)
          raise RescueFromSpecWrapperError, 'wrapped'
        end
        def alice
          raise KeyError, 'alice'
        end
      end
    end

    it 'when the handler re-raises' do
      status, = dispatch(reraiser, :alice, 'req-alice')
      expect(status).to be_a(RescueFromSpecWrapperError)
      expect(capture('alice')['request_id']).to eq('req-alice')
      expect(thread_state.values).to all(be_nil)

      dispatch(widgets, :ok, 'req-bob')
      bob = capture('in action')

      expect(bob['request_id']).to eq('req-bob')
      expect(bob['context']).not_to have_key('tags')
      expect(bob['breadcrumbs'].map { |c| c['message'] }).to eq(['SELECT ok'])
      expect(thread_state.values).to all(be_nil)
    end

    it 'when the hook never ran (a callback before it raised)' do
      prehook = Class.new(ActionController::Base) do
        define_singleton_method(:name) { 'PrehookWidgetsController' }
        prepend_before_action { raise ArgumentError, "#{request.request_id} before the hook" }
        rescue_from(ArgumentError) do |error|
          Koderift.set_tag(:who, request.request_id)
          Koderift.add_breadcrumb("#{request.request_id}'s handler crumb")
          Koderift.capture_exception(error)
          head 422
        end
        def show; end
      end

      dispatch(prehook, :show, 'req-alice')
      dispatch(prehook, :show, 'req-bob')
      bob = capture('req-bob before the hook')

      expect(bob['context']['tags']).to eq('who' => 'req-bob')
      expect(bob['breadcrumbs'].map { |c| c['message'] }).to eq(["req-bob's handler crumb"])
      expect(thread_state.values).to all(be_nil)
    end

    [
      ['the normal path', :boom],
      ['the no-hook path', :prehook]
    ].each do |label, action|
      it "when a handler abandons a non-block transaction (#{label})" do
        abandoner = Class.new(ActionController::Base) do
          define_singleton_method(:name) { 'AbandonWidgetsController' }
          prepend_before_action { raise ArgumentError, 'pre' if action_name == 'prehook' }
          rescue_from(ArgumentError) do |_error|
            Koderift.add_breadcrumb("alice's crumb")
            Koderift.start_transaction(name: 'Handler#abandoned')
            Koderift.add_breadcrumb("alice's crumb in the transaction")
            head 422
          end
          def boom
            ActiveSupport::Notifications.instrument('sql.active_record', sql: "SELECT 'alice@example.com'", name: 'Load') {}
            raise ArgumentError, 'abandon'
          end
          def prehook; end

          private

          def current_user
            RescueFromSpecUser.new('alice')
          end
        end

        dispatch(abandoner, action, 'req-alice')
        expect(thread_state.values).to all(be_nil)

        dispatch(widgets, :ok, 'req-bob')
        Koderift.start_transaction(name: 'Later#run') { Koderift.capture_message('later in a transaction', level: :error) }
        Koderift.capture_message('later outside', level: :error)

        # The abandoned transaction's own line goes out when the later one
        # finishes it, with its own ID and its own crumb, and nothing of the
        # request it was started in. Nothing else names Alice.
        later = captures.drop_while { |c| c['request_id'] != 'req-bob' }
        own, others = later.partition { |c| c['component'] == 'Handler' }
        expect(others).not_to be_empty
        expect(others.to_json).not_to include('alice')
        expect(own.size).to eq(1)
        expect(own.first).not_to include('user_id', 'path', 'http_method')
        expect(own.first['request_id']).not_to eq('req-alice')
        expect(own.first['breadcrumbs'].map { |c| c['message'] }).to eq(["alice's crumb in the transaction"])
        expect(capture('in action')['request_id']).to eq('req-bob')
      end
    end
  end

  # ------------------------------------------------------------------ test 4

  describe 'nested handling' do
    it 'the cause fallback: a handler found through the cause carries the request' do
      klass = Class.new(widgets) do
        define_singleton_method(:name) { 'CauseWidgetsController' }
        def wrapped
          begin
            raise ArgumentError, 'the cause'
          rescue ArgumentError
            raise RescueFromSpecWrapperError, 'no handler for me'
          end
        end
      end

      status, payload = dispatch(klass, :wrapped)
      expect(status).to eq(422)
      expect_request_context(capture('the cause'), lograge_line(payload),
                             request_id: 'req-1', component: 'CauseWidgetsController', action: 'wrapped')
    end

    it 'a handler that passes a second error to rescue_with_handler: every capture carries the request' do
      klass = Class.new(ActionController::Base) do
        define_singleton_method(:name) { 'NestedWidgetsController' }
        rescue_from ArgumentError, with: :outer_handler
        rescue_from RescueFromSpecSecondError, with: :inner_handler
        def boom
          raise ArgumentError, 'first'
        end

        private

        def outer_handler(_error)
          Koderift.capture_message('outer before', level: :error)
          begin
            raise RescueFromSpecSecondError, 'second'
          rescue RescueFromSpecSecondError => e
            rescue_with_handler(e)
          end
          Koderift.capture_message('outer after', level: :error)
          head 422
        end

        def inner_handler(error)
          Koderift.capture_exception(error)
        end
      end

      _, payload = dispatch(klass, :boom)
      line = lograge_line(payload)
      ['outer before', 'second', 'outer after'].each do |message|
        expect_request_context(capture(message), line,
                               request_id: 'req-1', component: 'NestedWidgetsController', action: 'boom')
      end
      expect(thread_state.values).to all(be_nil)
    end

    it 'a handler whose own error goes unhandled: the line is the unhandled one, and outer code has no context' do
      klass = Class.new(widgets) do
        define_singleton_method(:name) { 'UnhandledWidgetsController' }
        rescue_from(KeyError) do |error|
          Koderift.capture_exception(error)
          raise RescueFromSpecWrapperError, 'from the handler'
        end
        def boom
          raise KeyError, 'first'
        end
      end
      payloads = []
      sub = ActiveSupport::Notifications.subscribe('process_action.action_controller') { |*a| payloads << a.last }
      app = lambda do |env|
        klass.action(:boom).call(env)
      rescue RescueFromSpecWrapperError => e
        Koderift.capture_exception(e)
        [500, {}, []]
      end
      app.call(env_for('req-1'))
      ActiveSupport::Notifications.unsubscribe(sub)

      expect(capture('first')['request_id']).to eq('req-1')
      outer = capture('from the handler')
      expect(outer.keys & %w[request_id trace_id span_id component action path http_method user_id]).to be_empty
      expect(lograge_line(payloads.last)[:exception]).to eq('RescueFromSpecWrapperError: from the handler')
    end
  end

  # ------------------------------------------------------------------ test 5

  describe 'outside the handler' do
    it 'a capture in a middleware after the controller has no request context, as before' do
      app = lambda do |env|
        response = widgets.action(:boom).call(env)
        Koderift.capture_message('after the controller', level: :error)
        response
      end
      app.call(env_for('req-1'))

      after = capture('after the controller')
      expect(after.keys & %w[request_id trace_id span_id component action path http_method user_id]).to be_empty
    end

    it 'a transaction started in the handler carries its own context inside it' do
      klass = Class.new(widgets) do
        define_singleton_method(:name) { 'TxnWidgetsController' }
        rescue_from(KeyError) do |_error|
          Koderift.start_transaction(name: 'Report#deliver') do
            Koderift.capture_message('inside the transaction', level: :error)
          end
          Koderift.capture_message('after the transaction', level: :error)
          head 422
        end
        def boom
          raise KeyError, 'x'
        end
      end

      _, payload = dispatch(klass, :boom)
      line   = lograge_line(payload)
      inside = capture('inside the transaction')

      expect(inside['component']).to eq('Report')
      expect(inside['request_id']).not_to eq('req-1')
      expect(inside['trace_id']).not_to eq(line[:trace_id])
      expect_request_context(capture('after the transaction'), line,
                             request_id: 'req-1', component: 'TxnWidgetsController', action: 'boom')
    end
  end

  # ------------------------------------------------------------------ test 6

  describe 'the request line' do
    let(:lined) do
      Class.new(widgets) do
        define_singleton_method(:name) { 'LineWidgetsController' }
        def unhandled
          ActiveSupport::Notifications.instrument('sql.active_record', sql: 'SELECT unhandled', name: 'Load') {}
          raise RescueFromSpecWrapperError, 'nobody handles me'
        end
      end
    end

    def shape(line)
      line.transform_values do |value|
        case value
        when /\A[0-9a-f]{32}\z/ then :trace
        when /\A[0-9a-f]{16}\z/ then :span
        when /\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z\z/ then :time
        else value
        end
      end
    end

    it 'a successful request: as in 2.3.0' do
      _, payload = dispatch(lined, :ok)
      line = lograge_line(payload)

      expect(line.keys).to eq(%i[user_id host request_id trace_id span_id started_at ip breadcrumbs params
                                 spans query_count partial_count search_count])
      expect(shape(line).except(:breadcrumbs, :spans)).to eq(
        user_id: 42, host: 'example.org', request_id: 'req-1', trace_id: :trace, span_id: :span,
        started_at: :time, ip: '', params: {}, query_count: 1, partial_count: 0, search_count: 0
      )
      expect(line[:spans].map { |s| s[:name] }).to eq(['SELECT ok'])
    end

    # 2.4.0 (F1): an action that raised keeps its spans, counts and crumbs up
    # to the raise, and a line a handler took names the class it rescued.
    it 'a request whose error a handler took: the handler status, the spans and counts up to the raise, and rescued' do
      status, payload = dispatch(lined, :boom)
      line = lograge_line(payload)

      expect(status).to eq(422)
      expect(payload[:status]).to eq(422)
      expect(line.keys).to eq(%i[user_id host rescued request_id trace_id span_id started_at ip breadcrumbs params
                                 spans query_count partial_count search_count])
      expect(shape(line).except(:breadcrumbs, :spans)).to eq(
        user_id: 42, host: 'example.org', rescued: 'ArgumentError', request_id: 'req-1', trace_id: :trace,
        span_id: :span, started_at: :time, ip: '', params: {}, query_count: 1, partial_count: 0, search_count: 0
      )
      expect(line[:spans].map { |s| s[:name] }).to eq(['SELECT widgets'])
      expect(line[:breadcrumbs].map { |c| c[:message] }).to eq(['SELECT widgets'])
    end

    it 'an unhandled error: the exception, and the spans and counts up to the raise' do
      status, payload = dispatch(lined, :unhandled)
      line = lograge_line(payload)

      expect(status).to be_a(RescueFromSpecWrapperError)
      expect(payload[:status]).to eq(500)
      expect(line.keys).to eq(%i[user_id host exception request_id trace_id span_id started_at ip stack_trace
                                 breadcrumbs params spans query_count partial_count search_count])
      expect(line[:exception]).to eq('RescueFromSpecWrapperError: nobody handles me')
      expect(line).not_to have_key(:rescued)
      expect(line.slice(:query_count, :partial_count, :search_count)).to eq(query_count: 1, partial_count: 0,
                                                                              search_count: 0)
      expect(line[:spans].map { |s| s[:name] }).to eq(['SELECT unhandled'])
    end
  end

  # ------------------------------------------------------------------ test 7

  describe 'ActionController::Live' do
    # Live runs the action, and the handler, on a child thread, which the
    # parent may return before. The child's own state is read on the child.
    let(:observed) { Queue.new }

    let(:live) do
      seen = observed
      keys = RESCUE_SPEC_THREAD_KEYS
      Class.new(ActionController::Base) do
        include ActionController::Live
        define_singleton_method(:name) { 'LiveWidgetsController' }

        rescue_from(ArgumentError) do |error|
          Koderift.capture_exception(error)
          if response.committed?
            response.stream.close
          else
            head 422
          end
        end

        define_method(:process_action) do |*args|
          super(*args)
        ensure
          seen << [Thread.current.object_id, keys.map { |key| Thread.current[key] }]
        end

        def before_commit
          raise ArgumentError, 'live before commit'
        end

        def after_commit
          response.stream.write('partial')
          raise ArgumentError, 'live after commit'
        end
      end
    end

    %i[before_commit after_commit].each do |action|
      it "carries the request when the action raises #{action.to_s.tr('_', ' ')}, and leaves the child clean" do
        payloads = Queue.new
        sub = ActiveSupport::Notifications.subscribe('process_action.action_controller') { |*a| payloads << a.last }
        live.action(action).call(env_for('req-1'))
        # The request line is written inside the child's process_action,
        # before it reports its state, so both are there once this returns.
        child_thread, child_state = Timeout.timeout(5) { observed.pop }
        ActiveSupport::Notifications.unsubscribe(sub)
        payload = payloads.empty? ? nil : payloads.pop

        expect(child_thread).not_to eq(Thread.current.object_id)
        expect(child_state).to all(be_nil)
        expect(payload).not_to be_nil
        cap = capture("live #{action.to_s.tr('_', ' ')}")
        expect(cap).to include('request_id' => 'req-1', 'component' => 'LiveWidgetsController',
                               'action' => action.to_s, 'path' => '/widgets')
        expect(cap['trace_id']).to match(/\A[0-9a-f]{32}\z/)
        expect(cap['trace_id']).to eq(lograge_line(payload)[:trace_id])
        expect(cap['span_id']).to eq(lograge_line(payload)[:span_id])
      end
    end
  end

  # ------------------------------------------------------------------ test 8

  it 'two threads handling errors at once: each capture carries only its own request' do
    barrier = Concurrent::CyclicBarrier.new(2)
    klass = Class.new(ActionController::Base) do
      define_singleton_method(:name) { 'TogetherWidgetsController' }
      rescue_from(ArgumentError) do |error|
        barrier.wait(5)
        Koderift.capture_exception(error)
        barrier.wait(5)
        head 422
      end
      def boom
        raise ArgumentError, "for #{request.request_id}"
      end
    end

    payloads = Concurrent::Array.new
    sub = ActiveSupport::Notifications.subscribe('process_action.action_controller') { |*a| payloads << a.last }
    threads = %w[req-a req-b].map { |id| Thread.new { klass.action(:boom).call(env_for(id)) } }
    threads.each(&:join)
    ActiveSupport::Notifications.unsubscribe(sub)

    lines = payloads.map { |p| lograge_line(p) }
    %w[req-a req-b].each do |id|
      cap  = capture("for #{id}")
      line = lines.find { |l| l[:request_id] == id }
      expect(cap['request_id']).to eq(id)
      expect(cap['trace_id']).to eq(line[:trace_id])
      expect(cap['span_id']).to eq(line[:span_id])
    end
    expect(capture('for req-a')['trace_id']).not_to eq(capture('for req-b')['trace_id'])
  end

  # ------------------------------------------------------------------ test 11

  describe 'an exception raised outside the hook' do
    def expect_untraced(cap, line, request_id: 'req-1')
      expect(cap).to include('request_id' => request_id, 'path' => '/widgets', 'http_method' => 'POST')
      expect(cap).not_to include('trace_id', 'span_id')
      expect(line).not_to include(:trace_id, :span_id)
      expect(line[:request_id]).to eq(request_id)
    end

    let(:forgery_handler) do
      lambda do |klass_name, &body|
        Class.new(ActionController::Base) do
          define_singleton_method(:name) { klass_name }
          self.allow_forgery_protection = true
          rescue_from(ActionController::InvalidAuthenticityToken) do |error|
            Koderift.capture_exception(error)
            head 422
          end
          class_eval(&body) if body
          def create
            head 201
          end

          private

          def current_user
            RescueFromSpecUser.new(5)
          end
        end
      end
    end

    def post_without_token(klass)
      env = env_for('req-1', method: 'POST')
      store = Class.new do
        def load_session(_env)
          [1, {}]
        end

        def session_exists?(_env)
          true
        end
      end
      env['rack.session'] = ActionDispatch::Request::Session.create(store.new, ActionDispatch::Request.new(env), {})
      payloads = []
      sub = ActiveSupport::Notifications.subscribe('process_action.action_controller') { |*a| payloads << a.last }
      status, = klass.action(:create).call(env)
      ActiveSupport::Notifications.unsubscribe(sub)
      [status, payloads.last]
    end

    it 'protect_from_forgery prepend: true (before the hook): request ID and user, no trace, as on the line' do
      klass = forgery_handler.call('PrependForgeryController') { protect_from_forgery with: :exception, prepend: true }

      status, payload = post_without_token(klass)
      cap = capture('InvalidAuthenticityToken')

      expect(status).to eq(422)
      expect_untraced(cap, lograge_line(payload))
      expect(cap).to include('component' => 'PrependForgeryController', 'action' => 'create', 'user_id' => '5')
      expect(thread_state.values).to all(be_nil)
    end

    it 'protect_from_forgery declared in the controller (inside the hook): the full trace' do
      klass = forgery_handler.call('DeclaredForgeryController') { protect_from_forgery with: :exception }

      _, payload = post_without_token(klass)
      expect_request_context(capture('InvalidAuthenticityToken'), lograge_line(payload),
                             request_id: 'req-1', component: 'DeclaredForgeryController', action: 'create',
                             method: 'POST')
    end

    it 'prepend_before_action: request ID, no trace' do
      klass = Class.new(widgets) do
        define_singleton_method(:name) { 'PrependedWidgetsController' }
        prepend_before_action { raise ArgumentError, 'prepended' }
      end

      _, payload = dispatch(klass, :boom, method: 'POST')
      expect_untraced(capture('prepended'), lograge_line(payload))
    end

    it 'an after callback that runs once the hook has finished (as Rails puts verify_same_origin_request): the full trace' do
      klass = Class.new(widgets) do
        define_singleton_method(:name) { 'CrossOriginWidgetsController' }
        rescue_from(ActionController::InvalidCrossOriginRequest) do |error|
          Koderift.capture_exception(error)
        end
        prepend_after_action { raise ActionController::InvalidCrossOriginRequest, 'cross-origin' }
        def page
          render plain: 'js'
        end
      end

      _, payload = dispatch(klass, :page)
      line = lograge_line(payload)
      expect(line[:spans]).to be_an(Array)
      expect_request_context(capture('cross-origin'), line,
                             request_id: 'req-1', component: 'CrossOriginWidgetsController', action: 'page')
    end

    it 'skip_around_action: request ID, no trace' do
      klass = Class.new(widgets) do
        define_singleton_method(:name) { 'SkippedWidgetsController' }
        skip_around_action :koderift_instrument_request
      end

      _, payload = dispatch(klass, :boom, method: 'POST')
      expect_untraced(capture('bad widget'), lograge_line(payload))
    end
  end

  # ------------------------------------------------------------------ test 12

  it 'an explicit rescue_with_handler inside the action is unchanged: the in-action span, the frame still live' do
    klass = Class.new(ActionController::Base) do
      define_singleton_method(:name) { 'ExplicitWidgetsController' }
      rescue_from(ArgumentError) { |error| Koderift.capture_exception(error) }
      def explicit
        Koderift.with_child_span(op: 'work') do
          begin
            raise ArgumentError, 'explicit'
          rescue ArgumentError => e
            rescue_with_handler(e)
          end
        end
        Koderift.capture_message('still in the action', level: :error)
        render json: { ok: true }
      end
    end

    _, payload = dispatch(klass, :explicit)
    line   = lograge_line(payload)
    custom = line[:spans].find { |s| s[:type] == 'custom' }

    expect(capture('explicit')['span_id']).to eq(custom[:span_id])
    expect(capture('explicit')['trace_id']).to eq(line[:trace_id])
    expect_request_context(capture('still in the action'), line,
                           request_id: 'req-1', component: 'ExplicitWidgetsController', action: 'explicit')
  end

  it 'an explicit rescue_with_handler inside a transaction in the action: the request, which Sentry keys on' do
    klass = Class.new(ActionController::Base) do
      define_singleton_method(:name) { 'ExplicitTxnWidgetsController' }
      rescue_from(ArgumentError) { |error| Koderift.capture_exception(error) }
      def explicit
        Koderift.start_transaction(name: 'Inner#work') do
          begin
            raise ArgumentError, 'explicit in a transaction'
          rescue ArgumentError => e
            rescue_with_handler(e)
          end
        end
        render json: { ok: true }
      end
    end

    _, payload = dispatch(klass, :explicit)
    expect_request_context(capture('explicit in a transaction'), lograge_line(payload),
                           request_id: 'req-1', component: 'ExplicitTxnWidgetsController', action: 'explicit')
  end

  it "a transaction an earlier request abandoned, finished from a later handler, takes nothing of that handler's request" do
    alice = Class.new(ActionController::Base) do
      define_singleton_method(:name) { 'AliceWidgetsController' }
      def work
        Koderift.start_transaction(name: 'Alice#export')
        ActiveSupport::Notifications.instrument('sql.active_record', sql: 'SELECT alice', name: 'Load') {}
        head 200
      end
    end
    bob = Class.new(ActionController::Base) do
      define_singleton_method(:name) { 'BobWidgetsController' }
      before_action { Koderift.set_user(id: 'bob', email: 'bob@example.com') }
      rescue_from(KeyError) do |_error|
        Koderift.start_transaction(name: 'Bob#report') { nil }
        head 422
      end
      def boom
        raise KeyError, 'bob'
      end

      private

      def current_user
        RescueFromSpecUser.new('bob')
      end
    end

    dispatch(alice, :work, 'req-alice')
    dispatch(bob, :boom, 'req-bob', path: '/bob')

    lines = log_lines.map { |(_, m)| JSON.parse(m) rescue nil }.compact
    alices = lines.find { |l| l['component'] == 'Alice' }
    expect(alices['spans'].map { |s| s['name'] }).to eq(['SELECT alice'])
    expect(alices).not_to include('user_id', 'path', 'http_method')
    expect(alices['context']).not_to have_key('user')
    # Bob's own transaction, finished on top, is as it would be in his action.
    expect(lines.find { |l| l['component'] == 'Bob' }).to include('user_id' => 'bob')
  end

  it "a crumb added in a hookless handler doesn't land in a buffer that was there before it" do
    Koderift.add_breadcrumb('outside any unit')
    klass = Class.new(ActionController::Base) do
      define_singleton_method(:name) { 'CrumbWidgetsController' }
      prepend_before_action { raise ArgumentError, 'pre' }
      rescue_from(ArgumentError) do |_error|
        Koderift.add_breadcrumb("the handler's crumb")
        Koderift.capture_message('in the handler', level: :error)
        head 422
      end
      def show; end
    end

    dispatch(klass, :show)
    Koderift.capture_message('afterwards', level: :error)

    expect(capture('in the handler')['breadcrumbs'].map { |c| c['message'] }).to eq(["the handler's crumb"])
    expect(capture('afterwards')['breadcrumbs'].map { |c| c['message'] }).to eq(['outside any unit'])
  end

  it 'the kept scope is read once: a second controller handed the same Request (X-Cascade) does not get it' do
    first = Class.new(widgets) do
      define_singleton_method(:name) { 'CascadeFirstController' }
      def boom
        Koderift.set_tag(:who, 'first')
        raise ArgumentError, 'first'
      end
    end
    second = Class.new(ActionController::Base) do
      define_singleton_method(:name) { 'CascadeSecondController' }
      prepend_before_action { raise ArgumentError, 'second' }
      rescue_from(ArgumentError) do |error|
        Koderift.capture_exception(error)
        head 404
      end
      def show; end
    end
    request = ActionDispatch::Request.new(env_for('req-1'))

    first.new.dispatch(:boom, request, ActionDispatch::Response.new)
    second.new.dispatch(:show, request, ActionDispatch::Response.new)

    expect(capture('first')['context']['tags']).to eq('who' => 'first')
    expect(capture('second')['context']).not_to have_key('tags')
  end

  # ------------------------------------------------------------------ test 13

  describe 'a failure inside the gem' do
    let(:rescue_context) { Koderift::Rails::RescueContext }

    it 'before anything is written: the handler runs as before' do
      allow(rescue_context).to receive(:publish).and_raise(RuntimeError, 'gem bug')

      status, = dispatch(widgets, :boom)

      expect(status).to eq(422)
      expect(capture('bad widget')).not_to include('request_id')
      expect(thread_state.values).to all(be_nil)
    end

    it 'after the first write: everything is put back before the handler runs' do
      allow(rescue_context).to receive(:publish).and_wrap_original do |_original, *_args|
        Thread.current[:koderift_scope_stack] = [Koderift::Rails::Scope.new.set_tag(:half, 'written')]
        Thread.current[:koderift_rescue_view] = Object.new
        raise RuntimeError, 'gem bug'
      end

      status, = dispatch(widgets, :boom)

      expect(status).to eq(422)
      expect(capture('bad widget')).not_to include('request_id', 'context' => hash_including('tags'))
      expect(thread_state.values).to all(be_nil)
    end

    it 'while building the context: the capture still goes out' do
      allow(rescue_context).to receive(:context_for).and_call_original
      allow(rescue_context).to receive(:context_for).with(instance_of(widgets)).and_wrap_original do |original, controller|
        raise RuntimeError, 'gem bug' if Koderift::Rails::RescueContext.current

        original.call(controller)
      end

      status, = dispatch(widgets, :boom)

      expect(status).to eq(422)
      expect(capture('bad widget')).to include('exception' => 'ArgumentError: bad widget')
      expect(thread_state.values).to all(be_nil)
    end

    it 'when the thread key is written but the request is gone: nothing raises' do
      Thread.current[:koderift_rescue_view] = Object.new
      expect(Koderift.capture_message('stray', level: :error)).to be_a(Koderift::Rails::Event)
    end
  end

  # ------------------------------------------------------------------ test 14

  describe 'what else runs in a handler is unchanged' do
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

    it 'outbound HTTP, an enqueued job and a transaction get no request trace' do
      outbound = http
      job      = { 'class' => 'NotifyJob', 'jid' => 'j-1' }
      klass = Class.new(widgets) do
        define_singleton_method(:name) { 'SideEffectWidgetsController' }
        rescue_from(KeyError) do |_error|
          outbound.request(Net::HTTP::Get.new('/notify'))
          Koderift::Rails::SidekiqClientMiddleware.new.call('NotifyJob', job, 'default') { nil }
          Koderift.start_transaction(name: 'Report#deliver') { nil }
          head 422
        end
        def boom
          raise KeyError, 'x'
        end
      end

      _, payload = dispatch(klass, :boom)
      line = lograge_line(payload)
      sent = outbound.last_request
      txn  = log_lines.map { |(_, m)| JSON.parse(m) rescue nil }.compact.find { |l| l['component'] == 'Report' }

      expect(sent['traceparent']).to be_nil
      expect(sent['X-Koderift-Traceparent']).to be_nil
      expect(sent['X-Koderift-Trace-ID']).to be_nil
      expect(job).not_to include('koderift_traceparent', 'koderift_trace_id')
      expect(txn['trace_id']).not_to eq(line[:trace_id])
      expect(txn).not_to include('parent_span_id')
    end

    it 'Rails 8.1: a rescue_from_callback subscriber sees the request' do
      skip 'rescue_from_callback.action_controller is new in Rails 8.1' unless ActionPack.version >= Gem::Version.new('8.1')

      sub = ActiveSupport::Notifications.subscribe('rescue_from_callback.action_controller') do |*|
        Koderift.capture_message('from the subscriber', level: :error)
      end
      _, payload = dispatch(widgets, :boom)
      ActiveSupport::Notifications.unsubscribe(sub)

      expect_request_context(capture('from the subscriber'), lograge_line(payload),
                             request_id: 'req-1', component: 'RescueWidgetsController', action: 'boom')
    end
  end

  # ------------------------------------------------------------------ test 15

  describe 'where the request is kept' do
    it 'adds no controller ivars (view_assigns) and nothing to request.env' do
      seen = {}
      klass = Class.new(widgets) do
        define_singleton_method(:name) { 'IvarWidgetsController' }
        rescue_from(KeyError) do |_error|
          seen[:ivars] = instance_variables
          seen[:env]   = request.env.keys.grep(/koderift/)
          head 422
        end
        def boom
          Koderift.set_tag(:kept, 'yes')
          raise KeyError, 'x'
        end
      end

      dispatch(klass, :boom)

      expect(seen[:ivars].grep(/koderift/)).to be_empty
      expect(seen[:env]).to match_array(%w[koderift.trace_id koderift.span_id koderift.parent_span_id koderift.started_at])
    end

    it 'a second controller on the same env (exceptions_app style) does not get the first one\'s scope' do
      first = Class.new(widgets) do
        define_singleton_method(:name) { 'FirstWidgetsController' }
        def boom
          Koderift.set_tag(:who, 'first')
          raise RescueFromSpecWrapperError, 'unhandled'
        end
      end
      errors = Class.new(ActionController::Base) do
        define_singleton_method(:name) { 'ErrorsController' }
        prepend_before_action { raise ArgumentError, 'errors page' }
        rescue_from(ArgumentError) do |error|
          Koderift.capture_exception(error)
          head 500
        end
        def show; end
      end

      env = env_for('req-1')
      expect { first.action(:boom).call(env) }.to raise_error(RescueFromSpecWrapperError)
      errors.action(:show).call(env)

      expect(capture('errors page')['request_id']).to eq('req-1')
      expect(capture('errors page')['context']).not_to have_key('tags')
    end

    it 'a later dispatch of a reused controller does not get an earlier one\'s scope or action' do
      klass = Class.new(widgets) do
        define_singleton_method(:name) { 'ReusedWidgetsController' }
        prepend_before_action { raise ArgumentError, 'pre-hook' if action_name == 'pre' }
        def boom
          Koderift.set_tag(:from, 'boom')
          raise ArgumentError, 'in action'
        end
        def pre; end
      end
      controller = klass.new
      env        = env_for('req-1')
      process    = lambda do |action|
        controller.clear_instance_variables_between_requests if controller.respond_to?(:clear_instance_variables_between_requests)
        controller.recycle! if controller.respond_to?(:recycle!)
        controller.dispatch(action, ActionDispatch::Request.new(env), ActionDispatch::Response.new)
      end

      process.call(:boom)
      process.call(:pre)

      cap = capture('pre-hook')
      expect(cap['action']).to eq('pre')
      expect(cap['context']).not_to have_key('tags')
    end

    # sentry-sidekiq tags every event in a job with its jid, which Koderift
    # pairs on first, so the handler's capture keeps carrying the jid.
    it "a controller run inside a Sidekiq job: the handler keeps the job's context, and the job is intact" do
      klass = Class.new(widgets) do
        define_singleton_method(:name) { 'InJobWidgetsController' }
        rescue_from(KeyError) do |error|
          Koderift.capture_exception(error)
          ActiveSupport::Notifications.instrument('sql.active_record', sql: 'SELECT in_handler', name: 'Load') {}
          head 422
        end
        def boom
          raise KeyError, 'in the job'
        end
      end
      job = { 'class' => 'ReportJob', 'jid' => 'jid-1' }

      Koderift::Rails::SidekiqMiddleware.new.call(nil, job, 'default') do
        sql('SELECT outer_before')
        klass.action(:boom).call(env_for('req-in-job'))
        sql('SELECT outer_after')
        Koderift.capture_message('job after', level: :error)
      end

      handler = capture('in the job')
      expect(handler['request_id']).to eq('jid-1')
      expect(handler['trace_id']).to eq(capture('job after')['trace_id'])
      expect(capture('job after')['request_id']).to eq('jid-1')
      job_line = log_lines.map { |(_, m)| JSON.parse(m) rescue nil }.compact.find { |l| l['jid'] == 'jid-1' }
      expect(job_line['spans'].map { |s| s['name'] }).to include('SELECT outer_before', 'SELECT in_handler', 'SELECT outer_after')
      expect(thread_state.values).to all(be_nil)
    end
  end
end
