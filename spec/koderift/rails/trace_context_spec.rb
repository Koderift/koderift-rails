require 'spec_helper'

RSpec.describe Koderift::Rails::TraceContext do
  let(:trace_id) { '4bf92f3577b34da6a3ce929d0e0e4736' }
  let(:span_id)  { '00f067aa0ba902b7' }
  let(:valid)    { "00-#{trace_id}-#{span_id}-01" }

  describe '.new_trace_id / .new_span_id' do
    it 'are lowercase hex of the W3C lengths' do
      expect(described_class.new_trace_id).to match(/\A[0-9a-f]{32}\z/)
      expect(described_class.new_span_id).to match(/\A[0-9a-f]{16}\z/)
    end
  end

  describe '.parse_traceparent' do
    it 'parses a valid version 00 header' do
      expect(described_class.parse_traceparent(valid))
        .to eq(trace_id: trace_id, parent_span_id: span_id, flags: '01')
    end

    it 'keeps an unsampled flag' do
      expect(described_class.parse_traceparent("00-#{trace_id}-#{span_id}-00")[:flags]).to eq('00')
    end

    # Level 1: unknown flags are zeroed before the context is sent on.
    it 'keeps only the sampled bit of the flags' do
      expect(described_class.parse_traceparent("00-#{trace_id}-#{span_id}-03")[:flags]).to eq('01')
      expect(described_class.parse_traceparent("00-#{trace_id}-#{span_id}-02")[:flags]).to eq('00')
    end

    it 'tolerates surrounding whitespace' do
      expect(described_class.parse_traceparent("  #{valid}\t")).not_to be_nil
    end

    {
      'uppercase hex'                     => "00-#{'4BF92F3577B34DA6A3CE929D0E0E4736'}-00f067aa0ba902b7-01",
      'an all-zero trace ID'              => "00-#{'0' * 32}-00f067aa0ba902b7-01",
      'an all-zero parent ID'             => "00-4bf92f3577b34da6a3ce929d0e0e4736-#{'0' * 16}-01",
      'version ff'                        => 'ff-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01',
      'version 00 with an extra field'    => '00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01-extra',
      'a short trace ID'                  => '00-4bf92f3577b34da6a3ce929d0e0e473-00f067aa0ba902b7-01',
      'a long parent ID'                  => '00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7a-01',
      'a one-character version'           => '0-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01',
      'a future version without a dash'   => 'cc-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01x',
      'two headers joined by a comma'     => '00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01, ' \
                                             '00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01',
      'garbage'                           => 'garbage',
      'an empty string'                   => ''
    }.each do |label, header|
      it "rejects #{label}" do
        expect(described_class.parse_traceparent(header)).to be_nil
      end
    end

    it 'rejects non-strings and oversized values without raising' do
      expect(described_class.parse_traceparent(nil)).to be_nil
      expect(described_class.parse_traceparent(42)).to be_nil
      expect(described_class.parse_traceparent('0' * 10_000)).to be_nil
    end

    it 'reads an unknown version by its first four fields, extra fields included' do
      parsed = described_class.parse_traceparent("cc-#{trace_id}-#{span_id}-01-what-the-future-holds")

      expect(parsed).to eq(trace_id: trace_id, parent_span_id: span_id, flags: '01')
    end
  end

  describe '.format_traceparent' do
    it 'writes version 00' do
      expect(described_class.format_traceparent(trace_id, span_id)).to eq(valid)
      expect(described_class.format_traceparent(trace_id, span_id, '00')).to eq("00-#{trace_id}-#{span_id}-00")
    end

    # A non-hex trace ID put on the thread by older code never becomes a
    # malformed header.
    it 'returns nil for IDs that are not valid' do
      expect(described_class.format_traceparent('outer-trace', span_id)).to be_nil
      expect(described_class.format_traceparent(trace_id, nil)).to be_nil
    end
  end

  describe '.parse_sentry_trace' do
    it 'parses a sampled header' do
      expect(described_class.parse_sentry_trace("#{trace_id}-#{span_id}-1"))
        .to eq(trace_id: trace_id, parent_span_id: span_id, flags: '01')
    end

    it 'maps sampled 0 to flags 00' do
      expect(described_class.parse_sentry_trace("#{trace_id}-#{span_id}-0")[:flags]).to eq('00')
    end

    it 'treats a missing sampled flag as sampled' do
      expect(described_class.parse_sentry_trace("#{trace_id}-#{span_id}")[:flags]).to eq('01')
    end

    it 'rejects malformed values' do
      ["#{trace_id}-#{span_id}-2", "#{trace_id}-#{span_id[0, 15]}", trace_id, 'garbage', nil]
        .each { |value| expect(described_class.parse_sentry_trace(value)).to be_nil }
    end
  end

  describe '.normalise_legacy' do
    it 'turns a dashed UUID into 32 lowercase hex' do
      expect(described_class.normalise_legacy('4BF92F35-77B3-4DA6-A3CE-929D0E0E4736')).to eq(trace_id)
    end

    it 'accepts a UUID without dashes' do
      expect(described_class.normalise_legacy(trace_id)).to eq(trace_id)
    end

    it 'rejects anything else' do
      ['trace-from-upstream', '4bf92f35-77b3-4da6-a3ce', '0' * 32, nil, '']
        .each { |value| expect(described_class.normalise_legacy(value)).to be_nil }
    end
  end

  describe '.parse_tracestate' do
    it 'keeps a printable value' do
      expect(described_class.parse_tracestate(' rojo=00f067aa0ba902b7,congo=t61rcWkgMzE ')).to eq('rojo=00f067aa0ba902b7,congo=t61rcWkgMzE')
    end

    it 'drops values with control characters' do
      expect(described_class.parse_tracestate("rojo=1\r\nX-Evil: 1")).to be_nil
    end

    it 'cuts long values by dropping oversized entries, then entries from the end' do
      long_entry = "big=#{'x' * 200}"
      entries    = Array.new(60) { |i| "v#{i}=#{'a' * 8}" }
      value      = described_class.parse_tracestate(([long_entry] + entries).join(','))

      expect(value.length).to be <= 512
      expect(value).not_to include('big=')
      expect(value).to start_with('v0=')
    end
  end

  describe '.incoming' do
    let(:other_trace) { 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' }
    let(:other_span)  { 'bbbbbbbbbbbbbbbb' }

    it 'prefers X-Koderift-Traceparent over every other header' do
      ctx = described_class.incoming(
        'X-Koderift-Traceparent' => valid,
        'traceparent'            => "00-#{other_trace}-#{other_span}-01",
        'sentry-trace'           => "#{other_trace}-#{other_span}-1",
        'X-Koderift-Trace-ID'    => other_trace
      )

      expect(ctx).to include(trace_id: trace_id, parent_span_id: span_id)
    end

    it 'uses traceparent when there is no Koderift traceparent' do
      ctx = described_class.incoming('traceparent' => valid, 'sentry-trace' => "#{other_trace}-#{other_span}-1")

      expect(ctx).to include(trace_id: trace_id, parent_span_id: span_id)
    end

    it 'falls back to sentry-trace' do
      ctx = described_class.incoming('sentry-trace' => "#{trace_id}-#{span_id}-0")

      expect(ctx).to include(trace_id: trace_id, parent_span_id: span_id, flags: '00')
    end

    # A caller before 2.2 that also runs Sentry or an APM sends that tool's
    # header next to its own UUID. Nothing but this gem sets the Koderift ID,
    # so it wins; that header has no parent span to offer.
    it "follows a legacy Koderift ID over a traceparent that disagrees" do
      ctx = described_class.incoming(
        'traceparent'         => "00-#{other_trace}-#{other_span}-01",
        'tracestate'          => 'apm=1',
        'X-Koderift-Trace-ID' => '4bf92f35-77b3-4da6-a3ce-929d0e0e4736'
      )

      expect(ctx).to eq(trace_id: trace_id, parent_span_id: nil, flags: '01', tracestate: nil)
    end

    it "follows a legacy Koderift ID over a sentry-trace that disagrees" do
      ctx = described_class.incoming('sentry-trace'        => "#{other_trace}-#{other_span}-1",
                                     'X-Koderift-Trace-ID' => '4bf92f35-77b3-4da6-a3ce-929d0e0e4736')

      expect(ctx).to include(trace_id: trace_id, parent_span_id: nil)
    end

    it 'keeps the traceparent parent and tracestate when the legacy ID agrees' do
      ctx = described_class.incoming('traceparent' => valid, 'tracestate' => 'rojo=1', 'X-Koderift-Trace-ID' => trace_id)

      expect(ctx).to eq(trace_id: trace_id, parent_span_id: span_id, flags: '01', tracestate: 'rojo=1')
    end

    it 'ignores a legacy value that is not a UUID when choosing between headers' do
      ctx = described_class.incoming('traceparent' => valid, 'X-Koderift-Trace-ID' => 'trace-from-upstream')

      expect(ctx).to include(trace_id: trace_id, parent_span_id: span_id)
    end

    it 'falls back to the legacy header, with no parent' do
      ctx = described_class.incoming('X-Koderift-Trace-ID' => '4bf92f35-77b3-4da6-a3ce-929d0e0e4736')

      expect(ctx).to include(trace_id: trace_id, parent_span_id: nil)
    end

    it 'skips an invalid header and uses the next source' do
      ctx = described_class.incoming('traceparent' => 'garbage', 'sentry-trace' => "#{trace_id}-#{span_id}")

      expect(ctx[:trace_id]).to eq(trace_id)
    end

    it 'starts a new trace when nothing usable arrives' do
      [{}, { 'traceparent' => 'garbage' }, { 'X-Koderift-Trace-ID' => 'trace-from-upstream' }, nil].each do |source|
        ctx = described_class.incoming(source)

        expect(ctx[:trace_id]).to match(/\A[0-9a-f]{32}\z/)
        expect(ctx[:parent_span_id]).to be_nil
      end
    end

    it 'reads Rack env keys' do
      ctx = described_class.incoming('HTTP_TRACEPARENT' => valid, 'HTTP_TRACESTATE' => 'rojo=1')

      expect(ctx).to include(trace_id: trace_id, parent_span_id: span_id, tracestate: 'rojo=1')
    end

    it 'keeps tracestate only with the traceparent it belongs to' do
      same  = described_class.incoming('traceparent' => valid, 'tracestate' => 'rojo=1')
      other = described_class.incoming('X-Koderift-Traceparent' => "00-#{other_trace}-#{other_span}-01",
                                       'traceparent' => valid, 'tracestate' => 'rojo=1')

      expect(same[:tracestate]).to eq('rojo=1')
      expect(other[:tracestate]).to be_nil
    end

    it 'never raises, even for a source that does' do
      exploding = Object.new
      def exploding.[](_key)
        raise 'boom'
      end

      expect(described_class.incoming(exploding)[:trace_id]).to match(/\A[0-9a-f]{32}\z/)
    end
  end

  describe '.from_job' do
    it 'continues a stored traceparent' do
      expect(described_class.from_job('koderift_traceparent' => valid))
        .to include(trace_id: trace_id, parent_span_id: span_id)
    end

    it 'falls back to the legacy key, normalised, with no parent' do
      expect(described_class.from_job('koderift_trace_id' => '4bf92f35-77b3-4da6-a3ce-929d0e0e4736'))
        .to include(trace_id: trace_id, parent_span_id: nil)
    end

    it 'starts a new trace otherwise' do
      expect(described_class.from_job('koderift_trace_id' => 'nope')[:trace_id]).to match(/\A[0-9a-f]{32}\z/)
      expect(described_class.from_job(nil)[:trace_id]).to match(/\A[0-9a-f]{32}\z/)
    end
  end

  describe Koderift::Rails::TraceContext::Current do
    it 'publishes the trace ID and context, and clears them when the unit ends' do
      frame = described_class.push(kind: :request, trace_id: trace_id, context: { component: 'X' })

      expect(Thread.current[:koderift_trace_id]).to eq(trace_id)
      expect(Thread.current[:koderift_context]).to eq(component: 'X')
      expect(described_class.current_span_id).to eq(frame.root_span_id)
      expect(described_class.enclosing_span_id).to be_nil

      described_class.pop(frame)

      expect(Thread.current[:koderift_trace_id]).to be_nil
      expect(Thread.current[:koderift_context]).to be_nil
      expect(described_class.frame).to be_nil
    end

    it 'formats a traceparent for the current span' do
      frame = described_class.push(kind: :request, trace_id: trace_id, flags: '00')

      expect(described_class.traceparent).to eq("00-#{trace_id}-#{frame.root_span_id}-00")
    end

    it 'stamps started_at as UTC ISO-8601 with milliseconds' do
      frame = described_class.push(kind: :job, trace_id: trace_id)

      expect(frame.started_at).to match(/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z\z/)
    end
  end
end
