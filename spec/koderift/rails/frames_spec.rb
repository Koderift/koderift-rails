require 'spec_helper'
require 'koderift/rails/sidekiq_middleware'

# The per-thread frame stacks that keep units of work from leaking into each
# other: concurrent threads, nested transactions, abandoned transactions, and
# jobs run inline inside another unit.
RSpec.describe 'trace and capture frames' do
  include_context 'a captured log'

  let(:current) { Koderift::Rails::TraceContext::Current }

  # An abandoned transaction left on the thread would otherwise be finished
  # by the next spec's start_transaction and add a line to its log.
  after do
    leftover = Koderift::Rails::Tracing.current_transaction
    leftover.finish if leftover && !leftover.finished?
  end
  let(:trace_a) { 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' }
  let(:trace_b) { 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' }

  def sql(text)
    ActiveSupport::Notifications.instrument('sql.active_record', sql: text, name: 'Load') {}
  end

  def published_state
    %i[koderift_trace_id koderift_context koderift_breadcrumbs koderift_custom_spans
       koderift_external_calls koderift_external_config koderift_trace_frames
       koderift_capture_frames].map { |key| Thread.current[key] }
  end

  # A request as the controller runs it, without Rails' dispatch.
  def simulate_request(trace_id)
    frame  = current.push(kind: :request, trace_id: trace_id, context: { component: 'R' })
    result = Koderift::Rails::Instrumentation.capture { yield }
    [frame, result]
  ensure
    current.pop(frame)
  end

  describe Koderift::Rails::FrameStack do
    let(:frame_class) do
      Class.new do
        include Koderift::Rails::FrameStack::Member
        attr_reader :value

        def initialize(value, restore_outside: false)
          @value           = value
          @restore_outside = restore_outside
        end
      end
    end
    let(:stack) { described_class.new(:spec_frames, [:spec_value]) { |f| [f.value] } }

    after { stack.clear! }

    it 'publishes the top frame and the one below when it pops' do
      outer = stack.push(frame_class.new(:outer))
      inner = stack.push(frame_class.new(:inner))
      expect(Thread.current[:spec_value]).to eq(:inner)

      stack.pop(inner)
      expect(Thread.current[:spec_value]).to eq(:outer)

      stack.pop(outer)
      expect(Thread.current[:spec_value]).to be_nil
    end

    it 'drops abandoned frames above the one that pops' do
      outer = stack.push(frame_class.new(:outer))
      stack.push(frame_class.new(:abandoned))

      expect(stack.pop(outer)).to be true
      expect(stack.top).to be_nil
      expect(Thread.current[:spec_value]).to be_nil
    end

    it 'touches nothing when the frame is already gone' do
      gone = stack.push(frame_class.new(:gone))
      stack.pop(gone)
      live = stack.push(frame_class.new(:live))

      expect(stack.pop(gone)).to be false
      expect(stack.top).to equal(live)
      expect(Thread.current[:spec_value]).to eq(:live)
    end

    it 'restores what the thread held before, for a restore_outside frame' do
      Thread.current[:spec_value] = :outside
      frame = stack.push(frame_class.new(:mine, restore_outside: true))
      stack.pop(frame)

      expect(Thread.current[:spec_value]).to eq(:outside)
    ensure
      Thread.current[:spec_value] = nil
    end
  end

  # ActiveSupport::Notifications subscribers are process-wide. Before 2.2 a
  # capture on one thread recorded every other thread's SQL as its own.
  it "does not record another thread's events" do
    ready  = Queue.new
    done   = Queue.new
    result = nil
    owner  = Thread.new do
      result = Koderift::Rails::Instrumentation.capture do
        ready << true
        done.pop
        sql('SELECT mine')
      end
    end

    ready.pop
    Thread.new { sql('SELECT from_another_thread') }.join
    done << true
    owner.join

    expect(result[:spans].map { |s| s[:name] }).to eq(['SELECT mine'])
    expect(result[:query_count]).to eq(1)
  end

  it 'records a nested transaction on its own line and gives the request its collections back' do
    _frame, result = simulate_request(trace_a) do
      sql('SELECT before')
      Koderift.start_transaction(name: 'inner') { sql('SELECT inside_transaction') }
      sql('SELECT after')
      Koderift.with_child_span(op: 'after_span') { nil }
      Koderift.add_breadcrumb('after crumb')
    end

    expect(result[:spans].select { |s| s[:type] == 'sql' }.map { |s| s[:name] })
      .to eq(['SELECT before', 'SELECT after'])
    expect(result[:spans].map { |s| s[:name] }).to include('after_span')
    expect(result[:breadcrumbs].map { |b| b[:message] }).to include('after crumb')

    transaction = JSON.parse(capture_lines.last[1])
    expect(transaction['spans'].map { |s| s['name'] }).to eq(['SELECT inside_transaction'])
  end

  # Request 1 abandons a non-block transaction. Request 2, on the same thread,
  # starts another, which finishes the abandoned one first. That finish must
  # not hand request 2 the state request 1 had.
  it 'keeps an abandoned transaction from leaking into a later request' do
    simulate_request(trace_a) do
      Koderift.start_transaction(name: 'abandoned')
      sql('SELECT in_request_1')
    end
    expect(published_state).to all(be_nil)

    frame2, result2 = simulate_request(trace_b) do
      Koderift.start_transaction(name: 'second') { nil }
      expect(Thread.current[:koderift_trace_id]).to eq(trace_b)
      sql('SELECT after_second_transaction')
      Koderift.with_child_span(op: 'request_2_span') { nil }
    end

    expect(frame2.trace_id).to eq(trace_b)
    expect(result2[:spans].map { |s| s[:name] })
      .to include('SELECT after_second_transaction', 'request_2_span')
    expect(published_state).to all(be_nil)
  end

  it 'hands a job back its own state after a job run inline inside it' do
    middleware = Koderift::Rails::SidekiqMiddleware.new
    outer_job  = { 'class' => 'OuterJob', 'jid' => 'outer', 'koderift_trace_id' => trace_a }
    inner_job  = { 'class' => 'InnerJob', 'jid' => 'inner', 'koderift_trace_id' => trace_b }
    seen_after = nil

    middleware.call(nil, outer_job, 'default') do
      middleware.call(nil, inner_job, 'default') { sql('SELECT inner') }
      seen_after = [Thread.current[:koderift_trace_id], Thread.current[:koderift_context][:component]]
      sql('SELECT outer_after_inline')
    end

    lines = capture_lines.map { |(_, m)| JSON.parse(m) }
    inner = lines.find { |l| l['jid'] == 'inner' }
    outer = lines.find { |l| l['jid'] == 'outer' }

    expect(seen_after).to eq([trace_a, 'OuterJob'])
    expect(inner['spans'].map { |s| s['name'] }).to eq(['SELECT inner'])
    expect(outer['spans'].map { |s| s['name'] }).to eq(['SELECT outer_after_inline'])
    expect(published_state).to all(be_nil)
  end

  # with_child_span records on the line of the unit it was opened in while
  # that unit runs, even if a transaction started in the block outlives it.
  it 'keeps a span on its own line when a transaction started inside it outlives the block' do
    transaction = nil
    _frame, result = simulate_request(trace_a) do
      Koderift.with_child_span(op: 'outer') { transaction = Koderift.start_transaction(name: 'outlives') }
      transaction.finish
    end

    outer = result[:spans].find { |s| s[:name] == 'outer' }
    line  = JSON.parse(capture_lines.last[1])

    expect(outer).not_to be_nil
    expect(line['parent_span_id']).to eq(outer[:span_id])
    expect(line['spans'].map { |s| s['name'] }).not_to include('outer')
  end

  it 'keeps a span when the transaction it was opened in finishes inside the block' do
    _frame, result = simulate_request(trace_a) do
      transaction = Koderift.start_transaction(name: 'ends_inside')
      Koderift.with_child_span(op: 'inner') { transaction.finish }
    end

    expect(result[:spans].map { |s| s[:name] }).to include('inner')
  end

  it 'clears everything at the end of a unit that raises' do
    expect do
      simulate_request(trace_a) do
        Koderift.start_transaction(name: 'abandoned')
        Koderift.with_child_span(op: 'open') { raise 'boom' }
      end
    end.to raise_error('boom')

    expect(published_state).to all(be_nil)
  end
end
