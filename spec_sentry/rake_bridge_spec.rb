# frozen_string_literal: true

require_relative 'sentry_helper'
require 'rake'
require 'koderift/rails/rake_integration'

# A failing task under a real Rake::Application, with both integrations on.
# sentry-ruby prepends Sentry::Rake::Application when it loads; the gem's
# Railtie prepends RakeIntegration later, inside :environment. That is the
# production order, so the gem's hook runs first.
RSpec.describe 'a rake run with sentry-ruby' do
  include_context 'a captured log'

  before(:all) do
    unless Rake::Application.include?(Koderift::Rails::RakeIntegration)
      Rake::Application.prepend(Koderift::Rails::RakeIntegration)
    end
  end

  let(:bridge) { Koderift::Rails::SentryBridge }

  let(:uuid_re) { /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/ }

  def koderift_captures
    capture_lines.map { |(_, line)| JSON.parse(line) }.select { |line| line['koderift_capture'] }
  end

  # Runs `tasks` in a fresh Rake::Application the way `rake` does: init from
  # the command line, then top_level inside standard_exception_handling.
  # Returns what Rake printed. $stderr is swapped for the whole run because
  # Rake binds its error output to it when it reads its options.
  def run_rake(tasks, define: {})
    output    = StringIO.new
    original  = $stderr
    $stderr   = output
    Rake.with_application(Rake::Application.new) do |app|
      app.init('rake', tasks)
      define.each { |name, body| app.define_task(Rake::Task, name, &body) }
      yield app if block_given?
      begin
        app.standard_exception_handling { app.top_level }
      rescue SystemExit
        nil
      end
    end
    output.string
  ensure
    $stderr = original
  end

  def failing_task
    { 'billing:close_month' => proc { raise ZeroDivisionError, 'divided by 0' } }
  end

  # Sentry initialised and the bridge installed, as the Railtie's
  # after_initialize leaves them once the app has booted inside :environment.
  def boot_with_sentry
    init_sentry
    bridge.install_if_ready
  end

  def failure_capture
    koderift_captures.find { |line| line['exception'] }
  end

  # The order this file sets up: sentry-ruby prepended at require, the gem's
  # module after it, as the Railtie does inside :environment. The acceptance
  # fixtures (spec/fixtures/sentry_bridge) are the evidence for a real app.
  it "runs the gem's hook before Sentry's when the gem prepends after sentry-ruby loads" do
    ancestors = Rake::Application.ancestors

    expect(ancestors.index(Koderift::Rails::RakeIntegration)).to be < ancestors.index(Sentry::Rake::Application)
  end

  # Test 5.
  it 'gives the capture line and Sentry\'s rake event the same run ID, and leaves Rake\'s output unchanged' do
    outputs = %i[off on].map do |mode|
      if mode == :on
        init_sentry
      else
        init_sentry(skip_rake_integration: true)
        Koderift::Rails.configuration.project_token = nil
      end
      log_lines.clear
      sentry_events.clear if Sentry.initialized?
      output = run_rake(['billing:close_month'], define: failing_task)
      next output if mode == :off

      captures = koderift_captures
      events   = sentry_events

      expect(captures.size).to eq(1)
      expect(events.size).to eq(1)
      run_id = captures.first['request_id']
      expect(run_id).to match(uuid_re)
      expect(captures.first['component']).to eq('billing:close_month')
      expect(captures.first['exception']).to eq('ZeroDivisionError: divided by 0')
      expect(events.first.tags['request_id']).to eq(run_id)
      expect(events.first.tags['rake_task']).to eq('billing:close_month')
      expect(events.first.tags).not_to have_key('koderift_trace_id')
      output
    ensure
      Koderift::Rails.configuration.project_token = 'test-token'
      Sentry.close if Sentry.initialized?
      Sentry::Scope.global_event_processors.clear
      bridge.reset_for_tests!
    end

    expect(outputs.first).to include('rake aborted!', 'divided by 0')
    expect(outputs.last).to eq(outputs.first)
  end

  # Test 6. The run ID is per process: both invocations, and both reports of
  # each, carry the same one.
  it 'keeps the same run ID for two invocations of a task in one process' do
    boot_with_sentry
    original = $stderr
    $stderr  = StringIO.new
    Rake.with_application(Rake::Application.new) do |app|
      app.init('rake', ['billing:close_month'])
      task = app.define_task(Rake::Task, 'billing:close_month') { raise ZeroDivisionError, 'divided by 0' }
      2.times do
        task.reenable
        begin
          app.standard_exception_handling { task.invoke }
        rescue SystemExit
          nil
        end
      end
    end
    $stderr = original

    ids = koderift_captures.map { |line| line['request_id'] } + sentry_events.map { |e| e.tags['request_id'] }
    expect(ids.size).to eq(4)
    expect(ids.uniq.size).to eq(1)
    expect(ids.first).to match(uuid_re)
  end

  it 'gives every capture outside a unit in the run the same ID, and keeps a transaction its own' do
    boot_with_sentry
    transaction_id = nil
    run_rake(['billing:close_month'], define: {
               'billing:close_month' => proc do
                 Koderift.capture_message('starting', level: :warn)
                 Koderift.start_transaction(name: 'Billing#close') do |txn|
                   transaction_id = txn.request_id
                   Koderift.capture_message('inside', level: :warn)
                 end
                 raise ZeroDivisionError, 'divided by 0'
               end
             })

    by_message = koderift_captures.to_h { |line| [line['message'], line['request_id']] }
    run_id     = failure_capture['request_id']

    expect(run_id).to match(uuid_re)
    expect(by_message['starting']).to eq(run_id)
    expect(by_message['inside']).to eq(transaction_id)
    expect(transaction_id).not_to eq(run_id)
    expect(sentry_events.last.tags['request_id']).to eq(run_id)
  end

  # An abandoned non-block transaction is still open when the failure is
  # reported: both reports carry its request ID instead, so they still pair.
  it "uses an open transaction's request ID for both reports" do
    boot_with_sentry
    transaction = nil
    run_rake(['billing:close_month'], define: {
               'billing:close_month' => proc do
                 transaction = Koderift.start_transaction(name: 'Billing#close')
                 raise ZeroDivisionError, 'divided by 0'
               end
             })
    transaction.finish

    expect(failure_capture['request_id']).to eq(transaction.request_id)
    expect(sentry_events.last.tags['request_id']).to eq(transaction.request_id)
  end

  # The run ID only goes on an event with no key of its own. A jid that no
  # finished job on this thread names (a stale tag on Sentry's scope) keeps
  # the event as it is.
  it 'gives no run ID to an event that already has a key of its own' do
    boot_with_sentry
    Rake.with_application(Rake::Application.new) do |app|
      app.init('rake', ['billing:close_month'])
      Sentry.with_scope do |scope|
        scope.set_tags(jid: 'jid-nothing-recorded')
        Sentry.capture_message('a stale jid on the scope')
      end
      Sentry.capture_message('no key')
    end

    keyed, keyless = sentry_events.last(2)
    expect(keyed.tags).to eq(jid: 'jid-nothing-recorded')
    expect(keyless.tags['request_id']).to match(uuid_re)
  end

  describe 'a long-running worker task' do
    def worker_run(tasks)
      boot_with_sentry
      worker = tasks.last.sub(/\[.*\z/, '')
      run_rake(tasks, define: { 'environment' => proc {}, worker => proc { raise IOError, 'worker died' } })
    end

    it 'gets no run ID when any top-level task is a worker, arguments ignored' do
      worker_run(['environment', 'resque:work[1]'])

      expect(failure_capture['exception']).to eq('IOError: worker died')
      expect(koderift_captures.last).not_to have_key('request_id')
      expect(sentry_events.last.tags).not_to have_key('request_id')
    end

    it 'honours a task the app adds to config.rake_worker_tasks' do
      Koderift::Rails.configuration.rake_worker_tasks += ['mailroom:poll']
      worker_run(['mailroom:poll'])

      expect(koderift_captures.last).not_to have_key('request_id')
      expect(sentry_events.last.tags).not_to have_key('request_id')
    end
  end

  # Test 9's rake half.
  it 'gives no run ID with config.sentry_bridge = false' do
    Koderift::Rails.configuration.sentry_bridge = false
    boot_with_sentry
    run_rake(['billing:close_month'], define: failing_task)

    expect(koderift_captures.last).not_to have_key('request_id')
    expect(sentry_events.last.tags).not_to have_key('request_id')
    expect(Sentry::Scope.global_event_processors).to be_empty
  end

  it 'installs at the rake failure when Sentry was initialised after boot' do
    run_rake(['billing:close_month'], define: failing_task) { init_sentry }

    expect(bridge.installed?).to be true
    expect(koderift_captures.last['request_id']).to match(uuid_re)
    expect(sentry_events.last.tags['request_id']).to eq(koderift_captures.last['request_id'])
  end
end
