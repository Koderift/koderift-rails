require 'spec_helper'

RSpec.describe Koderift::Rails::LogrageConfig do
  describe '.format_backtrace' do
    it 'returns nil when exception is nil' do
      expect(described_class.format_backtrace(nil)).to be_nil
    end

    it 'returns nil when exception has no backtrace' do
      exc = StandardError.new('boom')
      # backtrace is nil until the exception is raised
      expect(described_class.format_backtrace(exc)).to be_nil
    end

    it 'returns a newline-joined string of frames' do
      exc = begin
        raise RuntimeError, 'test'
      rescue => e
        e
      end
      result = described_class.format_backtrace(exc)
      expect(result).to be_a(String)
      expect(result).to include('lograge_config_spec.rb')
    end

    it 'caps output at MAX_FRAMES lines' do
      exc = begin
        raise RuntimeError, 'test'
      rescue => e
        e
      end
      # Inject a very long fake backtrace
      exc.set_backtrace(Array.new(200) { |i| "fake/path/file_#{i}.rb:#{i}:in `method'" })
      result = described_class.format_backtrace(exc)
      expect(result.split("\n").size).to be <= Koderift::Rails::LogrageConfig::MAX_FRAMES
    end

    it 'prioritises app frames over gem frames in the tail' do
      exc = begin
        raise RuntimeError, 'test'
      rescue => e
        e
      end
      frames = Array.new(5) { |i| "gems/rack-#{i}.rb:1" } +
               Array.new(5) { |i| "/app/controllers/foo_#{i}.rb:1" } +
               Array.new(100) { |i| "gems/activesupport-#{i}.rb:1" }
      exc.set_backtrace(frames)
      result = described_class.format_backtrace(exc)
      lines = result.split("\n")
      # App frames should appear before the gem flood
      app_indices = lines.each_index.select { |i| lines[i].include?('/app/') }
      expect(app_indices).not_to be_empty
    end
  end

  describe '.apply' do
    it 'includes trace_id in custom_options output' do
      event = double('event', payload: {
        koderift_user_id:     nil,
        koderift_host:        'example.com',
        db_runtime:           10.5,
        exception:            nil,
        exception_object:     nil,
        koderift_request_id:  'req-123',
        koderift_trace_id:    'trace-abc-456',
        koderift_ip:          '1.2.3.4',
        koderift_user_agent:  'Mozilla/5.0',
        allocations:          1000,
        koderift_referer:     nil,
        koderift_breadcrumbs: nil,
        koderift_params:      {},
        koderift_slow_partials:  nil,
        koderift_query_stats:    nil,
        koderift_external_calls: nil
      })

      app = double('app', config: double(lograge: double(
        enabled: nil, keep_original_rails_log: nil,
        formatter: nil, custom_options: nil
      )))

      captured_options = nil
      allow(app.config.lograge).to receive(:custom_options=) { |v| captured_options = v }
      allow(app.config.lograge).to receive(:enabled=)
      allow(app.config.lograge).to receive(:keep_original_rails_log=)
      allow(app.config.lograge).to receive(:formatter=)

      stub_const('Lograge', Module.new)
      stub_const('Lograge::Formatters', Module.new)
      stub_const('Lograge::Formatters::Json', Class.new { def initialize; end })

      Koderift::Rails::LogrageConfig.apply(app)

      result = captured_options.call(event)
      expect(result[:trace_id]).to eq('trace-abc-456')
      expect(result[:request_id]).to eq('req-123')
    end
  end
end
