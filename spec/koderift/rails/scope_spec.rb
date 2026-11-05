require 'spec_helper'

RSpec.describe Koderift::Rails::Scope do
  include_context 'a captured log'

  describe 'ambient state' do
    it 'merges scope tags, extras and contexts into a capture' do
      Koderift.set_tags(region: 'eu')
      Koderift.set_extras(build: 42)
      Koderift.set_context('device', 'ipad')

      Koderift.capture_exception(raised)
      context = last_payload['context']

      expect(context['tags']).to     eq('region' => 'eu')
      expect(context['extra']).to    eq('build' => 42)
      expect(context['contexts']).to eq('device' => 'ipad')
    end

    it 'lets call-site options win over the scope' do
      Koderift.set_tags(region: 'eu')
      Koderift.capture_exception(raised, tags: { region: 'us' })

      expect(last_payload['context']['tags']).to eq('region' => 'us')
    end

    it 'splits a Sentry transaction name into component and action' do
      Koderift.configure_scope { |s| s.set_transaction_name('PaymentsController#create') }
      Koderift.capture_exception(raised)

      expect(last_payload['component']).to eq 'PaymentsController'
      expect(last_payload['action']).to    eq 'create'
    end
  end

  describe '.with_scope' do
    it 'restores the previous scope afterwards' do
      Koderift.set_tag(:region, 'eu')

      Koderift.with_scope do |scope|
        scope.set_tag(:temp, 'yes')
        expect(Koderift.get_current_scope.tags).to include('temp' => 'yes')
      end

      expect(Koderift.get_current_scope.tags).to eq('region' => 'eu')
    end

    it 'restores the scope even when the block raises' do
      Koderift.set_tag(:region, 'eu')

      expect do
        Koderift.with_scope { |s| s.set_tag(:temp, 'yes'); raise 'boom' }
      end.to raise_error('boom')

      expect(Koderift.get_current_scope.tags).to eq('region' => 'eu')
    end

    it 'never pops the root scope' do
      described_class.pop
      described_class.pop

      expect(described_class.stack.size).to eq 1
    end
  end

  describe 'thread isolation' do
    # Puma and Sidekiq both reuse threads. Without the reset in Controller and
    # SidekiqMiddleware, one request's tags would attach to the next request
    # served by the same thread.
    it 'keeps scopes separate per thread' do
      Koderift.set_tag(:region, 'eu')

      other = Thread.new { Koderift.get_current_scope.tags }.value

      expect(other).to eq({})
    end

    it 'is cleared by reset!' do
      Koderift.set_tag(:region, 'eu')
      described_class.reset!

      expect(Koderift.get_current_scope.tags).to eq({})
    end
  end
end
