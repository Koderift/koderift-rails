require 'spec_helper'
require 'json'
require 'koderift/rails/sidekiq_middleware'

RSpec.describe Koderift::Rails::SidekiqMiddleware do
  let(:middleware) { described_class.new }
  let(:worker)     { double('worker') }
  let(:job)        { { 'class' => 'GetStaffWorker', 'jid' => 'abc123' } }
  let(:queue)      { 'default' }
  let(:log_lines)  { [] }
  let(:logger)     { double('logger') }

  before do
    Koderift::Rails.configure do |c|
      c.project_token = 'test-token'
      c.enabled       = true
    end

    captured_logger = logger
    fake_rails = Module.new
    fake_rails.define_singleton_method(:logger) { captured_logger }
    stub_const('Rails', fake_rails)
    allow(logger).to receive(:info) { |msg| log_lines << msg }
    allow(logger).to receive(:warn)
  end

  describe '#call' do
    it 'yields the job' do
      yielded = false
      middleware.call(worker, job, queue) { yielded = true }
      expect(yielded).to be true
    end

    it 'writes a JSON line to Rails.logger with job metadata' do
      middleware.call(worker, job, queue) { nil }

      expect(log_lines.size).to eq 1
      parsed = JSON.parse(log_lines.last)
      expect(parsed['job_class']).to eq 'GetStaffWorker'
      expect(parsed['jid']).to       eq 'abc123'
      expect(parsed['queue']).to     eq 'default'
      expect(parsed['status']).to    eq 200
      expect(parsed['level']).to     eq 'info'
      expect(parsed['duration']).to  be_a(Integer)
      expect(parsed['trace_id']).to  be_a(String)
    end

    it 'includes spans array in the payload' do
      middleware.call(worker, job, queue) { nil }
      parsed = JSON.parse(log_lines.last)
      expect(parsed['spans']).to        be_an Array
      expect(parsed['query_count']).to  eq 0
      expect(parsed['search_count']).to eq 0
      expect(parsed['breadcrumbs']).to  be_an Array
    end

    it 'sets status 500 and includes exception on error' do
      expect {
        middleware.call(worker, job, queue) { raise RuntimeError, 'boom' }
      }.to raise_error(RuntimeError, 'boom')

      parsed = JSON.parse(log_lines.last)
      expect(parsed['status']).to    eq 500
      expect(parsed['level']).to     eq 'error'
      expect(parsed['exception']).to include 'boom'
      expect(parsed['exception']).to include 'RuntimeError'
    end

    it 'marks level slow when duration exceeds threshold' do
      Koderift::Rails.configure { |c| c.slow_job_threshold_ms = 50 }

      middleware.call(worker, job, queue) { sleep(0.1) }

      parsed = JSON.parse(log_lines.last)
      expect(parsed['level']).to eq 'slow'
    end

    it 'clears trace_id thread-local after success' do
      middleware.call(worker, job, queue) { nil }
      expect(Thread.current[:koderift_trace_id]).to be_nil
    end

    it 'clears trace_id thread-local even when job raises' do
      begin
        middleware.call(worker, job, queue) { raise 'oops' }
      rescue RuntimeError
        nil
      end
      expect(Thread.current[:koderift_trace_id]).to be_nil
    end

    it 'is a no-op when disabled' do
      Koderift::Rails.configure { |c| c.enabled = false }
      result = middleware.call(worker, job, queue) { :ran }
      expect(result).to    eq :ran
      expect(log_lines).to be_empty
    end

    it 'is a no-op when project_token is blank' do
      Koderift::Rails.configure { |c| c.project_token = nil }
      middleware.call(worker, job, queue) { nil }
      expect(log_lines).to be_empty
    end

    it 'inherits trace_id from job payload when present' do
      job['koderift_trace_id'] = 'upstream-trace-abc'
      middleware.call(worker, job, queue) { nil }
      parsed = JSON.parse(log_lines.last)
      expect(parsed['trace_id']).to eq 'upstream-trace-abc'
    end

    it 'generates a trace_id when job payload has none' do
      middleware.call(worker, job, queue) { nil }
      parsed = JSON.parse(log_lines.last)
      expect(parsed['trace_id']).to match(/\A[0-9a-f-]{36}\z/)
    end

    it 'sets trace_id thread-local during job execution' do
      seen_inside = nil
      middleware.call(worker, job, queue) { seen_inside = Thread.current[:koderift_trace_id] }
      expect(seen_inside).to be_a(String)
      expect(seen_inside).not_to be_empty
    end
  end
end
