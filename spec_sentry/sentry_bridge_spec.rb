# frozen_string_literal: true

require_relative 'sentry_helper'
require 'concurrent'
require 'koderift/rails/sidekiq_middleware'

class BridgeWrapperError < StandardError; end

RSpec.describe Koderift::Rails::SentryBridge do
  before(:all) { Koderift::Rails::Railtie.include_controller_concern }

  let(:bridge)  { described_class }
  let(:current) { Koderift::Rails::TraceContext::Current }
  let!(:gem_lines) { collect_gem_lines }

  let(:controller) do
    Class.new(ActionController::Base) do
      define_singleton_method(:name) { 'BridgeWidgetsController' }

      rescue_from KeyError, with: :wrap_key_error

      def boom
        Koderift.with_child_span(op: 'work') { nil.upcase }
      end

      def wrapped
        raise KeyError, 'key not found: :plan'
      end

      # Reported both ways from inside the action, while the request is live.
      def manual
        Koderift.with_child_span(op: 'work') do
          error = RuntimeError.new('handled')
          Koderift.capture_exception(error)
          Sentry.capture_exception(error)
        end
        render json: { ok: true }
      end

      def keyless
        Sentry.capture_message('keyless inside the request')
        render json: { ok: true }
      end

      def ok
        render json: { ok: true }
      end

      private

      def wrap_key_error(_error)
        raise BridgeWrapperError, 'could not load the plan'
      end
    end
  end

  # sentry-rails reports a request's exception from Rack middleware, after
  # the controller (and the gem's around_action) has finished.
  # Sentry::Rack::CaptureExceptions is the same capture, without Rails.
  def through_sentry_rack(action, request_id = 'req-123')
    error    = nil
    payloads = collect_request_payloads do
      Sentry::Rack::CaptureExceptions.new(controller.action(action)).call(rack_env(request_id))
    rescue StandardError => e
      error = e
    end
    [payloads.last, error]
  end

  def dispatch(action, request_id = 'req-123')
    payloads = collect_request_payloads do
      controller.action(action).call(rack_env(request_id))
    rescue StandardError
      nil
    end
    payloads.last
  end

  def run_job(job, &body)
    Koderift::Rails::SidekiqMiddleware.new.call(nil, job, 'default', &body)
  end

  def job_line(jid)
    json_lines(gem_lines).find { |line| line['jid'] == jid }
  end

  # A live request frame, as the controller pushes one.
  def in_live_request(request_id = 'r-1', trace_id = 'a' * 32)
    frame = current.push(kind: :request, trace_id: trace_id, context: { request_id: request_id })
    yield
  ensure
    current.pop(frame)
  end

  # ------------------------------------------------------------- installing

  describe 'installing' do
    before { configure_koderift }

    # Test 2.
    it 'installs nothing while sentry-ruby is loaded but not initialised, and changes nothing' do
      expect(Sentry.initialized?).to be false

      payload = dispatch(:ok)
      run_job('class' => 'BridgeJob', 'jid' => 'jid-not-initialised') { nil }
      Koderift.capture_exception(RuntimeError.new('outside'))

      expect(bridge.install_if_ready).to be false
      expect(Sentry::Scope.global_event_processors).to be_empty
      expect(payload[:koderift_request_id]).to eq('req-123')
      expect(job_line('jid-not-initialised')['status']).to eq(200)
      expect(json_lines(gem_lines).last).not_to have_key('request_id')
      expect(Thread.current[:koderift_closed_jid]).to be_nil
    end

    it 'registers the processor exactly once, however many threads race to install it' do
      init_sentry
      start   = Concurrent::CountDownLatch.new(1)
      threads = Array.new(8) { Thread.new { start.wait(5); bridge.install_if_ready } }
      start.count_down

      expect(threads.map(&:value)).to all(be true)
      expect(bridge_processors).to eq(1)
      expect(Sentry::Scope.global_event_processors.size).to eq(1)
    end

    it 'installs at the first request once Sentry is initialised late' do
      dispatch(:ok)
      expect(bridge.installed?).to be false

      init_sentry
      dispatch(:ok)

      expect(bridge.installed?).to be true
      expect(bridge_processors).to eq(1)
    end

    it 'installs at the first job once Sentry is initialised late' do
      init_sentry
      run_job('class' => 'BridgeJob', 'jid' => 'jid-late') { nil }

      expect(bridge.installed?).to be true
    end

    # Sentry::TestHelper#teardown_sentry_test clears the list between an
    # app's tests.
    it "adds the processor back, once, after something clears Sentry's list" do
      init_sentry
      bridge.install_if_ready
      Sentry::Scope.global_event_processors.clear

      expect(bridge.install_if_ready).to be true
      expect(bridge.install_if_ready).to be true
      expect(bridge_processors).to eq(1)
    end

    it 'gives up for good when an add does not stick, rather than adding on every call' do
      init_sentry
      allow(Sentry).to receive(:add_global_event_processor)

      expect(bridge.install_if_ready).to be false
      expect(bridge.install_if_ready).to be false
      dispatch(:ok)

      expect(Sentry).to have_received(:add_global_event_processor).once
      expect(bridge.active?).to be false
    end

    it 'gives up for good when the add raises, rather than raising on every request' do
      init_sentry
      allow(Sentry).to receive(:add_global_event_processor).and_raise(FrozenError, "can't modify frozen Array")

      expect(bridge.install_if_ready).to be false
      dispatch(:ok)
      expect(bridge.install_if_ready).to be false

      expect(Sentry).to have_received(:add_global_event_processor).once
    end
  end

  # --------------------------------------------------------------- requests

  describe 'a request' do
    before do
      configure_koderift
      init_sentry
    end

    # Test 3: sentry-rails' own request_id stays, and the trace and span are
    # the request line's, although the gem's unit has closed by then.
    it "tags the error Sentry reports after the request with the request line's trace and span" do
      payload, error = through_sentry_rack(:boom)
      event = sentry_events.last

      expect(error).to be_a(NoMethodError)
      expect(sentry_events.size).to eq(1)
      expect(event.tags[:request_id]).to eq('req-123')
      expect(event.tags).not_to have_key('request_id')
      expect(event.tags['koderift_trace_id']).to eq(payload[:koderift_trace_id])
      expect(event.tags['koderift_span_id']).to eq(payload[:koderift_span_id])
      expect(event.tags['koderift_trace_id']).to match(/\A\h{32}\z/)
    end

    # rescue_from runs outside the around_action, and its handler raises a
    # new exception. The finished request is matched by key, not by exception.
    it 'tags a wrapper error raised by a rescue_from handler the same way' do
      payload, error = through_sentry_rack(:wrapped)
      event = sentry_events.last

      expect(error).to be_a(BridgeWrapperError)
      expect(error.cause).to be_a(KeyError)
      expect(event.tags[:request_id]).to eq('req-123')
      expect(event.tags['koderift_trace_id']).to eq(payload[:koderift_trace_id])
      expect(event.tags['koderift_span_id']).to eq(payload[:koderift_span_id])
    end

    it "matches the gem's capture line when both report from inside the action" do
      payload, = through_sentry_rack(:manual)
      capture  = json_lines(gem_lines).find { |line| line['koderift_capture'] }
      event    = sentry_events.last
      child    = payload[:koderift_spans].find { |span| span[:name] == 'work' }

      expect(event.tags[:request_id]).to eq(capture['request_id'])
      expect(event.tags['koderift_trace_id']).to eq(capture['trace_id'])
      expect(event.tags['koderift_span_id']).to eq(capture['span_id'])
      expect(capture['span_id']).to eq(child[:span_id])
      expect(capture['trace_id']).to eq(payload[:koderift_trace_id])
    end

    it 'gives a keyless event inside the request the request ID the gem logs' do
      payload = dispatch(:keyless)
      event   = sentry_events.last

      expect(koderift_tags(event)).to eq(
        'request_id'        => 'req-123',
        'koderift_trace_id' => payload[:koderift_trace_id],
        'koderift_span_id'  => payload[:koderift_span_id]
      )
    end

    # A client resends an X-Request-Id, and the second request fails before
    # the controller runs. Its env has no trace of the gem's, so it gets none,
    # never the first request's.
    it 'gives a reused request ID that fails before the controller no trace, not the earlier one' do
      through_sentry_rack(:boom, 'req-reused')
      expect(sentry_events.last.tags).to have_key('koderift_trace_id')

      failing_middleware = ->(_env) { raise IOError, 'session store down' }
      begin
        Sentry::Rack::CaptureExceptions.new(failing_middleware).call(rack_env('req-reused'))
      rescue IOError
        nil
      end

      expect(sentry_events.size).to eq(2)
      expect(koderift_tags(sentry_events.last)).to eq('request_id' => 'req-reused')
    end

    it 'gives a request that fails in a prepended before_action, outside the gem, no trace' do
      through_sentry_rack(:boom, 'req-reused')
      guarded = Class.new(controller) do
        prepend_before_action { raise ArgumentError, 'refused before the gem' }
      end
      begin
        Sentry::Rack::CaptureExceptions.new(guarded.action(:ok)).call(rack_env('req-reused'))
      rescue ArgumentError
        nil
      end

      expect(sentry_events.last.exception.values.last.type).to eq('ArgumentError')
      expect(koderift_tags(sentry_events.last)).to eq('request_id' => 'req-reused')
    end

    # The app's own String 'request_id' tag sits beside Sentry's Symbol one.
    # The bridge reads the String first, which is not the request in Sentry's
    # env, so it adds no trace. The envelope keeps the later key (Sentry's),
    # so this costs the trace only, never a wrong one.
    it "adds no trace when the event's request key is not the request Sentry is reporting" do
      controller.define_method(:own_request_id) do
        Sentry.set_tags('request_id' => 'app-chosen-id')
        raise ArgumentError, 'boom'
      end

      through_sentry_rack(:own_request_id, 'req-env')
      event = sentry_events.last

      expect(event.tags['request_id']).to eq('app-chosen-id')
      expect(event.tags).not_to have_key('koderift_trace_id')
      expect(event.tags).not_to have_key('koderift_span_id')
    end

    # ActionController::Live runs the action, and the gem's around_action, on
    # a child thread. The env is shared, so the event still gets the trace.
    it 'tags an ActionController::Live action that raises' do
      live = Class.new(ActionController::Base) do
        include ActionController::Live
        define_singleton_method(:name) { 'BridgeLiveController' }

        def stream
          raise ArgumentError, 'live boom'
        end
      end

      payloads = collect_request_payloads do
        Sentry::Rack::CaptureExceptions.new(live.action(:stream)).call(rack_env('live-1'))
      rescue ArgumentError
        nil
      end
      event = sentry_events.last

      expect(event.tags[:request_id]).to eq('live-1')
      expect(event.tags['koderift_trace_id']).to eq(payloads.last[:koderift_trace_id])
      expect(event.tags['koderift_span_id']).to eq(payloads.last[:koderift_span_id])
    end

    # Inside a transaction the live unit is the transaction (its own request
    # ID), so the event's request key is matched to the request's env.
    it "gives a capture inside a nested transaction the request's trace" do
      controller.define_method(:nested) do
        Koderift.start_transaction(name: 'Inner#work') { Sentry.capture_message('inside the transaction') }
        render json: { ok: true }
      end

      payload, = through_sentry_rack(:nested, 'req-nested')
      event = sentry_events.last

      expect(event.tags[:request_id]).to eq('req-nested')
      expect(event.tags['koderift_trace_id']).to eq(payload[:koderift_trace_id])
      expect(event.tags['koderift_span_id']).to eq(payload[:koderift_span_id])
    end

    # Sentry's scope holds another request's env while this request is live
    # (a reused ActionController::Live thread under hub_isolation_level
    # :fiber, or a hub a fiber server shares). The event keeps Sentry's key
    # and gets no trace from that env.
    it "adds no trace from another request's env to a capture inside a live request" do
      controller.define_method(:stale_scope) do
        stale = Rack::MockRequest.env_for('/other').merge(
          'action_dispatch.request_id' => 'req-stale',
          'koderift.trace_id'          => 'b' * 32,
          'koderift.span_id'           => 'c' * 16
        )
        Sentry.with_scope do |scope|
          scope.set_rack_env(stale)
          Sentry.capture_message('inside a live request, on a stale scope')
        end
        render json: { ok: true }
      end

      through_sentry_rack(:stale_scope, 'req-live')
      event = sentry_events.last

      expect(event.tags[:request_id]).to eq('req-stale')
      expect(event.tags).not_to have_key('koderift_trace_id')
      expect(event.tags).not_to have_key('koderift_span_id')
    end

    it 'adds no rescue clause: the failing request raises from the gem exactly as often as before' do
      gem_raises = []
      trace = TracePoint.new(:raise) do |tp|
        gem_raises << tp.path if tp.path.include?('/lib/koderift/')
      end
      trace.enable { through_sentry_rack(:boom) }

      expect(bridge.active?).to be true
      expect(gem_raises).to be_empty
    end
  end

  # ------------------------------------------------------------------- jobs

  describe 'a Sidekiq job' do
    let(:jid) { 'a1b2c3d4e5f6a1b2c3d4e5f6' }
    let(:job) { { 'class' => 'BridgeJob', 'jid' => jid } }

    before do
      configure_koderift
      init_sentry
    end

    # sentry-sidekiq gives each attempt its own hub and tags it with the jid
    # in its server middleware, then reports from Sidekiq's error handlers,
    # after every middleware is done.
    def fail_like_sentry_sidekiq(job)
      Sentry.clone_hub_to_current_thread
      Sentry.with_scope do |scope|
        scope.set_tags(jid: job['jid'], queue: 'default')
        begin
          run_job(job) { raise ArgumentError, 'user 7 is not active' }
        rescue ArgumentError => e
          Sentry.capture_exception(e)
        end
      end
    end

    it "tags the failure Sentry reports after the job with the job line's trace and span" do
      fail_like_sentry_sidekiq(job)
      line  = job_line(jid)
      event = sentry_events.last

      expect(line['status']).to eq(500)
      expect(event.tags[:jid]).to eq(jid)
      expect(koderift_tags(event)).to eq(
        'request_id'        => jid,
        'koderift_trace_id' => line['trace_id'],
        'koderift_span_id'  => line['span_id']
      )
    end

    # A retry of the same jid on the same thread: the live attempt wins over
    # the attempt that finished before it.
    it 'uses the live attempt, not the previous attempt of the same jid' do
      fail_like_sentry_sidekiq(job)
      first_trace = job_line(jid)['trace_id']

      live_trace = nil
      Sentry.with_scope do |scope|
        scope.set_tags(jid: jid)
        run_job(job) do
          live_trace = current.trace_id
          Sentry.capture_message('inside the retry')
        end
      end

      expect(live_trace).not_to eq(first_trace)
      expect(sentry_events.last.tags['koderift_trace_id']).to eq(live_trace)
    end

    # A retry keeps the jid. If it fails in an app middleware that runs before
    # the gem's, it never reaches the gem, and Sentry reports it on the new
    # attempt's hub: it must not get the previous attempt's trace.
    it "gives a retry that fails before the gem's middleware nothing from the previous attempt" do
      fail_like_sentry_sidekiq(job)
      expect(sentry_events.last.tags).to have_key('koderift_trace_id')

      Sentry.clone_hub_to_current_thread
      Sentry.with_scope do |scope|
        scope.set_tags(jid: jid)
        begin
          raise ArgumentError, 'tenant switch failed'
        rescue ArgumentError => e
          Sentry.capture_exception(e)
        end
      end

      expect(sentry_events.size).to eq(2)
      expect(koderift_tags(sentry_events.last)).to be_empty
    end
  end

  # -------------------------------------------------- keys that do not match

  describe 'an event whose key names another unit' do
    before do
      configure_koderift
      init_sentry
      bridge.install_if_ready
    end

    it 'gets nothing for a request key when Sentry holds no Rack env, after another request finished' do
      dispatch(:boom, 'req-a')

      Sentry.with_scope do |scope|
        scope.set_tags(request_id: 'req-b')
        Sentry.capture_message('someone else')
      end

      expect(koderift_tags(sentry_events.last)).to eq('request_id' => 'req-b')
    end

    it 'gets nothing from a live unit whose ID differs (a job run inline inside another job)' do
      frame = current.push(kind: :job, trace_id: 'c' * 32, context: { request_id: 'outer-jid' })
      Sentry.with_scope do |scope|
        scope.set_tags(jid: 'inner-jid')
        Sentry.capture_message('inner jid left on the hub')
      end
      current.pop(frame)

      expect(bridge.active?).to be true
      expect(koderift_tags(sentry_events.last)).to be_empty
    end

    it 'gets nothing when it has no key and no unit is live, outside a rake run' do
      dispatch(:boom, 'req-a')
      Rake.with_application(Rake::Application.new) { Sentry.capture_message('after the request') }

      expect(bridge.active?).to be true
      expect(koderift_tags(sentry_events.last)).to be_empty
    end

    # An abandoned non-block transaction stays on the thread's stack; the
    # finished request still wins, because the event's key names it.
    it 'prefers the finished request it names over a stale transaction left live' do
      transaction = Koderift.start_transaction(name: 'Stale#run')
      payload, = through_sentry_rack(:boom)
      event = sentry_events.last
      transaction.finish

      expect(event.tags['koderift_trace_id']).to eq(payload[:koderift_trace_id])
      expect(event.tags['koderift_trace_id']).not_to eq(transaction.trace_id)
    end
  end

  # ------------------------------------------------------------ app's own tags

  # Test 4.
  describe "an app's own tags" do
    before do
      configure_koderift
      init_sentry
      bridge.install_if_ready
    end

    it 'are never overwritten, as Strings or Symbols, from the scope or the capture' do
      in_live_request('r-live') do
        Sentry.with_scope do |scope|
          scope.set_tags('request_id' => 'r-live', koderift_trace_id: 'app-trace')
          Sentry.capture_message('scope tags')
        end
        Sentry.capture_message('capture tags') do |scope|
          scope.set_tag(:request_id, 'r-live')
          scope.set_tag('koderift_trace_id', 'app-trace-2')
        end
        # A positive control in the same unit: the bridge is on and adds tags.
        Sentry.capture_message('no app tags')
      end

      first, second, control = sentry_events.last(3)
      expect(first.tags).to eq('request_id' => 'r-live', koderift_trace_id: 'app-trace')
      expect(second.tags).to eq(request_id: 'r-live', 'koderift_trace_id' => 'app-trace-2')
      expect(koderift_tags(control)).to include('request_id' => 'r-live', 'koderift_trace_id' => 'a' * 32)
    end

    it 'leave a request event exactly as it is with the bridge off, when the app set the trace tag' do
      controller.define_method(:own_trace) do
        Sentry.set_tags(koderift_trace_id: 'app-trace')
        raise ArgumentError, 'boom'
      end

      through_sentry_rack(:own_trace)
      configure_koderift(sentry_bridge: false)
      through_sentry_rack(:own_trace)

      on, off = sentry_events.last(2)
      expect(on.tags).to eq(off.tags)
      expect(on.tags).to eq(request_id: 'req-123', koderift_trace_id: 'app-trace')
    end
  end

  # ------------------------------------------------------- internal failures

  # Test 7.
  describe 'an internal error' do
    before do
      configure_koderift
      init_sentry
      bridge.install_if_ready
    end

    it 'returns the same event, unchanged, and Sentry still sends it' do
      in_live_request do
        allow(Koderift::Rails::TraceContext::Current).to receive(:trace_id).and_raise(NoMethodError, 'internal')

        event = Sentry.get_current_client.event_from_message('direct')
        event.tags = { 'app' => '1' }
        expect(bridge::PROCESSOR.call(event, {})).to equal(event)
        expect(event.tags).to eq('app' => '1')

        Sentry.capture_message('through Sentry')
      end

      expect(sentry_events.size).to eq(1)
      expect(koderift_tags(sentry_events.last)).to be_empty
    end

    it 'takes a nil hint and a frozen tags hash' do
      event  = Sentry.get_current_client.event_from_message('frozen')
      frozen = { 'app' => '1' }.freeze
      event.tags = frozen

      in_live_request { expect(bridge::PROCESSOR.call(event, nil)).to equal(event) }

      expect(frozen).to eq('app' => '1')
      expect(event.tags).to include('app' => '1', 'request_id' => 'r-1', 'koderift_trace_id' => 'a' * 32)
    end
  end

  # ---------------------------------------------------------------- tag cap

  # Test 8.
  describe 'the 50-tag limit' do
    before do
      configure_koderift
      init_sentry
      bridge.install_if_ready
    end

    def capture_with_tags(count)
      in_live_request do
        Sentry.with_scope do |scope|
          scope.set_tags((1..count).to_h { |i| ["app_tag_#{i}", i.to_s] })
          Sentry.capture_message("#{count} tags")
        end
      end
      sentry_events.last
    end

    it 'adds request_id only to an event holding 49 tags' do
      event = capture_with_tags(49)

      expect(event.tags.size).to eq(50)
      expect(koderift_tags(event).keys).to eq(['request_id'])
    end

    it 'adds nothing to an event holding 50 tags' do
      expect(capture_with_tags(50).tags.size).to eq(50)
    end

    it 'adds request_id and the trace to an event holding 48 tags' do
      event = capture_with_tags(48)

      expect(event.tags.size).to eq(50)
      expect(koderift_tags(event).keys).to eq(%w[request_id koderift_trace_id])
    end

    it 'adds all three to an event holding 47 tags' do
      event = capture_with_tags(47)

      expect(event.tags.size).to eq(50)
      expect(koderift_tags(event).keys).to eq(%w[request_id koderift_trace_id koderift_span_id])
    end
  end

  # ---------------------------------------------------------------- the switch

  # Test 9.
  describe 'config.sentry_bridge = false' do
    before { init_sentry }

    it 'registers nothing, records nothing and gives no rake run ID' do
      configure_koderift(sentry_bridge: false)
      through_sentry_rack(:boom)
      run_job('class' => 'BridgeJob', 'jid' => 'jid-off') { nil }

      expect(Sentry::Scope.global_event_processors).to be_empty
      expect(Thread.current[:koderift_closed_jid]).to be_nil
      expect(bridge.rake_run_id).to be_nil
      expect(koderift_tags(sentry_events.last)).to eq('request_id' => 'req-123')
    end

    it 'stops tagging, recording and the rake run ID when turned off after install' do
      configure_koderift
      through_sentry_rack(:boom, 'req-before')
      expect(sentry_events.last.tags).to have_key('koderift_trace_id')
      run_job('class' => 'BridgeJob', 'jid' => 'jid-before') { nil }
      expect(Thread.current[:koderift_closed_jid]).to eq('jid-before')

      Koderift::Rails.configuration.sentry_bridge = false
      through_sentry_rack(:boom, 'req-after')
      run_job('class' => 'BridgeJob', 'jid' => 'jid-after') { nil }

      expect(koderift_tags(sentry_events.last)).to eq('request_id' => 'req-after')
      expect(Thread.current[:koderift_closed_jid]).to eq('jid-before')
      expect(bridge.rake_run_id).to be_nil
    end

    it 'is off the same way without a project token or with the gem disabled' do
      configure_koderift(token: nil)
      through_sentry_rack(:boom)
      expect(Sentry::Scope.global_event_processors).to be_empty

      configure_koderift(enabled: false)
      through_sentry_rack(:boom)
      expect(Sentry::Scope.global_event_processors).to be_empty
      expect(koderift_tags(sentry_events.last)).to eq('request_id' => 'req-123')
    end
  end

  # ------------------------------------------------------------ thread safety

  describe 'two threads' do
    before do
      configure_koderift
      init_sentry
      bridge.install_if_ready
    end

    # Test 10: two live requests capture at the same moment.
    it 'tag events captured at the same moment inside two live requests with their own unit' do
      barrier = Concurrent::CyclicBarrier.new(2)
      controller.define_method(:together) do
        barrier.wait(5)
        Sentry.capture_message("from #{request.request_id}")
        render json: { ok: true }
      end

      payloads = collect_request_payloads do
        %w[req-a req-b].map { |id| Thread.new { controller.action(:together).call(rack_env(id)) } }.each(&:join)
      end
      by_id = payloads.to_h { |p| [p[:koderift_request_id], p] }

      %w[req-a req-b].each do |id|
        event = sentry_events.find { |e| e.message == "from #{id}" }
        expect(koderift_tags(event)).to eq(
          'request_id'        => id,
          'koderift_trace_id' => by_id[id][:koderift_trace_id],
          'koderift_span_id'  => by_id[id][:koderift_span_id]
        )
      end
      expect(by_id['req-a'][:koderift_trace_id]).not_to eq(by_id['req-b'][:koderift_trace_id])
    end

    # Both requests finish before either thread's Sentry capture runs. Each
    # event is read from the env of the request Sentry is reporting, so it gets
    # its own request's trace and never the other's.
    it "tag each Sentry event with its own finished request's trace after both have finished" do
      barrier = Concurrent::CyclicBarrier.new(2)
      seen    = Concurrent::Map.new
      after_both = Class.new do
        define_method(:initialize) { |app| @app = app }
        define_method(:call) do |env|
          @app.call(env)
        rescue Exception # rubocop:disable Lint/RescueException
          # The gem's unit has closed on this thread: nothing is live.
          seen[env['action_dispatch.request_id']] = [Thread.current[:koderift_context], Thread.current[:koderift_trace_id]]
          barrier.wait(5)
          raise
        end
      end
      app = Sentry::Rack::CaptureExceptions.new(after_both.new(controller.action(:boom)))

      payloads = collect_request_payloads do
        %w[req-a req-b].map do |id|
          Thread.new do
            app.call(rack_env(id))
          rescue NoMethodError
            nil
          end
        end.each(&:join)
      end
      by_id = payloads.to_h { |p| [p[:koderift_request_id], p] }

      expect(sentry_events.size).to eq(2)
      %w[req-a req-b].each do |id|
        other = (%w[req-a req-b] - [id]).first
        event = sentry_events.find { |e| e.tags[:request_id] == id }

        expect(seen[id]).to eq([nil, nil])
        expect(event.tags['koderift_trace_id']).to eq(by_id[id][:koderift_trace_id])
        expect(event.tags['koderift_span_id']).to eq(by_id[id][:koderift_span_id])
        expect(event.tags['koderift_trace_id']).not_to eq(by_id[other][:koderift_trace_id])
      end
    end
  end

  describe 'two Sidekiq threads' do
    let(:jids) { %w[aaaaaaaaaaaaaaaaaaaaaaaa bbbbbbbbbbbbbbbbbbbbbbbb] }

    before do
      configure_koderift
      init_sentry
      bridge.install_if_ready
    end

    # The finished job is held per thread, in Thread.current (where the gem
    # keeps its trace). Both jobs finish before either thread reports, as
    # sentry-sidekiq's error handler does, and each gets only its own trace.
    it "tag each Sentry event with its own finished job's trace after both have finished" do
      barrier = Concurrent::CyclicBarrier.new(2)
      seen    = Concurrent::Map.new

      jids.map do |jid|
        Thread.new do
          Sentry.clone_hub_to_current_thread
          Sentry.with_scope do |scope|
            scope.set_tags(jid: jid)
            begin
              run_job('class' => 'BridgeJob', 'jid' => jid) { raise ArgumentError, "job #{jid}" }
            rescue ArgumentError => e
              seen[jid] = [Thread.current[:koderift_context], Thread.current[:koderift_closed_jid]]
              barrier.wait(5)
              Sentry.capture_exception(e)
            end
          end
        end
      end.each(&:join)

      expect(sentry_events.size).to eq(2)
      jids.each do |jid|
        other = (jids - [jid]).first
        event = sentry_events.find { |e| e.tags[:jid] == jid }

        expect(seen[jid]).to eq([nil, jid])
        expect(koderift_tags(event)).to eq(
          'request_id'        => jid,
          'koderift_trace_id' => job_line(jid)['trace_id'],
          'koderift_span_id'  => job_line(jid)['span_id']
        )
        expect(event.tags['koderift_trace_id']).not_to eq(job_line(other)['trace_id'])
      end
    end
  end

  # --------------------------------------------------------------- event kinds

  describe 'events other than errors' do
    before do
      configure_koderift
      init_sentry(traces_sample_rate: 1.0)
      bridge.install_if_ready
    end

    it 'leaves check-ins and transactions untouched' do
      in_live_request do
        Sentry.capture_check_in('nightly', :ok)
        Sentry.start_transaction(name: 'Sentry txn', op: 'task').finish
        Sentry.capture_message('an error event')
      end

      check_in    = sentry_events.find { |e| e.is_a?(Sentry::CheckInEvent) }
      transaction = sentry_events.find { |e| e.is_a?(Sentry::TransactionEvent) }
      message     = sentry_events.find { |e| e.is_a?(Sentry::ErrorEvent) }

      expect(check_in).not_to be_nil
      expect(transaction).not_to be_nil
      expect(koderift_tags(check_in)).to be_empty
      expect(koderift_tags(transaction)).to be_empty
      expect(koderift_tags(message)).to include('request_id' => 'r-1')
    end
  end
end
