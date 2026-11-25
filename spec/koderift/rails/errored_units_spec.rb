# frozen_string_literal: true

require 'spec_helper'
require 'action_controller'
require 'rails/railtie'
require 'koderift/rails/railtie'
require 'koderift/rails/sidekiq_middleware'
require 'timeout'

class ErroredUnitsSpecError < StandardError; end
class ErroredUnitsSpecStop < Interrupt; end
ErroredUnitsSpecUser = Struct.new(:id)

# 2.4.0 (F1): a request or job that raises keeps the spans, counts and
# breadcrumbs it recorded up to the raise; a handler's captures get the
# action's trail; a line a handler took says what it rescued; and nothing the
# gem builds can fail a request or job, or replace its exception.
RSpec.describe 'requests and jobs that raise' do
  include_context 'a captured log'
  before(:all) { Koderift::Rails::Railtie.include_controller_concern }

  after do
    txn = Koderift::Rails::Tracing.current_transaction
    txn.finish if txn && !txn.finished?
    Koderift::Rails::Tracing.clear_current(txn) if txn
    Koderift::Rails.reset!
  end

  let(:trace_env_keys) { %w[koderift.trace_id koderift.span_id koderift.parent_span_id koderift.started_at] }

  def sql(text)
    ActiveSupport::Notifications.instrument('sql.active_record', sql: text, name: 'Load') {}
  end

  def env_for(request_id = 'req-1', method: 'GET')
    env = Rack::MockRequest.env_for('/widgets', method: method)
    env['action_dispatch.request_id'] = request_id
    env
  end

  # [status or the exception that escaped, the request line, the env]
  def dispatch(klass, action, request_id = 'req-1', **env_options)
    payloads   = []
    subscriber = ActiveSupport::Notifications.subscribe('process_action.action_controller') do |*args|
      payloads << args.last
    end
    env = env_for(request_id, **env_options)
    begin
      status, = klass.action(action).call(env)
    rescue Exception => e # rubocop:disable Lint/RescueException
      status = e
    end
    [status, payloads.last && lograge_line(payloads.last), env]
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

  def crumb_messages(list)
    Array(list).map { |c| c[:message] || c['message'] }
  end

  # No koderift.* env value may hold spans or crumbs: env dumps print them.
  def expect_env_clean(env)
    expect(env.keys.grep(/\Akoderift\./) - trace_env_keys).to be_empty
  end

  let(:raised) { [] }

  let(:widgets) do
    seen = raised
    Class.new(ActionController::Base) do
      define_singleton_method(:name) { 'ErroredWidgetsController' }

      rescue_from ArgumentError, with: :report_and_render

      define_method(:boom) do
        ActiveSupport::Notifications.instrument('sql.active_record', sql: 'SELECT widgets', name: 'Load') {}
        error = ArgumentError.new('bad widget')
        seen << error
        raise error
      end

      define_method(:unhandled) do
        ActiveSupport::Notifications.instrument('sql.active_record', sql: 'SELECT unhandled', name: 'Load') {}
        error = ErroredUnitsSpecError.new('nobody handles me')
        seen << error
        raise error
      end

      def ok
        ActiveSupport::Notifications.instrument('sql.active_record', sql: 'SELECT ok', name: 'Load') {}
        render json: { ok: true }
      end

      private

      def current_user
        ErroredUnitsSpecUser.new(42)
      end

      def report_and_render(error)
        Koderift.capture_exception(error)
        render json: { handled: true }, status: 422
      end
    end
  end

  # ---------------------------------------------------------------- the line

  describe 'the request line of an action that raised' do
    it 'keeps a with_child_span and its nested SQL' do
      klass = Class.new(widgets) do
        define_singleton_method(:name) { 'ChildSpanWidgetsController' }
        def nested
          Koderift.with_child_span(op: 'work') do
            ActiveSupport::Notifications.instrument('sql.active_record', sql: 'SELECT inside', name: 'Load') {}
            raise ArgumentError, 'inside the span'
          end
        end
      end

      _, line, = dispatch(klass, :nested)
      custom = line[:spans].find { |s| s[:type] == 'custom' }
      inside = line[:spans].find { |s| s[:name] == 'SELECT inside' }

      expect(custom).not_to be_nil
      expect(inside[:parent_span_id]).to eq(custom[:span_id])
      expect(line[:rescued]).to eq('ArgumentError')
    end

    it 'keeps the SQL of a callback inside the hook that raised' do
      klass = Class.new(widgets) do
        define_singleton_method(:name) { 'CallbackWidgetsController' }
        before_action do
          ActiveSupport::Notifications.instrument('sql.active_record', sql: 'SELECT in_callback', name: 'Load') {}
          raise ArgumentError, 'from a callback'
        end
      end

      _, line, = dispatch(klass, :ok)

      expect(line[:spans].map { |s| s[:name] }).to eq(['SELECT in_callback'])
      expect(line[:query_count]).to eq(1)
    end

    it 'keeps all 500 spans of a big action (the agent, not the gem, trims them)' do
      klass = Class.new(widgets) do
        define_singleton_method(:name) { 'BigWidgetsController' }
        def big
          500.times { |i| ActiveSupport::Notifications.instrument('sql.active_record', sql: "SELECT #{i}", name: 'Load') {} }
          raise ErroredUnitsSpecError, 'after 500'
        end
      end

      _, line, = dispatch(klass, :big)

      expect(line[:spans].size).to eq(500)
      expect(line[:query_count]).to eq(500)
      expect(line[:breadcrumbs].size).to eq(20)
    end

    it 'hands Rails the same exception object, handled or not' do
      status, = dispatch(widgets, :unhandled)

      expect(status).to equal(raised.last)
    end

    it 'leaves no spans or crumbs in request.env, on success, a handled raise, an unhandled raise or a post-hook raise' do
      post_hook = Class.new(widgets) do
        define_singleton_method(:name) { 'PostHookWidgetsController' }
        prepend_after_action { raise ArgumentError, 'after the hook' }
      end

      [[widgets, :ok], [widgets, :boom], [widgets, :unhandled], [post_hook, :ok]].each do |klass, action|
        _, line, env = dispatch(klass, action)
        expect_env_clean(env)
        expect(line[:spans]).to be_an(Array)
      end
    end

    it 'hands Rails the same exception object when it is not a StandardError, with the spans on the line' do
      klass = Class.new(widgets) do
        define_singleton_method(:name) { 'InterruptWidgetsController' }
        def stop
          ActiveSupport::Notifications.instrument('sql.active_record', sql: 'SELECT before_stop', name: 'Load') {}
          raise ErroredUnitsSpecStop
        end
      end

      status, line, env = dispatch(klass, :stop)

      expect(status).to be_a(ErroredUnitsSpecStop)
      expect(line[:spans].map { |s| s[:name] }).to eq(['SELECT before_stop'])
      expect_env_clean(env)
    end

    it 'a request that ends in throw (Warden from a before_action) carries what it recorded, with no exception' do
      klass = Class.new(widgets) do
        define_singleton_method(:name) { 'WardenWidgetsController' }
        before_action do
          ActiveSupport::Notifications.instrument('sql.active_record', sql: 'SELECT users', name: 'Load') {}
          throw :warden
        end
      end
      payloads = []
      sub = ActiveSupport::Notifications.subscribe('process_action.action_controller') { |*a| payloads << a.last }
      catch(:warden) { klass.action(:ok).call(env_for) }
      ActiveSupport::Notifications.unsubscribe(sub)
      line = lograge_line(payloads.last)

      expect(line[:spans].map { |s| s[:name] }).to eq(['SELECT users'])
      expect(line).not_to include(:exception, :rescued)
      expect(payloads.last[:status]).to be_nil
    end

    it 'a successful request leaves nothing of the gem on the Request' do
      request = ActionDispatch::Request.new(env_for)
      widgets.new.dispatch(:ok, request, ActionDispatch::Response.new)

      expect(request.instance_variables.grep(/koderift/)).to be_empty
    end

    # 2.4.1: a second controller dispatched on the same env (an exceptions_app
    # error page) used to take the first one's trace from the env keys.
    describe 'a second controller dispatched on the same env' do
      let(:failing) do
        Class.new(widgets) do
          define_singleton_method(:name) { 'FirstOnEnvController' }
          def fail_first
            ActiveSupport::Notifications.instrument('sql.active_record', sql: 'SELECT first', name: 'Load') {}
            raise ErroredUnitsSpecError, 'first fails'
          end
        end
      end

      def both_lines(second, action)
        payloads = []
        sub = ActiveSupport::Notifications.subscribe('process_action.action_controller') { |*a| payloads << a.last }
        env = env_for
        begin
          failing.action(:fail_first).call(env)
        rescue ErroredUnitsSpecError
          nil
        end
        second.action(action).call(env)
        ActiveSupport::Notifications.unsubscribe(sub)
        payloads.map { |p| lograge_line(p) }
      end

      it "whose hook never runs carries no trace or span of the first one's, on its line or in its handler" do
        errors = Class.new(ActionController::Base) do
          define_singleton_method(:name) { 'HooklessErrorsController' }
          prepend_before_action { raise KeyError, 'error page before the hook' }
          rescue_from(KeyError) do |error|
            Koderift.capture_exception(error)
            head 500
          end
          def show; end
        end

        first, second = both_lines(errors, :show)

        expect(first[:span_id]).to match(/\A[0-9a-f]{16}\z/)
        expect(first[:spans].map { |s| s[:name] }).to eq(['SELECT first'])
        expect(second).not_to include(:trace_id, :span_id, :parent_span_id, :started_at, :spans)
        expect(second[:request_id]).to eq('req-1')
        expect(capture('error page before the hook')).not_to include('trace_id', 'span_id')
        expect(capture('error page before the hook')['request_id']).to eq('req-1')
      end

      it 'whose hook runs carries its own trace and span, not the first one\'s' do
        errors = Class.new(ActionController::Base) do
          define_singleton_method(:name) { 'HookedErrorsController' }
          def show
            head 500
          end
        end

        first, second = both_lines(errors, :show)

        expect(second[:span_id]).to match(/\A[0-9a-f]{16}\z/)
        expect(second[:span_id]).not_to eq(first[:span_id])
        expect(second[:trace_id]).not_to eq(first[:trace_id])
      end
    end

    it 'leaves nothing on the Request for a second controller handed the same one (X-Cascade)' do
      request = ActionDispatch::Request.new(env_for)
      widgets.new.dispatch(:boom, request, ActionDispatch::Response.new)

      expect(request.instance_variables.grep(/koderift/)).to be_empty
    end
  end

  # -------------------------------------------------------------- live

  describe 'ActionController::Live' do
    let(:observed) { Queue.new }

    let(:live) do
      seen = observed
      Class.new(ActionController::Base) do
        include ActionController::Live
        define_singleton_method(:name) { 'ErroredLiveController' }
        rescue_from(ArgumentError) do |_error|
          Koderift.capture_message('live handler', level: :error)
          response.committed? ? response.stream.close : head(422)
        end
        define_method(:process_action) do |*args|
          super(*args)
        ensure
          seen << true
        end
        def before_commit
          ActiveSupport::Notifications.instrument('sql.active_record', sql: 'SELECT live before', name: 'Load') {}
          raise ArgumentError, 'live before commit'
        end

        def after_commit
          ActiveSupport::Notifications.instrument('sql.active_record', sql: 'SELECT live', name: 'Load') {}
          response.stream.write('partial')
          raise ArgumentError, 'live after commit'
        end
      end
    end

    def live_line(action)
      payloads = Queue.new
      sub = ActiveSupport::Notifications.subscribe('process_action.action_controller') { |*a| payloads << a.last }
      live.action(action).call(env_for)
      Timeout.timeout(5) { observed.pop }
      ActiveSupport::Notifications.unsubscribe(sub)
      lograge_line(payloads.pop)
    end

    it "writes the raised action's spans on the child thread's line, before the commit too" do
      line = live_line(:before_commit)

      expect(line[:spans].map { |s| s[:name] }).to eq(['SELECT live before'])
      expect(line[:rescued]).to eq('ArgumentError')
    end

    it "writes the raised action's spans on the child thread's line" do
      payloads = Queue.new
      sub = ActiveSupport::Notifications.subscribe('process_action.action_controller') { |*a| payloads << a.last }
      live.action(:after_commit).call(env_for)
      Timeout.timeout(5) { observed.pop }
      ActiveSupport::Notifications.unsubscribe(sub)
      line = lograge_line(payloads.pop)

      expect(line[:spans].map { |s| s[:name] }).to eq(['SELECT live'])
      expect(line[:rescued]).to eq('ArgumentError')
      expect(crumb_messages(capture('live handler')['breadcrumbs'])).to eq(['SELECT live'])
    end
  end

  # ---------------------------------------------------- the gem never fails

  describe 'a failure inside the gem' do
    let(:instrumentation) { Koderift::Rails::Instrumentation }

    it 'building the result: a successful request still returns 200, without spans' do
      allow(instrumentation).to receive(:build_result).and_raise(NoMethodError, 'gem bug')

      status, line, = dispatch(widgets, :ok)

      expect(status).to eq(200)
      expect(line).not_to include(:spans, :query_count)
    end

    it 'building the result: an action that raised still hands Rails its own exception' do
      allow(instrumentation).to receive(:build_result).and_raise(NoMethodError, 'gem bug')

      status, = dispatch(widgets, :unhandled)

      expect(status).to equal(raised.last)
    end

    it 'stopping the capture: the original exception still reaches Rails' do
      allow(instrumentation).to receive(:stop_capture).and_raise(NoMethodError, 'gem bug')

      expect(dispatch(widgets, :unhandled).first).to equal(raised.last)
      expect(dispatch(widgets, :ok).first).to eq(200)
    end

    it 'starting the capture: the request runs, without spans' do
      allow(instrumentation).to receive(:start_capture).and_raise(NoMethodError, 'gem bug')

      status, line, = dispatch(widgets, :ok)

      expect(status).to eq(200)
      expect(line).not_to include(:spans)
      expect(Thread.current[:koderift_capture_frames]).to be_nil
    end
  end

  describe 'config.max_breadcrumbs' do
    let(:crumbing) do
      Class.new(widgets) do
        define_singleton_method(:name) { 'CrumbingWidgetsController' }
        def many
          25.times { |i| ActiveSupport::Notifications.instrument('sql.active_record', sql: "SELECT #{i}", name: 'Load') {} }
          Koderift.capture_message('in the action', level: :error)
          render json: { ok: true }
        end
      end
    end

    {
      nil    => 25,
      '3'    => 3,
      3.0    => 3,
      0      => 0,
      -1     => 0,
      Float::INFINITY  => 25,
      -Float::INFINITY => 0,
      :junk  => 20
    }.each do |value, kept|
      it "#{value.inspect} keeps #{kept}, on the line and on a capture, and fails nothing" do
        Koderift::Rails.configuration.max_breadcrumbs = value

        status, line, = dispatch(crumbing, :many)

        expect(status).to eq(200)
        expect(Array(line[:breadcrumbs]).size).to eq(kept)
        expect(Array(capture('in the action')['breadcrumbs']).size).to eq(kept)
      end
    end
  end

  # ------------------------------------------------------- breadcrumb fixes

  describe 'breadcrumbs' do
    it 'clearing them clears the line and every capture, and later crumbs still land in one trail (B1)' do
      klass = Class.new(widgets) do
        define_singleton_method(:name) { 'ClearingWidgetsController' }
        def clearing
          Koderift.add_breadcrumb('secret before the clear')
          ActiveSupport::Notifications.instrument('sql.active_record', sql: "SELECT 'secret'", name: 'Load') {}
          Koderift::Rails::Scope.current.clear_breadcrumbs
          ActiveSupport::Notifications.instrument('sql.active_record', sql: 'SELECT after', name: 'Load') {}
          Koderift.add_breadcrumb('after the clear')
          Koderift.capture_message('in the action', level: :error)
          raise ArgumentError, 'then raise'
        end
      end

      _, line, = dispatch(klass, :clearing)
      expected = ['SELECT after', 'after the clear']

      expect(crumb_messages(line[:breadcrumbs])).to eq(expected)
      expect(crumb_messages(capture('in the action')['breadcrumbs'])).to eq(expected)
      expect(crumb_messages(capture('then raise')['breadcrumbs'])).to eq(expected)
    end

    it 'caps an in-action capture at max_breadcrumbs (B2)' do
      klass = Class.new(widgets) do
        define_singleton_method(:name) { 'CappedWidgetsController' }
        def capped
          30.times { |i| ActiveSupport::Notifications.instrument('sql.active_record', sql: "SELECT #{i}", name: 'Load') {} }
          Koderift.capture_message('capped', level: :error)
          render json: { ok: true }
        end
      end

      dispatch(klass, :capped)
      crumbs = crumb_messages(capture('capped')['breadcrumbs'])

      expect(crumbs.size).to eq(20)
      expect(crumbs.last).to eq('SELECT 29')
    end

    it 'take cyclic data without raising' do
      data = { 'a' => 1 }
      data['self'] = data

      expect { Koderift.add_breadcrumb(Koderift::Breadcrumb.new(message: 'cyclic', data: data)) }.not_to raise_error
    end

    it 'outside any unit are trimmed by the same limit as lines and captures' do
      Koderift::Rails.configuration.max_breadcrumbs = 0
      3.times { |i| Koderift.add_breadcrumb("outside #{i}") }
      expect(Koderift::Rails::Breadcrumbs.current).to be_empty

      Koderift::Rails.configuration.max_breadcrumbs = nil
      30.times { |i| Koderift.add_breadcrumb("outside #{i}") }
      expect(Koderift::Rails::Breadcrumbs.current.size).to eq(30)
    end

    it "keeps controller, method, job_class and koderift_capture out of a crumb's data, at any depth (B3)" do
      Koderift.add_breadcrumb(Koderift::Breadcrumb.new(
        message: 'with data',
        data: { 'job_class' => 'X', method: 'GET', 'ok' => 1,
                'nested' => { 'controller' => 'Y', 'koderift_capture' => 1, 'keep' => [{ 'job_class' => 'Z', 'v' => 2 }] } }
      ))
      Koderift.capture_message('carrying data', level: :error)

      data = capture('carrying data')['breadcrumbs'].first['data']
      expect(data).to eq('ok' => 1, 'nested' => { 'keep' => [{ 'v' => 2 }] })
      expect(JSON.generate(capture('carrying data')['breadcrumbs'])).not_to match(/"(?:controller|method|job_class|koderift_capture)":/)
    end
  end

  # ------------------------------------------------------- handler captures

  describe "a handler's captures (D3)" do
    it "carry the action's trail up to the raise, then the handler's own, capped" do
      Koderift::Rails.configuration.max_breadcrumbs = 4
      klass = Class.new(widgets) do
        define_singleton_method(:name) { 'TrailWidgetsController' }
        rescue_from(KeyError) do |error|
          ActiveSupport::Notifications.instrument('sql.active_record', sql: 'SELECT in_handler', name: 'Load') {}
          Koderift.add_breadcrumb('handler 1')
          Koderift.add_breadcrumb('handler 2')
          Koderift.capture_exception(error)
          head 422
        end
        def trail
          %w[a b c d e].each { |n| ActiveSupport::Notifications.instrument('sql.active_record', sql: "SELECT #{n}", name: 'Load') {} }
          raise KeyError, 'trail'
        end
      end

      _, line, = dispatch(klass, :trail)

      expect(crumb_messages(line[:breadcrumbs])).to eq(['SELECT b', 'SELECT c', 'SELECT d', 'SELECT e'])
      expect(crumb_messages(capture('trail')['breadcrumbs'])).to eq(['SELECT d', 'SELECT e', 'handler 1', 'handler 2'])
    end

    it 'are in place before before_send runs' do
      seen = []
      Koderift::Rails.configuration.before_send = lambda do |payload, _hint|
        seen << crumb_messages(payload[:breadcrumbs])
        payload
      end

      dispatch(widgets, :boom)

      expect(seen).to eq([['SELECT widgets']])
    end

    it "are the request's trail, not a transaction's the action left open" do
      klass = Class.new(widgets) do
        define_singleton_method(:name) { 'TxnTrailWidgetsController' }
        def txn
          ActiveSupport::Notifications.instrument('sql.active_record', sql: 'SELECT request_part', name: 'Load') {}
          Koderift.start_transaction(name: 'Left#open')
          ActiveSupport::Notifications.instrument('sql.active_record', sql: 'SELECT txn_part', name: 'Load') {}
          raise ArgumentError, 'txn left open'
        end
      end

      _, line, = dispatch(klass, :txn)

      expect(crumb_messages(line[:breadcrumbs])).to eq(['SELECT request_part'])
      expect(crumb_messages(capture('txn left open')['breadcrumbs'])).to eq(['SELECT request_part'])
    end

    it "clearing them in the handler clears the action's crumbs from its captures, not from the line" do
      klass = Class.new(widgets) do
        define_singleton_method(:name) { 'HandlerClearWidgetsController' }
        rescue_from(KeyError) do |error|
          Koderift::Rails::Scope.current.clear_breadcrumbs
          Koderift.capture_exception(error)
          head 422
        end
        def boom2
          ActiveSupport::Notifications.instrument('sql.active_record', sql: 'SELECT kept_on_line', name: 'Load') {}
          raise KeyError, 'cleared in handler'
        end
      end

      _, line, = dispatch(klass, :boom2)

      expect(capture('cleared in handler')).not_to have_key('breadcrumbs')
      expect(crumb_messages(line[:breadcrumbs])).to eq(['SELECT kept_on_line'])
    end

    it "are only the handler's own for a raise after the hook has finished, though the line has the action's" do
      klass = Class.new(widgets) do
        define_singleton_method(:name) { 'PostHookTrailController' }
        rescue_from(KeyError) do |error|
          Koderift.add_breadcrumb('handler crumb')
          Koderift.capture_exception(error)
        end
        prepend_after_action { raise KeyError, 'after the hook' }
      end

      _, line, = dispatch(klass, :ok)

      expect(crumb_messages(line[:breadcrumbs])).to eq(['SELECT ok'])
      expect(crumb_messages(capture('after the hook')['breadcrumbs'])).to eq(['handler crumb'])
    end

    it "don't reach the next request on the thread" do
      dispatch(widgets, :boom, 'req-alice')
      klass = Class.new(widgets) do
        define_singleton_method(:name) { 'NextWidgetsController' }
        prepend_before_action { raise ArgumentError, 'pre-hook' }
      end

      dispatch(klass, :ok, 'req-bob')

      expect(capture('pre-hook')).not_to have_key('breadcrumbs')
      expect(Thread.current[:koderift_rescue_view_crumbs]).to be_nil
    end
  end

  # --------------------------------------------------------------- rescued

  describe 'the rescued key (D6)' do
    it "names the class a handler took, raised before the hook too, and nothing for an action's own call" do
      prehook = Class.new(widgets) do
        define_singleton_method(:name) { 'RescuedPrehookController' }
        prepend_before_action { raise ArgumentError, 'pre' }
      end
      explicit = Class.new(widgets) do
        define_singleton_method(:name) { 'RescuedExplicitController' }
        def explicit
          begin
            raise ArgumentError, 'explicit'
          rescue ArgumentError => e
            rescue_with_handler(e)
          end
          response_body || render(json: { ok: true })
        end
      end

      expect(dispatch(widgets, :boom)[1][:rescued]).to eq('ArgumentError')
      expect(dispatch(prehook, :ok)[1][:rescued]).to eq('ArgumentError')
      expect(dispatch(explicit, :explicit)[1]).not_to have_key(:rescued)
      expect(dispatch(widgets, :unhandled)[1]).not_to have_key(:rescued)
      expect(dispatch(widgets, :ok)[1]).not_to have_key(:rescued)
    end

    it 'adds nothing for an explicit call inside a transaction or an inline job the action started' do
      klass = Class.new(widgets) do
        define_singleton_method(:name) { 'RescuedInsideUnitController' }
        def in_txn
          Koderift.start_transaction(name: 'Inner#work') { explicit }
          render json: { ok: true }
        end

        def in_job
          Koderift::Rails::SidekiqMiddleware.new.call(nil, { 'class' => 'InlineJob', 'jid' => 'jid-inline' }, 'q') { explicit }
          render json: { ok: true }
        end

        private

        def explicit
          raise ArgumentError, 'explicit'
        rescue ArgumentError => e
          rescue_with_handler(e)
          self.response_body = nil
        end
      end

      expect(dispatch(klass, :in_txn)[1]).not_to have_key(:rescued)
      expect(dispatch(klass, :in_job)[1]).not_to have_key(:rescued)
    end

    it 'names the outermost class when a handler passes another error on, and the cause when that is what matched' do
      nested = Class.new(ActionController::Base) do
        define_singleton_method(:name) { 'RescuedNestedController' }
        rescue_from ArgumentError, with: :outer
        rescue_from KeyError, with: :inner
        def boom
          raise ArgumentError, 'outer'
        end

        def caused
          begin
            raise KeyError, 'the cause'
          rescue KeyError
            raise ErroredUnitsSpecError, 'no handler'
          end
        end

        private

        def outer(_error)
          begin
            raise KeyError, 'inner'
          rescue KeyError => e
            rescue_with_handler(e)
          end
          head 422
        end

        def inner(error)
          Koderift.capture_exception(error)
        end
      end

      expect(dispatch(nested, :boom)[1][:rescued]).to eq('ArgumentError')
      expect(dispatch(nested, :caused)[1][:rescued]).to eq('KeyError')
    end
  end

  # ------------------------------------------------------------------ jobs

  describe 'a Sidekiq job' do
    let(:middleware) { Koderift::Rails::SidekiqMiddleware.new }

    def job_lines
      log_lines.map { |(_, m)| JSON.parse(m) rescue nil }.compact.select { |l| l['job_class'] }
    end

    def run(job = { 'class' => 'ReportJob', 'jid' => 'jid-1' }, &body)
      middleware.call(nil, job, 'default', &body)
    end

    it 'that fails keeps its real spans, counts and breadcrumbs, with the same keys as a success' do
      run({ 'class' => 'OkJob', 'jid' => 'jid-ok' }) { sql('SELECT ok') }
      error = ErroredUnitsSpecError.new('job failed')
      escaped = begin
        run do
          3.times { |i| sql("SELECT #{i}") }
          raise error
        end
      rescue ErroredUnitsSpecError => e
        e
      end

      ok, failed = job_lines
      expect(escaped).to equal(error)
      expect(failed).to include('status' => 500, 'query_count' => 3, 'search_count' => 0, 'level' => 'error')
      expect(failed['spans'].map { |s| s['name'] }).to eq(['SELECT 0', 'SELECT 1', 'SELECT 2'])
      expect(crumb_messages(failed['breadcrumbs'])).to eq(['SELECT 0', 'SELECT 1', 'SELECT 2'])
      expect(failed.keys - %w[exception stack_trace]).to match_array(ok.keys)
    end

    it 'whose result fails to build: a success stays a success, and a failure keeps its own exception' do
      allow(Koderift::Rails::Instrumentation).to receive(:build_result).and_raise(NoMethodError, 'gem bug')
      error = ErroredUnitsSpecError.new('job failed')

      expect(run { sql('SELECT 1'); :done }).to eq(:done)
      expect { run { raise error } }.to raise_error { |e| expect(e).to equal(error) }

      done, failed = job_lines
      expect(done).to include('status' => 200)
      expect(done).not_to include('spans', 'query_count')
      expect(failed).to include('status' => 500, 'exception' => 'ErroredUnitsSpecError: job failed')
      expect(failed).not_to include('spans', 'query_count')
    end

    it 'stopped by an Interrupt (Sidekiq::Shutdown) writes no line and leaves nothing on the thread' do
      expect { run { sql('SELECT 1'); raise ErroredUnitsSpecStop } }.to raise_error(ErroredUnitsSpecStop)

      expect(job_lines).to be_empty
      expect(Thread.current[:koderift_capture_frames]).to be_nil
      expect(Thread.current[:koderift_breadcrumbs]).to be_nil
    end

    it 'with max_breadcrumbs set to nil or a String never fails' do
      [nil, '20'].each do |value|
        Koderift::Rails.configuration.max_breadcrumbs = value
        expect(run { sql('SELECT 1'); :done }).to eq(:done)
      end
      expect(job_lines.map { |l| l['status'] }).to eq([200, 200])
    end

    it "a controller it runs whose handler took an error is marked rescued, and the handler keeps the job's context" do
      klass = Class.new(widgets) { define_singleton_method(:name) { 'InJobErroredController' } }
      line = nil
      run do
        _, line, = dispatch(klass, :boom, 'req-in-job')
      end

      expect(line[:rescued]).to eq('ArgumentError')
      expect(capture('bad widget')['request_id']).to eq('jid-1')
    end
  end
end
