require 'spec_helper'

RSpec.describe Koderift::Rails::Configuration do
  subject(:config) { described_class.new }

  it 'has nil project_token by default' do
    expect(config.project_token).to be_nil
  end

  it 'has sensible filter_params defaults' do
    expect(config.filter_params).to include('password', 'token', 'secret')
  end

  it 'has 20 max_breadcrumbs by default' do
    expect(config.max_breadcrumbs).to eq(20)
  end

  it 'is enabled by default' do
    expect(config.enabled).to be true
  end

  it 'is not valid without a project_token' do
    expect(config.valid?).to be false
  end

  it 'is valid with a project_token' do
    config.project_token = 'abc123'
    expect(config.valid?).to be true
  end

  it 'defaults rum_enabled to true' do
    expect(config.rum_enabled).to be true
  end

  it 'defaults rum_sampling_rate to 0.1' do
    expect(config.rum_sampling_rate).to eq(0.1)
  end

  it 'allows rum_enabled to be set to false' do
    config.rum_enabled = false
    expect(config.rum_enabled).to be false
  end

  it 'allows rum_sampling_rate to be configured' do
    config.rum_sampling_rate = 0.5
    expect(config.rum_sampling_rate).to eq(0.5)
  end
end
