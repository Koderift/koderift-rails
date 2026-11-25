require 'spec_helper'
require 'json'

# The real envelopes and log lines from a Rails 8.1 app running this gem with
# sentry-ruby, sentry-rails and sentry-sidekiq 7.3.0 (spec/fixtures/sentry_bridge).
# Plain JSON: no sentry-ruby is loaded. This is the contract Koderift pairs on.
RSpec.describe 'sentry-ruby bridge fixtures' do
  dir = File.expand_path('../../fixtures/sentry_bridge', __dir__)

  define_method(:event) do |name|
    JSON.parse(File.read(File.join(dir, "#{name}.envelope")).split("\n", 3).last)
  end

  # The JSON lines in a Rails log, prefix removed. Other lines (Rails' own
  # "Parameters: {...}") are skipped.
  define_method(:log_json) do |name|
    File.readlines(File.join(dir, "#{name}.log")).filter_map do |line|
      start = line.index('{"')
      next unless start

      begin
        JSON.parse(line[start..])
      rescue JSON::ParserError
        nil
      end
    end
  end

  def raised_class(event)
    event['exception']['values'].last['type']
  end

  it 'pairs the request error by request_id and links it to the request line\'s trace' do
    sdk  = event('request')
    line = log_json('request').find { |l| l['controller'] }

    expect(sdk['tags']['request_id']).to eq(line['request_id'])
    expect(sdk['tags']['koderift_trace_id']).to eq(line['trace_id'])
    expect(sdk['tags']['koderift_span_id']).to eq(line['span_id'])
    expect(line['exception']).to start_with("#{raised_class(sdk)}: ")
    expect(sdk['contexts']['trace']['trace_id']).not_to eq(line['trace_id'])
  end

  it 'pairs the job failure by jid and links it to the job line\'s trace' do
    sdk  = event('job')
    line = log_json('job').find { |l| l['job_class'] }

    expect(sdk['tags']['jid']).to eq(line['jid'])
    expect(sdk['tags']['request_id']).to eq(line['jid'])
    expect(sdk['tags']['koderift_trace_id']).to eq(line['trace_id'])
    expect(sdk['tags']['koderift_span_id']).to eq(line['span_id'])
    expect(line['status']).to eq(500)
    expect(line['exception']).to start_with("#{raised_class(sdk)}: ")
  end

  %w[rake_bin_rails rake_cli].each do |name|
    it "pairs the rake failure (#{name}) by the run ID" do
      sdk      = event(name)
      captures = log_json(name).select { |l| l['koderift_capture'] }

      expect(captures.size).to eq(1)
      expect(captures.first['request_id']).to match(/\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/)
      expect(sdk['tags']['request_id']).to eq(captures.first['request_id'])
      expect(sdk['tags']['rake_task']).to eq(captures.first['component'])
      expect(captures.first['exception']).to start_with("#{raised_class(sdk)}: ")
      expect(sdk['tags']).not_to have_key('koderift_trace_id')
    end
  end

  # 2.3.1: a rescue_from handler that reports both ways. Sentry's event is the
  # handler's own Sentry.capture_exception; the gem's capture line now carries
  # the request.
  it 'pairs a rescue_from handler\'s report by request_id, with the request line\'s trace' do
    sdk     = event('rescue_from')
    lines   = log_json('rescue_from')
    capture = lines.find { |l| l['koderift_capture'] }
    line    = lines.find { |l| l['controller'] }

    expect(lines.count { |l| l['koderift_capture'] }).to eq(1)
    expect(capture['request_id']).to eq(line['request_id'])
    expect(sdk['tags']['request_id']).to eq(capture['request_id'])
    expect(capture.values_at('trace_id', 'span_id')).to eq(line.values_at('trace_id', 'span_id'))
    expect(sdk['tags'].values_at('koderift_trace_id', 'koderift_span_id')).to eq(line.values_at('trace_id', 'span_id'))
    expect(capture).to include('component' => line['controller'], 'action' => line['action'],
                               'path' => line['path'], 'http_method' => line['method'])
    expect(capture['exception']).to start_with("#{raised_class(sdk)}: ")
    expect(line['status']).to eq(500)
    expect(line).not_to have_key('exception')
  end

  it 'pairs a CSRF failure handled before the hook by request_id, with no trace on either side' do
    sdk     = event('rescue_from_csrf')
    lines   = log_json('rescue_from_csrf')
    capture = lines.find { |l| l['koderift_capture'] }
    line    = lines.find { |l| l['controller'] }

    expect(sdk['tags']['request_id']).to eq(capture['request_id'])
    expect(capture['request_id']).to eq(line['request_id'])
    expect(capture['exception']).to start_with("#{raised_class(sdk)}: ")
    expect(raised_class(sdk)).to eq('ActionController::InvalidAuthenticityToken')
    expect(capture).not_to include('trace_id', 'span_id')
    expect(line).not_to include('trace_id', 'span_id')
    expect(sdk['tags']).not_to have_key('koderift_trace_id')
  end

  it 'gives the two rake runs different run IDs' do
    ids = %w[rake_bin_rails rake_cli].map { |name| event(name)['tags']['request_id'] }

    expect(ids.uniq.size).to eq(2)
  end
end
