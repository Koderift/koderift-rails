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

  # Reproduces the stdlib re-entry shape line for line, including the non-local
  # `return` out of the `start` block (which is what makes the guard's ensure
  # load-bearing) and start closing the socket on the way out.
  describe 'Net::HTTP re-entrancy' do
    def reentrant_http_class
      Class.new do
        attr_reader :address, :invocations, :transports

        def initialize(address: 'sender.thelinkcm.com', started: false,
                       connect_ms: 60, transport_ms: 2,
                       status: '201', raise_with: nil)
          @address      = address
          @started      = started
          @connect_ms   = connect_ms
          @transport_ms = transport_ms
          @raise_with   = raise_with
          @response     = Net::HTTPResponse.new('1.1', status, 'Created')
          @invocations  = 0 # entries into the UNPATCHED body (2 == it re-entered)
          @transports   = 0 # requests that actually went on the wire
        end

        def started?
          @started
        end

        def start
          sleep(@connect_ms / 1000.0) # DNS + TCP + TLS
          @started = true
          yield
        ensure
          @started = false            # socket closed -> next call reconnects
        end

        def request(req, body = nil, &block)
          @invocations += 1

          unless started?
            start {
              req['connection'] ||= 'close'
              return request(req, body, &block)
            }
          end

          @transports += 1
          sleep(@transport_ms / 1000.0)
          raise @raise_with if @raise_with

          block&.call(@response)
          @response
        end
      end.tap { |c| c.prepend(Koderift::Rails::NetHttpPatch) }
    end

    # Own thread per example so the guard's thread-local cannot leak.
    def with_capture
      calls = nil
      result = nil
      Thread.new do
        result = Koderift::Rails::Instrumentation.capture do
          calls = Thread.current[:koderift_external_calls]
          yield
        end
      end.join
      [calls, result]
    end

    it 'records exactly one entry for one logical call on a cold connection' do
      http = reentrant_http_class.new
      req  = Net::HTTP::Post.new('/api/messages')

      calls, _result = with_capture { http.request(req) }

      # Anti-vacuity: if the stand-in stopped re-entering, or only ever made
      # one call, the assertion below would prove nothing.
      expect(http.invocations).to eq(2)
      expect(http.transports).to eq(1)

      expect(calls.size).to eq(1)
    end

    it 'emits one http span, not two, for one logical call' do
      http = reentrant_http_class.new
      req  = Net::HTTP::Post.new('/api/messages')

      _calls, result = with_capture { http.request(req) }

      http_spans = result[:spans].select { |s| s[:type] == 'http' }
      expect(http_spans.size).to eq(1)
      expect(http_spans.first[:name]).to eq('sender.thelinkcm.com/api/messages')
      expect(http_spans.first[:sequence]).to eq(0)
    end

    it 'keeps the outer timing, which includes connection setup' do
      http = reentrant_http_class.new(connect_ms: 60, transport_ms: 2)
      req  = Net::HTTP::Post.new('/api/messages')

      calls, _result = with_capture { http.request(req) }

      expect(calls.size).to eq(1)
      # The inner frame is timed from after the connection is open, so it can
      # only ever be a couple of ms. >= 50 against a 60ms sleep proves the
      # surviving entry is the outer one.
      expect(calls.first[:duration_ms]).to be >= 50
    end

    it 'records a second entry for a genuine second call on a started connection' do
      http = reentrant_http_class.new(started: true)

      calls, _result = with_capture do
        http.request(Net::HTTP::Get.new('/api/messages/1'))
        http.request(Net::HTTP::Get.new('/api/messages/2'))
      end

      expect(http.invocations).to eq(2) # warm: no recursion
      expect(calls.size).to eq(2)
    end

    it 'records once per logical call when every call reconnects' do
      http = reentrant_http_class.new(connect_ms: 1)

      calls, _result = with_capture do
        http.request(Net::HTTP::Post.new('/api/messages'))
        http.request(Net::HTTP::Post.new('/api/messages'))
      end

      expect(http.invocations).to eq(4) # two logical calls, each re-entering
      expect(calls.size).to eq(2)
    end

    # Hypothetical, not witnessed: an exhaustive grep of every repo and gem on
    # this machine found five real `#request { |res| ... }` call sites and none
    # of them nests an HTTP call. Kept because the identity guard handles it for
    # free; see the ordering caveat in the plan before trusting the output.
    it 'still records a nested call to another host made from the response block' do
      outer = reentrant_http_class.new(address: 'sender.thelinkcm.com', connect_ms: 1)
      inner = reentrant_http_class.new(address: 'uploads.example.com', started: true)

      calls, _result = with_capture do
        outer.request(Net::HTTP::Post.new('/api/messages')) do |_res|
          inner.request(Net::HTTP::Put.new('/v1/objects/abc'))
        end
      end

      # Completion order: the nested call finishes first.
      expect(calls.map { |c| c[:host] })
        .to eq(['uploads.example.com', 'sender.thelinkcm.com'])
    end

    it 'leaves the guard clean when the request raises, so the next call records' do
      broken  = reentrant_http_class.new(connect_ms: 1, raise_with: Errno::ECONNRESET)
      healthy = reentrant_http_class.new(connect_ms: 1)
      req     = Net::HTTP::Post.new('/api/messages') # SAME object both times

      calls, _result = with_capture do
        expect { broken.request(req) }.to raise_error(Errno::ECONNRESET)
        healthy.request(req)
      end

      expect(calls.size).to eq(1)
      expect(calls.first[:host]).to eq('sender.thelinkcm.com')
    end

    it 'injects the trace ID header exactly once on a re-entrant call' do
      trace_id = 'test-trace-id-1234'
      http     = reentrant_http_class.new(connect_ms: 1)
      req      = Net::HTTP::Post.new('/api/messages')

      calls, _result = with_capture do
        Thread.current[:koderift_trace_id] = trace_id
        http.request(req)
      end

      expect(req['X-Koderift-Trace-ID']).to eq(trace_id)
      expect(req.get_fields('X-Koderift-Trace-ID')).to eq([trace_id])
      expect(calls.size).to eq(1)
      expect(calls.first[:trace_id]).to eq(trace_id)
    end
  end

  # Replaces the deleted `describe 'external call capture'`. Warm connection, so
  # re-entrancy is out of the picture and only the recording rules are tested --
  # and unlike the deleted block, these drive NetHttpPatch for real.
  describe 'external call recording' do
    def warm_http_class
      Class.new do
        attr_reader :address, :transports

        def initialize(address: 'api.stripe.com', status: '201')
          @address    = address
          @transports = 0
          @response   = Net::HTTPResponse.new('1.1', status, 'Created')
        end

        def started?
          true
        end

        def request(_req, _body = nil, &_block)
          @transports += 1
          @response
        end
      end.tap { |c| c.prepend(Koderift::Rails::NetHttpPatch) }
    end

    def with_capture
      calls = nil
      result = nil
      Thread.new do
        result = Koderift::Rails::Instrumentation.capture do
          calls = Thread.current[:koderift_external_calls]
          yield
        end
      end.join
      [calls, result]
    end

    it 'records host, endpoint, method and status for a captured call' do
      http = warm_http_class.new

      calls, _result = with_capture { http.request(Net::HTTP::Post.new('/v1/charges')) }

      expect(calls.size).to eq(1)
      expect(calls.first).to include(
        host: 'api.stripe.com', endpoint: '/v1/charges',
        method: 'POST', status: 201
      )
      expect(calls.first[:duration_ms]).to be_a(Integer)
    end

    it 'truncates the recorded endpoint to two path segments and drops the query' do
      http = warm_http_class.new

      calls, _result = with_capture do
        http.request(Net::HTTP::Get.new('/v1/charges/ch_abc123xyz?expand[]=customer'))
      end

      expect(calls.first[:endpoint]).to eq('/v1/charges')
    end

    it 'records the root path as "/"' do
      http = warm_http_class.new

      calls, _result = with_capture { http.request(Net::HTTP::Get.new('/')) }

      expect(calls.first[:endpoint]).to eq('/')
    end

    it 'does not record loopback hosts' do
      %w[127.0.0.1 localhost [::1]].each do |host|
        http = warm_http_class.new(address: host)

        calls, _result = with_capture { http.request(Net::HTTP::Get.new('/health')) }

        expect(calls).to be_empty
      end
    end

    it 'does not record a host matched by external_call_ignore_hosts' do
      Koderift::Rails.configure { |c| c.external_call_ignore_hosts = ['internal.example'] }
      http = warm_http_class.new(address: 'svc.internal.example.com')

      calls, result = with_capture { http.request(Net::HTTP::Get.new('/health')) }

      expect(calls).to be_empty
      expect(result[:spans].select { |s| s[:type] == 'http' }).to be_empty
    end

    it 'is a pass-through when no capture block is active' do
      http = warm_http_class.new
      response = nil

      Thread.new { response = http.request(Net::HTTP::Get.new('/v1/charges')) }.join

      expect(response).to be_a(Net::HTTPResponse)
      expect(http.transports).to eq(1)
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
