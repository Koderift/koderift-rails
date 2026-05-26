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
      c.rum_enabled       = true
      c.rum_sampling_rate = 0.1
    end
  end

  after { Koderift::Rails.reset! }

  describe '#koderift_rum_meta_tag' do
    it 'renders a meta tag with the project token' do
      result = koderift_rum_meta_tag
      expect(result).to include('name="koderift-rum-token"')
      expect(result).to include('content="test-token-abc"')
    end

    it 'includes the sampling rate as a data attribute' do
      result = koderift_rum_meta_tag
      expect(result).to include('0.1')
    end

    it 'returns empty string when rum_enabled is false' do
      Koderift::Rails.configure { |c| c.rum_enabled = false }
      expect(koderift_rum_meta_tag).to eq('')
    end

    it 'returns empty string when project_token is blank' do
      Koderift::Rails.configure { |c| c.project_token = nil }
      expect(koderift_rum_meta_tag).to eq('')
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
end
