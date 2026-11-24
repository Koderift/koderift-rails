# frozen_string_literal: true

require_relative 'sentry_helper'
require 'net/http'
require 'sidekiq'
ENV['RACK_ENV'] ||= 'test' # keeps sidekiq/testing from warning that this is not a test run
require 'sidekiq/testing'
require 'koderift/rails/sidekiq_client_middleware'

class BridgeSmokeJob
  include Sidekiq::Job

  def perform(*); end
end

# Test 11: with sentry-ruby live, an outbound Net::HTTP call and a Sidekiq
# enqueue inside a request carry exactly what they carry with the bridge off,
# and what 2.2.0's own specs expect.
RSpec.describe 'outbound calls and enqueues with sentry-ruby live' do
  before(:all) do
    Sidekiq::Testing.fake!
    Sidekiq.logger.level = Logger::WARN
    Koderift::Rails::Railtie.include_controller_concern
    Koderift::Rails::Railtie.register_sidekiq_middleware
  end

  after { Sidekiq::Job.clear_all }

  let!(:gem_lines) { collect_gem_lines }

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
      define_singleton_method(:name) { 'SmokeController' }
      define_method(:outbound) { outbound }

      def call_out
        outbound.request(Net::HTTP::Get.new('/v1/things'))
        BridgeSmokeJob.perform_async(1)
        render json: { ok: true }
      end
    end
  end

  # What the request sent and enqueued, with IDs replaced by their role, so
  # two runs can be compared.
  def observed(bridge_on)
    configure_koderift(sentry_bridge: bridge_on)
    init_sentry
    Sidekiq::Job.clear_all
    payload   = collect_request_payloads { controller.action(:call_out).call(rack_env('req-1')) }.last
    sent      = http.last_request
    job       = BridgeSmokeJob.jobs.last
    trace     = payload[:koderift_trace_id]
    http_span = payload[:koderift_spans].find { |s| s[:type] == 'http' }[:span_id]

    expect(sent['traceparent']).to eq("00-#{trace}-#{http_span}-01")
    expect(sent['X-Koderift-Traceparent']).to eq(sent['traceparent'])
    expect(sent['X-Koderift-Trace-ID']).to eq(trace)
    expect(job['koderift_trace_id']).to eq(trace)
    expect(job['koderift_traceparent']).to eq("00-#{trace}-#{payload[:koderift_span_id]}-01")

    roles = { trace => 'TRACE', http_span => 'HTTP_SPAN', payload[:koderift_span_id] => 'ROOT_SPAN' }
    {
      headers: sent.to_hash.transform_values { |v| v.map { |s| roles.reduce(s) { |acc, (id, role)| acc.gsub(id, role) } } },
      job:     job.select { |k, _| k.start_with?('koderift') }
                  .transform_values { |v| roles.reduce(v) { |acc, (id, role)| acc.gsub(id, role) } }
    }
  ensure
    Sentry.close if Sentry.initialized?
    Sentry::Scope.global_event_processors.clear
    Koderift::Rails::SentryBridge.reset_for_tests!
  end

  it 'sends the same headers and job keys with the bridge on as with it off' do
    on  = observed(true)
    off = observed(false)

    expect(on).to eq(off)
    expect(on[:job].keys).to contain_exactly('koderift_trace_id', 'koderift_traceparent')
  end
end
