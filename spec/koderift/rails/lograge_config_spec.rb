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
    let(:spans) { [{ type: 'sql', name: 'SELECT 1', duration_ms: 5, sequence: 0 }] }

    let(:event) do
      double('event', payload: {
        koderift_user_id:      nil,
        koderift_host:         'example.com',
        db_runtime:            10.5,
        exception:             nil,
        exception_object:      nil,
        koderift_request_id:   'req-123',
        koderift_trace_id:     'trace-abc-456',
        koderift_ip:           '1.2.3.4',
        koderift_user_agent:   'Mozilla/5.0',
        allocations:           1000,
        koderift_referer:      nil,
        koderift_breadcrumbs:  nil,
        koderift_params:       {},
        koderift_spans:        spans,
        koderift_query_count:  1,
        koderift_partial_count: 0,
        koderift_search_count: 0
      })
    end

    def apply_and_call(event)
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
      captured_options.call(event)
    end

    it 'includes trace_id and request_id in custom_options output' do
      result = apply_and_call(event)
      expect(result[:trace_id]).to eq('trace-abc-456')
      expect(result[:request_id]).to eq('req-123')
    end

    it 'emits spans and scalar counts' do
      result = apply_and_call(event)
      expect(result[:spans]).to eq(spans)
      expect(result[:query_count]).to eq(1)
      expect(result[:partial_count]).to eq(0)
      expect(result[:search_count]).to eq(0)
    end

    it 'does not emit the legacy blob keys' do
      result = apply_and_call(event)
      expect(result).not_to have_key(:slow_partials)
      expect(result).not_to have_key(:query_stats)
      expect(result).not_to have_key(:search_stats)
      expect(result).not_to have_key(:external_calls)
    end
  end

  describe '.release_hijacked_logger' do
    include_context 'a captured log'

    let(:options)    { Lograge::OrderedOptions.new }
    let(:app)        { double('app', config: double('config', lograge: options)) }
    let(:gem_logger) { ::Logger.new(StringIO.new) }
    let(:app_logger) { ::Logger.new(StringIO.new) }

    # Saves the module state Lograge.set_lograge_log_options writes, and the
    # fallback logger lograge's subscribers use when Lograge.logger is nil.
    around do |example|
      lograge_state    = %i[@@logger @@application @@custom_options @@before_format @@log_level]
      saved_lograge    = lograge_state.to_h { |name| [name, Lograge.class_variable_get(name)] }
      saved_subscriber = ActiveSupport::LogSubscriber.instance_variable_get(:@logger)
      ActiveSupport::LogSubscriber.logger = nil
      begin
        example.run
      ensure
        saved_lograge.each { |name, value| Lograge.class_variable_set(name, value) }
        ActiveSupport::LogSubscriber.logger = saved_subscriber
      end
    end

    # The step in Lograge.setup that copies config.lograge.logger into
    # Lograge.logger. The rest of setup attaches subscribers process-wide, so
    # only this step runs here.
    def run_lograge_copy_step
      Lograge.application = app
      Lograge.set_lograge_log_options
    end

    # Where lograge will write the JSON request line.
    def lograge_destination
      Lograge::LogSubscribers::ActionController.new.logger
    end

    context 'when a gem has given every object a public logger' do
      # Stands in for data-anonymization 0.9.1, whose top-level
      # `include DataAnon::Core::DSL` puts a STDOUT logger on every object.
      let(:hijacker) do
        hijacked = gem_logger
        Module.new { define_method(:logger) { hijacked } }
      end

      before do
        stub_const('HijackingLoggerGem', hijacker)
        Object.include(hijacker)
      end

      # A module cannot be un-included, but once its method is gone it is inert,
      # so no other example sees Object#logger.
      after { hijacker.send(:remove_method, :logger) }

      it 'reproduces the hijack: lograge copies the gem logger although the app set none' do
        expect(options.key?(:logger)).to be(false)
        expect(options.logger).to be(gem_logger)

        run_lograge_copy_step

        expect(Lograge.logger).to be(gem_logger)
        expect(lograge_destination).to be(gem_logger)
      end

      it 'points lograge back at Rails.logger' do
        run_lograge_copy_step
        described_class.release_hijacked_logger(app)

        expect(Lograge.logger).to be_nil
        expect(lograge_destination).to be(logger)
      end

      it 'warns once, naming the method owner and the loggers it probably redirected too' do
        run_lograge_copy_step
        2.times { described_class.release_hijacked_logger(app) }

        expect(warnings.size).to eq(1)
        expect(warnings.first).to include(
          'HijackingLoggerGem (',
          File.basename(__FILE__),
          'pointed lograge back at Rails.logger',
          'ActionController::Base.logger',
          'ActiveRecord::Base.logger',
          "Rails' own request lines"
        )
      end

      context 'and the app set config.lograge.logger itself' do
        before { options.logger = app_logger }

        it 'restores the configured logger, which the gem method had shadowed' do
          expect(options.key?(:logger)).to be(true)
          run_lograge_copy_step
          expect(Lograge.logger).to be(gem_logger)

          described_class.release_hijacked_logger(app)

          expect(Lograge.logger).to be(app_logger)
          expect(lograge_destination).to be(app_logger)
          expect(warnings.first).to include('pointed lograge back at the logger set in config.lograge.logger')
        end
      end
    end

    context 'when no gem shadows logger' do
      it 'leaves a configured config.lograge.logger alone' do
        options.logger = app_logger
        run_lograge_copy_step

        described_class.release_hijacked_logger(app)

        expect(Lograge.logger).to be(app_logger)
        expect(warnings).to be_empty
      end

      it 'leaves an unset logger nil and stays quiet' do
        run_lograge_copy_step

        described_class.release_hijacked_logger(app)

        expect(Lograge.logger).to be_nil
        expect(lograge_destination).to be(logger)
        expect(warnings).to be_empty
      end

      it 'leaves a Lograge.logger the app assigned directly alone' do
        run_lograge_copy_step
        Lograge.logger = app_logger

        described_class.release_hijacked_logger(app)

        expect(Lograge.logger).to be(app_logger)
        expect(warnings).to be_empty
      end
    end
  end
end
