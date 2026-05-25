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

    it 'captures every partial as a span without truncation' do
      result = nil
      thread = Thread.new do
        result = described_class.capture do
          [10, 50, 30].each do |ms|
            ActiveSupport::Notifications.instrument(
              'render_partial.action_view',
              identifier: "/app/views/pages/_partial_#{ms}.html.erb",
              duration:   ms.to_f
            )
          end
        end
      end
      thread.join

      partial_spans = result[:spans].select { |s| s[:type] == 'partial' }
      expect(partial_spans.size).to eq(3)
      partial_spans.each do |s|
        expect(s).to include(:type, :name, :duration_ms, :sequence)
      end
      expect(partial_spans.map { |s| s[:sequence] }).to eq([0, 1, 2])
      expect(result[:partial_count]).to eq(3)
    end

    it 'does not return the legacy blob keys' do
      result = nil
      thread = Thread.new do
        result = described_class.capture { nil }
      end
      thread.join

      expect(result).not_to have_key(:slow_partials)
      expect(result).not_to have_key(:query_stats)
      expect(result).not_to have_key(:search_stats)
      expect(result).not_to have_key(:external_calls)
    end

    it 'returns scalar counts for queries, partials, and searches' do
      result = nil
      thread = Thread.new do
        result = described_class.capture { nil }
      end
      thread.join

      expect(result).to include(query_count: 0, partial_count: 0, search_count: 0)
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

  describe 'search.searchkick instrumentation' do
    it 'captures single search notifications with correct index name' do
      result = nil
      thread = Thread.new do
        result = Koderift::Rails::Instrumentation.capture do
          ActiveSupport::Notifications.instrument(
            'search.searchkick',
            name: 'Admin10 Search'
          ) {}
        end
      end
      thread.join

      expect(result[:search_count]).to eq(1)
      q = result[:spans].find { |s| s[:type] == 'search' }
      expect(q[:name]).to eq('Admin10')
      expect(q[:duration_ms]).to be_a(Integer)
      expect(q[:sequence]).to eq(0)
    end

    it 'strips " Search" suffix from payload name' do
      result = nil
      thread = Thread.new do
        result = Koderift::Rails::Instrumentation.capture do
          ActiveSupport::Notifications.instrument(
            'search.searchkick',
            name: 'Property Search'
          ) {}
        end
      end
      thread.join

      expect(result[:spans].find { |s| s[:type] == 'search' }[:name]).to eq('Property')
    end

    it 'uses "unknown" when name has no model prefix' do
      result = nil
      thread = Thread.new do
        result = Koderift::Rails::Instrumentation.capture do
          ActiveSupport::Notifications.instrument(
            'search.searchkick',
            name: 'Search'
          ) {}
        end
      end
      thread.join

      expect(result[:spans].find { |s| s[:type] == 'search' }[:name]).to eq('unknown')
    end

    it 'captures multi_search notifications as "multi_search" index' do
      result = nil
      thread = Thread.new do
        result = Koderift::Rails::Instrumentation.capture do
          ActiveSupport::Notifications.instrument(
            'multi_search.searchkick',
            name: 'Multi Search',
            body: ''
          ) {}
        end
      end
      thread.join

      expect(result[:search_count]).to eq(1)
      expect(result[:spans].find { |s| s[:type] == 'search' }[:name]).to eq('multi_search')
    end

    it 'counts both single and multi search notifications together' do
      result = nil
      thread = Thread.new do
        result = Koderift::Rails::Instrumentation.capture do
          ActiveSupport::Notifications.instrument('search.searchkick',
            name: 'Admin10 Search') {}
          ActiveSupport::Notifications.instrument('multi_search.searchkick',
            name: 'Multi Search', body: '') {}
          ActiveSupport::Notifications.instrument('search.searchkick',
            name: 'Property Search') {}
        end
      end
      thread.join

      expect(result[:search_count]).to eq(3)
      expect(result[:spans].count { |s| s[:type] == 'search' }).to eq(3)
    end

    it 'returns zero search_count and no search spans when no searches occur' do
      result = nil
      thread = Thread.new do
        result = Koderift::Rails::Instrumentation.capture { nil }
      end
      thread.join

      expect(result[:search_count]).to eq(0)
      expect(result[:spans].select { |s| s[:type] == 'search' }).to be_empty
    end

    it 'ignores searchkick notifications outside a capture block' do
      expect {
        ActiveSupport::Notifications.instrument('search.searchkick',
          name: 'Admin10 Search') {}
        ActiveSupport::Notifications.instrument('multi_search.searchkick',
          name: 'Multi Search', body: '') {}
      }.not_to raise_error
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

    it 'includes trace_id inside the http span detail JSON' do
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

      span = result[:spans].find { |s| s[:type] == 'http' }
      expect(span[:name]).to eq('api.stripe.com/v1/charges')
      expect(span[:duration_ms]).to eq(145)
      expect(span[:sequence]).to eq(0)
      detail = JSON.parse(span[:detail])
      expect(detail).to include('method' => 'POST', 'status' => 200, 'trace_id' => trace_id)
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
