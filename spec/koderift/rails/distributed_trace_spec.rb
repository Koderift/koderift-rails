require 'spec_helper'
require 'logger'
require 'rails'
require 'action_controller'
require 'active_job'
require 'sidekiq'
ENV['RACK_ENV'] ||= 'test' # keeps sidekiq/testing from warning that this is not a test run
require 'sidekiq/testing'
require 'koderift/rails/railtie'
require 'koderift/rails/sidekiq_middleware'
require 'koderift/rails/sidekiq_client_middleware'

class KoderiftTraceProbeJob
  include Sidekiq::Job

  def perform(*)
    ActiveSupport::Notifications.instrument('sql.active_record', sql: 'SELECT in_job', name: 'Load') {}
  end
end

class KoderiftTraceProbeActiveJob < ActiveJob::Base
  self.queue_adapter = :sidekiq

  def perform; end
end

# A request and the jobs it enqueues share one trace, through the real
# Sidekiq client and server middleware chains (Sidekiq::Testing fake mode).
RSpec.describe 'trace context from a request into its jobs' do
  before(:all) do
    Sidekiq::Testing.fake!
    Sidekiq.logger.level = Logger::WARN
    ActiveJob::Base.logger = Logger.new(nil)
    Koderift::Rails::Railtie.include_controller_concern
    Koderift::Rails::Railtie.register_sidekiq_middleware
    Sidekiq::Testing.server_middleware { |chain| chain.add Koderift::Rails::SidekiqMiddleware }
  end

  after(:all) do
    Sidekiq::Testing.server_middleware { |chain| chain.remove Koderift::Rails::SidekiqMiddleware }
  end

  let(:job_lines) { [] }
  let(:current)   { Koderift::Rails::TraceContext::Current }

  before do
    Koderift::Rails.configure do |config|
      config.project_token = 'test-token'
      config.enabled       = true
    end

    lines  = job_lines
    logger = Object.new
    %i[info warn error fatal debug].each do |severity|
      logger.define_singleton_method(severity) { |message = nil| lines << message.to_s if severity == :info; true }
    end
    allow(::Rails).to receive(:logger).and_return(logger)
    Sidekiq::Job.clear_all
  end

  after { Sidekiq::Job.clear_all }

  let(:controller) do
    Class.new(ActionController::Base) do
      define_singleton_method(:name) { 'EnqueuingController' }

      def create
        Koderift.with_child_span(op: 'enqueue') { KoderiftTraceProbeJob.perform_async(1) }
        KoderiftTraceProbeActiveJob.perform_later
        render json: { ok: true }
      end
    end
  end

  def dispatch
    payloads   = []
    subscriber = ActiveSupport::Notifications.subscribe('process_action.action_controller') do |*args|
      payloads << args.last
    end
    env = Rack::MockRequest.env_for('/things', method: 'POST')
    env['action_dispatch.request_id'] = 'req-1'
    status, = controller.action(:create).call(env)
    expect(status).to eq(200)
    payloads.last
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  def parsed_job_lines
    job_lines.select { |l| l.start_with?('{') }.map { |l| JSON.parse(l) }
  end

  it 'gives the job line the request trace, with the enqueuing span as parent' do
    request      = dispatch
    request_ids  = [request[:koderift_span_id]] + request[:koderift_spans].map { |s| s[:span_id] }
    enqueue_span = request[:koderift_spans].find { |s| s[:name] == 'enqueue' }

    stored = KoderiftTraceProbeJob.jobs.last
    expect(stored['koderift_traceparent']).to eq("00-#{request[:koderift_trace_id]}-#{enqueue_span[:span_id]}-01")
    expect(stored['koderift_trace_id']).to eq(request[:koderift_trace_id])

    Sidekiq::Job.drain_all
    job = parsed_job_lines.find { |l| l['job_class'] == 'KoderiftTraceProbeJob' }

    expect(job['trace_id']).to match(/\A[0-9a-f]{32}\z/)
    expect(job['trace_id']).to eq(request[:koderift_trace_id])
    expect(request_ids).to include(job['parent_span_id'])
    expect(job['parent_span_id']).to eq(enqueue_span[:span_id])
    expect(job['span_id']).to match(/\A[0-9a-f]{16}\z/)
    expect(job['started_at']).to match(/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z\z/)
    expect(job['spans'].map { |s| s['name'] }).to eq(['SELECT in_job'])
  end

  it 'carries the trace through an ActiveJob on the Sidekiq adapter' do
    request = dispatch

    Sidekiq::Job.drain_all
    job = parsed_job_lines.find { |l| l['job_class'] == 'KoderiftTraceProbeActiveJob' }

    expect(job['trace_id']).to eq(request[:koderift_trace_id])
    expect(job['parent_span_id']).to eq(request[:koderift_span_id])
  end

  # The poller re-pushes retries and scheduled jobs with Sidekiq::Client.push.
  # Whatever trace is on that thread, the job keeps the one it was enqueued with.
  it 'never replaces the trace a job already carries' do
    original = { 'class' => 'KoderiftTraceProbeJob', 'args' => [1], 'jid' => 'abc',
                 'koderift_traceparent' => '00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01',
                 'koderift_trace_id' => '4bf92f3577b34da6a3ce929d0e0e4736' }
    frame = current.push(kind: :request, trace_id: 'cccccccccccccccccccccccccccccccc')
    Sidekiq::Client.push(original)
    current.pop(frame)

    stored = KoderiftTraceProbeJob.jobs.last
    expect(stored['koderift_traceparent']).to eq(original['koderift_traceparent'])
    expect(stored['koderift_trace_id']).to eq(original['koderift_trace_id'])
  end

  it 'still links a job that only has the legacy trace ID key' do
    Sidekiq::Client.push('class' => 'KoderiftTraceProbeJob', 'args' => [1],
                         'koderift_trace_id' => '4bf92f35-77b3-4da6-a3ce-929d0e0e4736')
    Sidekiq::Job.drain_all
    job = parsed_job_lines.last

    expect(job['trace_id']).to eq('4bf92f3577b34da6a3ce929d0e0e4736')
    expect(job).not_to have_key('parent_span_id')
  end

  it 'adds nothing to a job enqueued outside any trace' do
    KoderiftTraceProbeJob.perform_async(1)

    expect(KoderiftTraceProbeJob.jobs.last.keys.grep(/koderift/)).to be_empty
  end
end
