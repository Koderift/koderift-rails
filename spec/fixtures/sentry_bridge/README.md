# sentry-ruby bridge fixtures (2.3.0, 2.3.1)

Real output from a Rails 8.1.3.1 app (Ruby 3.4.9) running koderift-rails 2.3.0
(this checkout), lograge 0.14.0, Sidekiq 8.1.6, and sentry-ruby, sentry-rails
and sentry-sidekiq 7.3.0. Generated on 23 Nov 2026. The two `rescue_from`
cases came from the same app on 2.3.1, generated on 24 Nov 2026 (release
`fixture-2.3.1`). Each case has a Sentry
envelope (written by a file transport, so nothing was sent) and the Rails log
lines the app wrote for it.

| Case | Envelope | Log | Shared key |
| --- | --- | --- | --- |
| `GET /users/7/edit` raising NoMethodError (sentry-rails) | `request.envelope` | `request.log` | `tags.request_id` = the lograge line's `request_id` |
| `FailingJob` raising ArgumentError, retry 0, under a real `sidekiq` server (sentry-sidekiq) | `job.envelope` | `job.log`, plus Sidekiq's own output in `job_sidekiq.log` | `tags.jid` = the job line's `jid` (and `tags.request_id` = the jid) |
| `billing:close_month` raising ZeroDivisionError, run as `bin/rails billing:close_month` (sentry/rake) | `rake_bin_rails.envelope` | `rake_bin_rails.log` | `tags.request_id` = the capture line's `request_id`, the rake run ID |
| The same task under the plain `rake` CLI | `rake_cli.envelope` | `rake_cli.log` | as above |
| 2.3.1: `GET /reports/7` raising NoMethodError, taken by `rescue_from StandardError, with: :report_and_render`, which calls `Koderift.capture_exception` and `Sentry.capture_exception` | `rescue_from.envelope` | `rescue_from.log` | `tags.request_id` = the capture line's `request_id` = the lograge line's |
| 2.3.1: `POST /forms` with no CSRF token. `ActionController::Base`'s default check runs before the gem's hook, and a `rescue_from InvalidAuthenticityToken` handler reports both ways. The app takes it off sentry-rails' `excluded_exceptions` for this case. | `rescue_from_csrf.envelope` | `rescue_from_csrf.log` | `tags.request_id` = the capture line's `request_id`; no trace on either |

For the request and the job, `tags.koderift_trace_id` and `tags.koderift_span_id`
equal the gem line's `trace_id` and `span_id`. `contexts.trace.trace_id` is
still Sentry's own trace. Koderift's `SentryEventMapper` reads that today, so
linking SDK errors to Koderift traces needs the mapper to prefer the tags.
`sentry_bridge_fixtures_spec.rb` checks these keys.

Before they were copied here, the files were normalised by a deterministic
script:

* Local paths became `/app/...`, `/gems/...` and `/usr/local/ruby/...`.
* The host name became `web-1`.
* `contexts.os` was replaced with fixed values.

`server_name` (`web-1`), the release (`fixture-2.3.0`) and the DSN (a dummy key
on localhost) were set in the app. Nothing else was changed: IDs, timestamps
and stack traces are as the run produced them.

Koderift's P1-11 fixtures can be refreshed from these. Read through the agent
parser and `SentryEventMapper`, each envelope pairs with exactly one log row
under P1-11's key rule.
