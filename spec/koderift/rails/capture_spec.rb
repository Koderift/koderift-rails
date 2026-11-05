require 'spec_helper'

RSpec.describe Koderift::Rails::Capture do
  include_context 'a captured log'

  describe '.exception' do
    it 'returns an Event whose id is a 32-character hex, as Sentry ids are' do
      event = Koderift.capture_exception(raised)

      expect(event).to be_a(Koderift::Rails::Event)
      expect(event.event_id).to match(/\A[0-9a-f]{32}\z/)
    end

    it 'supports the &.event_id idiom by returning nil rather than raising' do
      Koderift::Rails.configure { |c| c.enabled = false }

      expect(Koderift.capture_exception(raised)&.event_id).to be_nil
    end

    it 'writes one JSON line with koderift_capture as the first key' do
      Koderift.capture_exception(raised)

      expect(capture_lines.size).to eq 1
      expect(last_payload.keys.first).to eq 'koderift_capture'
    end

    it 'carries the exception, message and formatted backtrace' do
      Koderift.capture_exception(raised)
      payload = last_payload

      expect(payload['exception']).to eq 'ArgumentError: bad token'
      expect(payload['message']).to   eq 'ArgumentError: bad token'
      expect(payload['stack_trace']).to include('capture_spec.rb')
    end

    it 'records the cause chain' do
      error = begin
        begin
          raise IOError, 'socket closed'
        rescue StandardError
          raise ArgumentError, 'bad token'
        end
      rescue StandardError => e
        e
      end

      Koderift.capture_exception(error)

      expect(last_payload['error_cause']).to eq 'socket closed'
    end

    it 'accepts an explicit backtrace' do
      Koderift.capture_exception(raised, backtrace: ['app/models/order.rb:5:in `sync\''])

      expect(last_payload['stack_trace']).to eq 'app/models/order.rb:5:in `sync\''
    end

    it 'ignores anything that is not an exception' do
      expect(Koderift.capture_exception('a string')).to be_nil
      expect(capture_lines).to be_empty
    end

    it 'does not emit when no project token is configured' do
      Koderift::Rails.configure { |c| c.project_token = nil }

      expect(Koderift.capture_exception(raised)).to be_nil
      expect(capture_lines).to be_empty
    end

    it 'records the last event id' do
      event = Koderift.capture_exception(raised)

      expect(Koderift.last_event_id).to eq event.event_id
    end
  end

  describe 'log severity' do
    it 'writes at the severity matching the level, so the app log reads correctly' do
      Koderift.capture_exception(raised, level: :error)
      expect(last_severity).to eq :error

      Koderift.capture_exception(raised, level: :fatal)
      expect(last_severity).to eq :fatal

      Koderift.capture_message('heads up', level: :warning)
      expect(last_severity).to eq :warn

      Koderift.capture_message('fyi', level: :info)
      expect(last_severity).to eq :info
    end
  end

  describe 'level normalisation' do
    # A level outside LogAnalyticsQueryService::LOG_LEVELS produces rows the Log
    # Explorer's level filter cannot select, so Sentry's extra levels fold.
    it 'folds :warning to warn and :debug to info' do
      Koderift.capture_message('a', level: :warning)
      expect(last_payload['level']).to eq 'warn'

      Koderift.capture_message('b', level: :debug)
      expect(last_payload['level']).to eq 'info'
    end

    it 'falls back to error for an unrecognised level' do
      Koderift.capture_exception(raised, level: :nonsense)

      expect(last_payload['level']).to eq 'error'
    end
  end

  describe '.message' do
    it 'sets no exception below error level, because nothing could group it' do
      Koderift.capture_message('just so you know', level: :info)

      expect(last_payload).not_to have_key('exception')
    end

    it 'synthesises a grouping class at error level' do
      Koderift.capture_message('sync drifted', level: :error, name: 'SyncDrift')

      expect(last_payload['exception']).to eq 'SyncDrift: sync drifted'
    end

    it 'falls back to the default class when no name is given' do
      Koderift.capture_message('sync drifted', level: :error)

      expect(last_payload['exception']).to eq 'Koderift::Message: sync drifted'
    end

    it 'camelises a name that is not already constant-shaped' do
      Koderift.capture_message('x', level: :error, name: 'payment.retry_exhausted')

      expect(last_payload['exception']).to start_with 'PaymentRetryExhausted:'
    end

    it 'falls back to the default when a name cannot be made constant-shaped' do
      Koderift.capture_message('x', level: :error, name: '!!!')

      expect(last_payload['exception']).to start_with 'Koderift::Message:'
    end
  end

  describe 'fingerprint' do
    it 'prefixes the exception with a synthesised class so grouping follows it' do
      Koderift.capture_exception(raised, fingerprint: %w[stripe timeout])

      expect(last_payload['exception']).to eq 'StripeTimeout: ArgumentError: bad token'
    end
  end

  describe 'context scrubbing' do
    # LogAgent::Parser matches "controller": / "method": / "job_class": ANYWHERE
    # in the line. Leaving one in would make an older agent parse the capture as
    # a Lograge request line and corrupt the customer's APM figures.
    it 'strips reserved keys at every depth' do
      Koderift.capture_exception(
        raised,
        tags:  { controller: 'Nope' },
        extra: { nested: { method: 'POST', job_class: 'Worker', kept: 1 } }
      )
      line = capture_lines.last[1]

      expect(line).not_to include('"controller":')
      expect(line).not_to include('"method":')
      expect(line).not_to include('"job_class":')
      expect(last_payload['context']['extra']['nested']).to eq('kept' => 1)
    end

    it 'applies filter_params at every depth' do
      Koderift.capture_exception(
        raised,
        extra: { password: 'hunter2', deep: { api_token: 'abc', order_id: 91 } }
      )
      extra = last_payload['context']['extra']

      expect(extra).not_to have_key('password')
      expect(extra['deep']).to eq('order_id' => 91)
    end

    it 'drops whole keys rather than characters when the context is too large' do
      Koderift.capture_exception(raised, tags: { small: 'ok' },
                                         extra: { blob: 'x' * 6_000 })
      payload = last_payload

      # The agent JSON.parses the line as one unit, so a half-truncated context
      # would lose the entire capture, not just its tail.
      expect(payload['context']['truncated']).to be true
      expect(payload['context']['tags']).to eq('small' => 'ok')
      expect { JSON.parse(capture_lines.last[1]) }.not_to raise_error
    end

    it 'always carries the event id so it can be searched for' do
      event = Koderift.capture_exception(raised)

      expect(last_payload['context']['event_id']).to eq event.event_id
    end
  end

  describe 'user resolution' do
    it 'lifts the id out of a Sentry-shaped user hash' do
      Koderift.capture_exception(raised, user: { id: 42, email: 'a@b.c' })

      expect(last_payload['user_id']).to eq '42'
      expect(last_payload['context']['user']).to eq('id' => 42, 'email' => 'a@b.c')
    end

    it 'prefers an explicit user_id' do
      Koderift.capture_exception(raised, user_id: 7, user: { id: 42 })

      expect(last_payload['user_id']).to eq '7'
    end

    it 'reads the scope when the call gives no user' do
      Koderift.set_user(id: 99)
      Koderift.capture_exception(raised)

      expect(last_payload['user_id']).to eq '99'
    end
  end

  describe 'gates' do
    it 'skips an excluded exception, matching on the ancestor chain' do
      Koderift::Rails.configure { |c| c.excluded_exceptions = ['StandardError'] }

      expect(Koderift.capture_exception(raised)).to be_nil
      expect(capture_lines).to be_empty
    end

    it 'reports the same exception object only once' do
      error = raised

      expect(Koderift.capture_exception(error)).not_to be_nil
      expect(Koderift.capture_exception(error)).to be_nil
      expect(Koderift.exception_captured?(error)).to be true
    end

    it 'drops everything at sample_rate zero' do
      Koderift::Rails.configure { |c| c.sample_rate = 0.0 }

      expect(Koderift.capture_exception(raised)).to be_nil
    end

    it 'applies the gates in order: excluded before the rate limiter' do
      Koderift::Rails.configure do |c|
        c.excluded_exceptions    = ['ArgumentError']
        c.max_captures_per_minute = 1
      end

      Koderift.capture_exception(raised)          # excluded, must not spend the budget
      expect(Koderift.capture_message('still here', level: :info)).not_to be_nil
    end
  end

  describe 'rate limiting' do
    it 'emits up to the cap and announces the drop exactly once' do
      Koderift::Rails.configure { |c| c.max_captures_per_minute = 3 }

      6.times { Koderift.capture_exception(raised) }

      expect(capture_lines.size).to eq 3
      expect(warnings.grep(/rate limit of 3\/min reached/).size).to eq 1
    end

    it 'does not limit when set to nil' do
      Koderift::Rails.configure { |c| c.max_captures_per_minute = nil }

      10.times { Koderift.capture_exception(raised) }

      expect(capture_lines.size).to eq 10
    end

    it 'reports the dropped count when the window rolls over' do
      limiter = described_class::RateLimiter.new
      now     = 1_000.0
      allow(Process).to receive(:clock_gettime).with(Process::CLOCK_MONOTONIC) { now }

      3.times { limiter.allow(1) }
      now += 61

      _allowed, warning = limiter.allow(1)
      expect(warning).to include('dropped 2 capture(s)')
    end
  end

  describe 'before_send' do
    it 'emits what the callback returns' do
      Koderift::Rails.configure do |c|
        c.before_send = ->(payload, _hint) { payload.merge(message: 'rewritten') }
      end

      Koderift.capture_exception(raised)

      expect(last_payload['message']).to eq 'rewritten'
    end

    it 'drops the capture when the callback returns nil' do
      Koderift::Rails.configure { |c| c.before_send = ->(_p, _h) { nil } }

      expect(Koderift.capture_exception(raised)).to be_nil
      expect(capture_lines).to be_empty
    end

    it 'receives the hint' do
      seen = nil
      Koderift::Rails.configure do |c|
        c.before_send = ->(payload, hint) { seen = hint; payload }
      end

      Koderift.capture_exception(raised, hint: { source: 'cron' })

      expect(seen).to eq(source: 'cron')
    end

    # A bug in the customer's callback must not look identical to "nothing went
    # wrong" — silently losing error reports is the worst available failure.
    it 'emits the original payload and warns when the callback raises' do
      Koderift::Rails.configure { |c| c.before_send = ->(_p, _h) { raise 'callback bug' } }

      expect(Koderift.capture_exception(raised)).not_to be_nil
      expect(last_payload['message']).to eq 'ArgumentError: bad token'
      expect(warnings.grep(/before_send raised/)).not_to be_empty
    end
  end

  describe 'block form' do
    it 'applies the block scope to this capture only' do
      Koderift.set_tag(:region, 'eu')
      Koderift.capture_exception(raised) { |scope| scope.set_tag(:temp, 'yes') }

      expect(last_payload['context']['tags']).to eq('region' => 'eu', 'temp' => 'yes')
      expect(Koderift.get_current_scope.tags).to eq('region' => 'eu')
    end
  end

  describe 'resilience' do
    it 'never raises when the logger itself fails' do
      allow(logger).to receive(:error).and_raise(IOError, 'log device closed')

      expect { Koderift.capture_exception(raised) }.not_to raise_error
    end

    it 'never raises when a context value cannot be serialised' do
      unserialisable = Object.new
      def unserialisable.to_json(*_args)
        raise 'nope'
      end

      expect { Koderift.capture_exception(raised, extra: { bad: unserialisable }) }
        .not_to raise_error
    end
  end

  describe '.event' do
    it 're-emits an event under its original id' do
      event = Koderift.capture_exception(raised)
      log_lines.clear

      Koderift.capture_event(event)

      expect(last_payload['context']['event_id']).to eq event.event_id
      expect(last_payload['exception']).to eq 'ArgumentError: bad token'
    end
  end
end
