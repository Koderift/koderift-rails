require 'spec_helper'
require 'bigdecimal'
require 'json'
require 'active_support/core_ext/object/json'
require 'action_view'
require 'koderift/rails/rum_helper'

RSpec.describe Koderift::Rails::RumHelper do
  include ActionView::Helpers::TagHelper
  include ActionView::Context
  include described_class

  before do
    Koderift::Rails.reset!
    Koderift::Rails.configure do |c|
      c.project_token     = 'test-token-abc'
      c.rum_token         = 'rum_test-public'
      c.rum_enabled       = true
      c.rum_sampling_rate = 0.1
    end
  end

  after { Koderift::Rails.reset! }

  describe '#koderift_rum_meta_tag' do
    it 'renders a meta tag with the RUM token' do
      result = koderift_rum_meta_tag
      expect(result).to include('name="koderift-rum-token"')
      expect(result).to include('content="rum_test-public"')
    end

    it 'never publishes the project token' do
      expect(koderift_rum_meta_tag).not_to include('test-token-abc')
    end

    it 'includes the sampling rate as a data attribute' do
      result = koderift_rum_meta_tag
      expect(result).to include('0.1')
    end

    it 'returns empty string when rum_enabled is false' do
      Koderift::Rails.configure { |c| c.rum_enabled = false }
      expect(koderift_rum_meta_tag).to eq('')
    end

    it 'returns empty string when rum_token is blank, with no fallback to project_token' do
      Koderift::Rails.configure { |c| c.rum_token = nil }
      expect(koderift_rum_meta_tag).to eq('')
    end

    it 'returns empty string when rum_token is the project token' do
      Koderift::Rails.configure { |c| c.rum_token = 'test-token-abc' }
      expect(koderift_rum_meta_tag).to eq('')
    end

    it 'renders with a rum_token even when project_token is blank' do
      Koderift::Rails.configure { |c| c.project_token = nil }
      expect(koderift_rum_meta_tag).to include('content="rum_test-public"')
    end

    it 'returns html_safe string' do
      expect(koderift_rum_meta_tag).to be_html_safe
    end

    it 'uses configured sampling rate' do
      Koderift::Rails.configure { |c| c.rum_sampling_rate = 0.5 }
      result = koderift_rum_meta_tag
      expect(result).to include('0.5')
    end

    it 'includes data-environment attribute with current Rails env' do
      result = koderift_rum_meta_tag
      expect(result).to include('data-environment')
    end

    it 'uses Rails.env for the environment attribute' do
      without_partial_double_verification do
        allow(::Rails).to receive(:env).and_return(
          ActiveSupport::StringInquirer.new('staging')
        )
        result = koderift_rum_meta_tag
        expect(result).to include('staging')
      end
    end

    it 'falls back to production when Rails is not defined' do
      hide_const('::Rails')
      result = koderift_rum_meta_tag
      expect(result).to include('production')
    end
  end

  describe 'warnings when RUM has no publishable token' do
    include_context 'a captured log'

    def warnings
      log_lines.select { |(severity, _)| severity == :warn }.map(&:last)
    end

    it 'warns once per process when rum_token is missing but the gem is configured' do
      Koderift::Rails.configure { |c| c.rum_token = nil }
      2.times { koderift_rum_meta_tag }
      expect(warnings).to eq([ Koderift::Rails::RumHelper::MISSING_RUM_TOKEN_WARNING ])
    end

    it 'warns when rum_token is the project token' do
      Koderift::Rails.configure { |c| c.rum_token = c.project_token }
      koderift_rum_meta_tag
      expect(warnings).to eq([ Koderift::Rails::RumHelper::SECRET_RUM_TOKEN_WARNING ])
    end

    it 'stays quiet when the gem is not configured at all' do
      Koderift::Rails.configure do |c|
        c.project_token = nil
        c.rum_token     = nil
      end
      koderift_rum_meta_tag
      expect(warnings).to be_empty
    end

    it 'stays quiet when rum_enabled is false' do
      Koderift::Rails.configure do |c|
        c.rum_token   = nil
        c.rum_enabled = false
      end
      koderift_rum_meta_tag
      expect(warnings).to be_empty
    end

    it 'warns again after reset!' do
      Koderift::Rails.configure { |c| c.rum_token = nil }
      koderift_rum_meta_tag
      Koderift::Rails.reset!
      Koderift::Rails.configure { |c| c.project_token = 'test-token' }
      koderift_rum_meta_tag
      expect(warnings.size).to eq(2)
    end
  end
end
