require 'spec_helper'

RSpec.describe Koderift::Rails::Tracing do
  include_context 'a captured log'

  def sql_listeners
    ActiveSupport::Notifications.notifier.listeners_for('sql.active_record').size
  end

  describe '.with_child_span' do
    it 'returns the block value' do
      expect(Koderift.with_child_span(op: 'db') { 42 }).to eq 42
    end

    it 'records a custom span inside a unit of work' do
      result = Koderift::Rails::Instrumentation.capture do
        Koderift.with_child_span(op: 'stripe', description: 'charge') do |span|
          span.set_data(:amount, 500)
        end
      end

      span = result[:spans].find { |s| s[:type] == 'custom' }
      expect(span[:name]).to eq 'charge'
      expect(JSON.parse(span[:detail])).to eq('amount' => 500, 'op' => 'stripe')
    end

    it 'falls back to the op when no description is given' do
      result = Koderift::Rails::Instrumentation.capture do
        Koderift.with_child_span(op: 'stripe') { nil }
      end

      expect(result[:spans].first[:name]).to eq 'stripe'
    end

    # Not a stub: the same call inside a request, job or transaction produces a
    # real span. Outside one there is simply no collection to append to.
    it 'still yields outside a unit of work, recording nothing' do
      ran = false

      Koderift.with_child_span(op: 'db') { ran = true }

      expect(ran).to be true
      expect(Thread.current[:koderift_custom_spans]).to be_nil
    end

    it 'records the span even when the block raises' do
      spans = nil
      expect do
        Koderift::Rails::Instrumentation.capture do
          spans = Thread.current[:koderift_custom_spans]
          Koderift.with_child_span(op: 'db') { raise 'boom' }
        end
      end.to raise_error('boom')

      expect(spans.size).to eq 1
    end
  end

  describe '.start_transaction' do
    it 'emits one line with a duration and the collected spans' do
      Koderift.start_transaction(name: 'nightly:sync', op: 'rake') do
        Koderift.with_child_span(op: 'http', description: 'panel fetch') { nil }
      end

      payload = last_payload
      expect(payload['component']).to eq 'nightly:sync'
      expect(payload['action']).to    eq 'rake'
      expect(payload['duration']).to  be_a(Integer)
      expect(payload['spans'].map { |s| s['name'] }).to eq ['panel fetch']
    end

    # IngestLogBatchJob#build_span_rows does `next if request_id.blank?`, so
    # without an id every span here is dropped before reaching log_spans and the
    # trace arrives empty with nothing to explain why.
    it 'always carries a request id, or its spans would be silently discarded' do
      Koderift.start_transaction(name: 'nightly:sync') { nil }

      expect(last_payload['request_id']).to match(/\A[0-9a-f-]{36}\z/)
      expect(last_payload['trace_id']).not_to be_empty
    end

    it 'returns the block value' do
      value = Koderift.start_transaction(name: 'nightly:sync') { :done }

      expect(value).to eq :done
    end

    it 'gives captures inside it the transaction as their context' do
      Koderift.start_transaction(name: 'nightly:sync', op: 'rake') do
        Koderift.capture_exception(raised)
      end

      capture = capture_lines.map { |(_, m)| JSON.parse(m) }.find { |p| p['exception'] }
      expect(capture['component']).to eq 'nightly:sync'
      expect(capture['action']).to    eq 'rake'
      expect(capture['trace_id']).not_to be_empty
    end

    it 'restores the surrounding trace id and context' do
      Thread.current[:koderift_trace_id] = 'outer-trace'

      Koderift.start_transaction(name: 'nightly:sync') { nil }

      expect(Thread.current[:koderift_trace_id]).to eq 'outer-trace'
      expect(Thread.current[:koderift_context]).to be_nil
    end

    it 'unsubscribes cleanly' do
      before = sql_listeners
      Koderift.start_transaction(name: 'nightly:sync') { nil }

      expect(sql_listeners).to eq before
    end

    it 'finishes even when the body raises' do
      before = sql_listeners

      expect do
        Koderift.start_transaction(name: 'nightly:sync') { raise 'boom' }
      end.to raise_error('boom')

      expect(sql_listeners).to eq before
      expect(capture_lines.size).to eq 1
    end
  end

  describe 'the non-block form' do
    it 'returns a transaction that emits on finish' do
      transaction = Koderift.start_transaction(name: 'nightly:sync')
      expect(capture_lines).to be_empty

      transaction.finish
      expect(last_payload['component']).to eq 'nightly:sync'
    end

    it 'is idempotent on repeated finish' do
      transaction = Koderift.start_transaction(name: 'nightly:sync')
      transaction.finish
      transaction.finish

      expect(capture_lines.size).to eq 1
    end

    # An abandoned transaction leaves four notification subscribers attached to
    # the process, so starting a new one closes the old one first. That bounds
    # the leak to one per thread; the block form avoids it entirely.
    it 'finishes an abandoned transaction on the same thread' do
      before = sql_listeners
      first  = Koderift.start_transaction(name: 'first')
      second = Koderift.start_transaction(name: 'second')

      expect(first).to be_finished
      second.finish
      expect(sql_listeners).to eq before
    end
  end
end
