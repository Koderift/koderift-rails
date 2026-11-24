require 'spec_helper'
require 'open3'
require 'rbconfig'
require 'tmpdir'
require 'rails'
require 'action_controller'
require 'rails/railtie'
require 'koderift/rails/railtie'
require 'koderift/rails/rake_integration'

# Apps without sentry-ruby must see no change at all. spec_sentry/ covers the
# bridge itself, in its own process.
RSpec.describe 'koderift-rails without sentry-ruby' do
  let(:bridge) { Koderift::Rails::SentryBridge }

  before(:all) { Koderift::Rails::Railtie.include_controller_concern }

  before do
    Koderift::Rails.configure do |config|
      config.project_token = 'test-token'
      config.enabled       = true
    end
  end

  # A real boot, so the new initializer and its after_initialize hook run.
  it 'boots a Rails app without defining ::Sentry or installing anything' do
    script = <<~RUBY
      require 'logger'
      require 'tmpdir'
      require 'rails'
      require 'action_controller/railtie'
      require 'koderift-rails'

      class BridgeProbeApp < Rails::Application
        config.root            = Dir.mktmpdir
        config.eager_load      = false
        config.logger          = Logger.new(nil)
        config.secret_key_base = 'x' * 64
      end
      Koderift::Rails.configure { |c| c.project_token = 'probe-token' }
      BridgeProbeApp.initialize!

      names = Rails.application.initializers.map(&:name)
      puts [defined?(::Sentry).inspect, Koderift::Rails::SentryBridge.installed?,
            names.include?('koderift.sentry_bridge')].join(',')
    RUBY

    output, status = Open3.capture2e(RbConfig.ruby, '-I', File.expand_path('../../../lib', __dir__), '-e', script)

    expect(status).to be_success, output
    expect(output.lines.last.strip).to eq('nil,false,true')
  end

  it 'never installs, and the processor hands any event back untouched' do
    event = Struct.new(:tags).new({ 'app' => '1' })

    expect(bridge.install_if_ready).to be false
    expect(bridge::PROCESSOR.call(event, nil)).to equal(event)
    expect(event.tags).to eq('app' => '1')
    expect(bridge.rake_run_id).to be_nil
  end

  # The migration guide's `Sentry = Koderift` shim answers initialized? but
  # has no add_global_event_processor.
  it 'stays off under a Sentry = Koderift shim' do
    stub_const('Sentry', Koderift)

    expect(bridge.install_if_ready).to be false
    expect(bridge.installed?).to be false
  end

  # An app's own autoloadable Sentry constant (app/models/sentry.rb under
  # Zeitwerk) is not sentry-ruby, and the bridge must not load it.
  it 'leaves an autoloadable Sentry constant unloaded' do
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'sentry.rb')
      File.write(path, "$koderift_spec_sentry_loaded = true\nmodule Sentry; end\n")
      Object.autoload(:Sentry, path)
      begin
        expect(bridge.install_if_ready).to be false
        expect($koderift_spec_sentry_loaded).to be_nil
        expect(Object.autoload?(:Sentry)).to eq(path)
      ensure
        Object.send(:remove_const, :Sentry) if Object.const_defined?(:Sentry, false)
      end
    end
  end

  describe 'a failing request' do
    let(:controller) do
      Class.new(ActionController::Base) do
        define_singleton_method(:name) { 'PlainWidgetsController' }

        def boom
          raise ArgumentError, 'boom'
        end
      end
    end

    def env
      Rack::MockRequest.env_for('/widgets').merge('action_dispatch.request_id' => 'req-123')
    end

    it 'raises from the gem no more often than before, and leaves nothing of the bridge on the thread' do
      allow(::Rails).to receive(:logger).and_return(Logger.new(nil))
      gem_raises = []
      trace = TracePoint.new(:raise) { |tp| gem_raises << tp.path if tp.path.include?('/lib/koderift/') }

      error = nil
      trace.enable do
        controller.action(:boom).call(env)
      rescue ArgumentError => e
        error = e
      end

      expect(error.message).to eq('boom')
      expect(error.instance_variables.grep(/koderift/)).to be_empty
      expect(gem_raises).to be_empty
      bridge_keys = %i[koderift_closed_jid koderift_closed_trace_id koderift_closed_span_id koderift_closed_hub_id]
      expect(bridge_keys.map { |key| Thread.current[key] }).to all(be_nil)
    end
  end

  describe 'a rake failure' do
    include_context 'a captured log'

    it 'gets no request_id, as in 2.2.0' do
      app = Object.new
      app.define_singleton_method(:top_level_tasks) { ['billing:close_month'] }
      app.define_singleton_method(:display_error_message) { |_e| nil }
      app.singleton_class.prepend(Koderift::Rails::RakeIntegration)
      rake = Module.new
      rake.define_singleton_method(:application) { app }
      stub_const('Rake', rake)

      app.display_error_message(raised(ZeroDivisionError, 'divided by 0'))

      expect(last_payload['component']).to eq('billing:close_month')
      expect(last_payload).not_to have_key('request_id')
    end
  end
end
