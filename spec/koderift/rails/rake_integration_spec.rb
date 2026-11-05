require 'spec_helper'
require 'koderift/rails/rake_integration'

RSpec.describe Koderift::Rails::RakeIntegration do
  include_context 'a captured log'

  let(:application_class) do
    Class.new do
      attr_reader :displayed

      def initialize
        @displayed = []
      end

      def display_error_message(exception)
        @displayed << exception
      end

      def top_level_tasks
        ['ringley_panel:sync_recent_contractors']
      end
    end
  end

  let(:application) { application_class.new }

  before do
    application_class.prepend(described_class)
    app  = application
    rake = Module.new
    rake.define_singleton_method(:application) { app }
    stub_const('Rake', rake)
  end

  # A rake task that raises writes its backtrace to STDERR, which under cron
  # goes to a mail spool or /dev/null — never to production.log. Before this
  # hook, Koderift never saw those failures at all.
  it 'captures an uncaught task failure under the task name' do
    application.display_error_message(raised(IOError, 'panel down'))

    expect(last_payload['exception']).to eq 'IOError: panel down'
    expect(last_payload['component']).to eq 'ringley_panel:sync_recent_contractors'
    expect(last_payload['action']).to    eq 'rake'
  end

  it 'leaves rake output untouched by still calling super' do
    error = raised

    application.display_error_message(error)

    expect(application.displayed).to eq [error]
  end

  # `exit` inside a task arrives here as a SystemExit. That is the task
  # finishing, not failing, and reporting it would file an error for every
  # well-behaved task that exits explicitly.
  it 'ignores SystemExit' do
    application.display_error_message(SystemExit.new(0))

    expect(capture_lines).to be_empty
    expect(application.displayed.size).to eq 1
  end

  it 'still shows rake its own error when capturing fails' do
    allow(Koderift).to receive(:capture_exception).and_raise(IOError, 'logger gone')
    error = raised

    expect { application.display_error_message(error) }.not_to raise_error
    expect(application.displayed).to eq [error]
  end

  it 'falls back to a generic name when no task name is available' do
    allow(application).to receive(:top_level_tasks).and_return([])

    application.display_error_message(raised)

    expect(last_payload['component']).to eq 'rake'
  end
end
