require 'active_support'
require 'active_support/core_ext/object/blank'
require 'koderift/rails'
require 'json'

RSpec.configure do |config|
  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end

  config.shared_context_metadata_behavior = :apply_to_host_groups

  config.before(:each) do
    Koderift::Rails.reset!
  end
end

# Stands in for Rails.logger and collects everything the gem writes, so a spec
# can assert on the exact JSON line the log agent would go on to parse.
RSpec.shared_context 'a captured log' do
  let(:log_lines) { [] }

  let(:logger) do
    lines = log_lines
    Object.new.tap do |fake|
      %i[error warn info fatal].each do |severity|
        fake.define_singleton_method(severity) { |message| lines << [severity, message]; true }
      end
    end
  end

  before do
    captured_logger = logger
    fake_rails      = Module.new
    fake_rails.define_singleton_method(:logger) { captured_logger }
    stub_const('Rails', fake_rails)

    Koderift::Rails.configure do |config|
      config.project_token = 'test-token'
      config.enabled       = true
    end
  end

  # Only the JSON capture lines; warnings and other logger output are excluded.
  def capture_lines
    log_lines.select { |(_, message)| message.to_s.start_with?('{') }
  end

  def last_payload
    JSON.parse(capture_lines.last[1])
  end

  def last_severity
    capture_lines.last[0]
  end

  def warnings
    log_lines.select { |(severity, _)| severity == :warn }.map(&:last)
  end

  def raised(klass = ArgumentError, message = 'bad token')
    raise klass, message
  rescue StandardError => e
    e
  end
end
