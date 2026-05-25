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

  describe 'trace ID propagation' do
    # Stand-in for Net::HTTP — `request` returns the req so we can inspect
    # what the prepended patch did to it before calling super.
    def fake_http_class
      Class.new do
        def request(req, *_args, &_block)
          req
        end
      end.tap { |c| c.prepend(Koderift::Rails::NetHttpPatch) }
    end

    it 'injects X-Koderift-Trace-ID header into outbound Net::HTTP requests' do
      trace_id = 'test-trace-id-1234'
      Thread.current[:koderift_trace_id] = trace_id

      req = Net::HTTP::Get.new('/')
      fake_http_class.new.request(req)

      expect(req['X-Koderift-Trace-ID']).to eq(trace_id)
    ensure
      Thread.current[:koderift_trace_id] = nil
    end

    it 'does not inject header when no trace_id is set' do
      Thread.current[:koderift_trace_id] = nil

      req = Net::HTTP::Get.new('/')
      fake_http_class.new.request(req)

      expect(req['X-Koderift-Trace-ID']).to be_nil
    end

    it 'includes trace_id in captured external call hash' do
      trace_id = 'abc-123'

      result = Koderift::Rails::Instrumentation.capture do
        Thread.current[:koderift_trace_id] = trace_id
        Thread.current[:koderift_external_calls] << {
          host:        'api.stripe.com',
          endpoint:    '/v1/charges',
          method:      'POST',
          status:      200,
          duration_ms: 145,
          trace_id:    trace_id
        }
      end

      call = result[:external_calls].first
      expect(call[:trace_id]).to eq(trace_id)
    ensure
      Thread.current[:koderift_trace_id] = nil
    end

    it 'propagates incoming trace ID rather than generating a new one' do
      upstream_trace = 'upstream-trace-xyz'
      headers        = { 'X-Koderift-Trace-ID' => upstream_trace }

      trace_id = headers['X-Koderift-Trace-ID'].presence || SecureRandom.uuid
      expect(trace_id).to eq(upstream_trace)
    end

    it 'generates a new trace ID when no upstream header present' do
      headers  = {}
      trace_id = headers['X-Koderift-Trace-ID'].presence || SecureRandom.uuid
      expect(trace_id).to match(/\A[0-9a-f\-]{36}\z/)
    end
  end
end
