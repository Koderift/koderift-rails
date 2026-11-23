require 'spec_helper'
require 'koderift/rails/sidekiq_client_middleware'

RSpec.describe Koderift::Rails::SidekiqClientMiddleware do
  let(:middleware) { described_class.new }
  let(:current)    { Koderift::Rails::TraceContext::Current }
  let(:trace_id)   { '4bf92f3577b34da6a3ce929d0e0e4736' }
  let(:job)        { { 'class' => 'SendInvoiceJob', 'args' => [1] } }

  def enqueue(job)
    middleware.call('SendInvoiceJob', job, 'default', nil) { :pushed }
  end

  it 'yields and returns what the chain returns' do
    expect(enqueue(job)).to eq(:pushed)
  end

  it 'stores the trace and the enqueuing span on the job' do
    frame = current.push(kind: :request, trace_id: trace_id)
    enqueue(job)

    expect(job['koderift_traceparent']).to eq("00-#{trace_id}-#{frame.root_span_id}-01")
    expect(job['koderift_trace_id']).to eq(trace_id)
  ensure
    current.pop(frame)
  end

  it 'names the open with_child_span as the parent' do
    frame = current.push(kind: :request, trace_id: trace_id)
    span  = nil
    Koderift.with_child_span(op: 'enqueue') do
      span = current.current_span_id
      enqueue(job)
    end

    expect(job['koderift_traceparent']).to eq("00-#{trace_id}-#{span}-01")
  ensure
    current.pop(frame)
  end

  it 'never replaces a trace the job already carries' do
    frame = current.push(kind: :request, trace_id: trace_id)
    [{ 'koderift_traceparent' => 'original' }, { 'koderift_trace_id' => 'original' }].each do |keys|
      carried = job.merge(keys)
      enqueue(carried)

      expect(carried.slice('koderift_traceparent', 'koderift_trace_id')).to eq(keys)
    end
  ensure
    current.pop(frame)
  end

  it 'adds nothing when no trace is in flight' do
    enqueue(job)

    expect(job.keys.grep(/koderift/)).to be_empty
  end

  it 'writes only the legacy key for a trace ID that is not W3C hex' do
    Thread.current[:koderift_trace_id] = 'outer-trace'
    enqueue(job)

    expect(job['koderift_trace_id']).to eq('outer-trace')
    expect(job).not_to have_key('koderift_traceparent')
  ensure
    Thread.current[:koderift_trace_id] = nil
  end

  it 'still enqueues when it cannot touch the job' do
    frame = current.push(kind: :request, trace_id: trace_id)

    expect(enqueue(job.freeze)).to eq(:pushed)
  ensure
    current.pop(frame)
  end
end
