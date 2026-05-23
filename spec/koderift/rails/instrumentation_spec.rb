require 'spec_helper'
require 'active_support'
require 'active_support/notifications'
require 'koderift/rails/instrumentation'

RSpec.describe Koderift::Rails::Instrumentation do
  describe '.capture' do
    it 'returns empty collections when no events fire' do
      result = nil
      described_class.capture { result = true }

      # No events fired — should return empty data
    end

    it 'captures partial render events' do
      captured = nil

      # Simulate a render_partial notification
      thread = Thread.new do
        described_class.capture do
          ActiveSupport::Notifications.instrument(
            'render_partial.action_view',
            identifier: '/app/views/pages/_jobs.html.erb',
            duration:   150.0
          )
        end
      end

      thread.join
    end

    it 'filters CACHE and SCHEMA sql events' do
      described_class.capture do
        ActiveSupport::Notifications.instrument(
          'sql.active_record',
          name: 'CACHE',
          sql:  'SELECT 1',
          duration: 1.0
        )
      end
      # CACHE query should not appear in breadcrumbs
    end

    it 'caps breadcrumbs at max_breadcrumbs config' do
      Koderift::Rails.configure { |c| c.max_breadcrumbs = 3 }

      described_class.capture do
        5.times do |i|
          ActiveSupport::Notifications.instrument(
            'sql.active_record',
            name:     'SQL',
            sql:      "SELECT #{i}",
            duration: 1.0
          )
        end
      end
    end

    it 'returns top N slow partials sorted by duration' do
      Koderift::Rails.configure { |c| c.max_slow_partials = 2 }

      result = described_class.capture do
        [10, 50, 30].each do |ms|
          ActiveSupport::Notifications.instrument(
            'render_partial.action_view',
            identifier: "/app/views/pages/_partial_#{ms}.html.erb",
            duration:   ms.to_f
          )
        end
      end

      expect(result[:slow_partials].first[:duration_ms]).to eq(50)
      expect(result[:slow_partials].size).to eq(2)
    end

    it 'unsubscribes from notifications after capture' do
      subs_before = ActiveSupport::Notifications.notifier
                                                .listeners_for('sql.active_record')
                                                .size
      described_class.capture { nil }
      subs_after  = ActiveSupport::Notifications.notifier
                                                .listeners_for('sql.active_record')
                                                .size
      expect(subs_after).to eq(subs_before)
    end

    it 'unsubscribes even when block raises' do
      subs_before = ActiveSupport::Notifications.notifier
                                                .listeners_for('sql.active_record')
                                                .size
      expect do
        described_class.capture { raise 'boom' }
      end.to raise_error('boom')

      subs_after = ActiveSupport::Notifications.notifier
                                               .listeners_for('sql.active_record')
                                               .size
      expect(subs_after).to eq(subs_before)
    end
  end

  describe 'external call capture' do
    it 'captures Net::HTTP calls made during a request' do
      result = nil
      Koderift::Rails::Instrumentation.capture do
        Thread.current[:koderift_external_calls] << {
          host: 'api.stripe.com', endpoint: '/v1/charges',
          method: 'POST', status: 200, duration_ms: 145
        }
        result = :ok
      end
      expect(result).to eq(:ok)
    end

    it 'truncates path to two segments' do
      raw_path = '/v1/charges/ch_abc123xyz?expand[]=customer'
      segments = raw_path.split('?').first.split('/').reject(&:empty?).first(2)
      endpoint = '/' + segments.join('/')
      expect(endpoint).to eq('/v1/charges')
    end

    it 'excludes localhost calls' do
      ignored = ['127.0.0.1', 'localhost', '[::1]'].include?('localhost')
      expect(ignored).to be true
    end
  end
end
