# Changelog

All notable changes to `koderift-rails` are documented here.

This project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
Releases before 1.3.4 were installed from git and were never published to
RubyGems; they are listed for continuity.

## [2.2.0] - 2026-11-22

Distributed tracing with W3C Trace Context. Traces now link with OpenTelemetry,
Sentry and browsers, spans nest, and a request's trace continues into the
Sidekiq jobs it enqueues.

### Added
- Incoming requests continue a trace from `X-Koderift-Traceparent`, then a W3C
  `traceparent`, then Sentry's `sentry-trace`, then the older
  `X-Koderift-Trace-ID`. A Koderift trace ID wins whenever it disagrees with
  `traceparent` or `sentry-trace`, because nothing else sets it. With none of
  them a request starts a new trace. A malformed header is ignored.
- Outbound Net::HTTP calls send `traceparent`, naming the call's own span as the
  parent, and any `tracestate` that arrived with the trace. A call that is not
  recorded (to a loopback or ignored host, or made outside a request, job or
  transaction) names the span around it instead. They also send the
  same context in the gem's own `X-Koderift-Traceparent` header. A `traceparent`
  already on the request (set by OpenTelemetry, Datadog, New Relic, a Sentry SDK
  or your code) is never overwritten. Those tools rewrite `traceparent` but not
  the Koderift header, so a Koderift app downstream still nests under the exact
  call. `X-Koderift-Trace-ID` is still sent, now with the 32-hex trace ID, for
  apps on older versions.
- Sidekiq client middleware. A job enqueued inside a request, job or
  transaction carries its trace (`koderift_traceparent`, plus
  `koderift_trace_id` for servers on older versions). The job's line shares the
  request's trace ID and names the enqueuing span as its parent. This covers
  `perform_async`, `perform_in`, bulk pushes and ActiveJob on the Sidekiq
  adapter. A job that already carries a trace keeps it, so retries and
  scheduled jobs stay in the trace they were enqueued in.
- Every span has a `span_id` and a `start_ms` (milliseconds from the start of
  its request, job or transaction). `start_ms` is left out in the rare case a
  start time cannot be placed inside its unit. Spans inside a `with_child_span` block also
  have a `parent_span_id`. A span without one belongs to the line's root span.
- Request, job and transaction lines gain `span_id` (their root span),
  `parent_span_id` (the caller's span, when the trace came from one) and
  `started_at` (UTC ISO-8601 with milliseconds). Manual captures gain `span_id`.
- A transaction started inside a request or job joins its trace, as a child of
  the span open there. Starting a transaction while another one is open on the
  same thread still finishes the open one first, as in 2.1.

### Changed
- Trace IDs are W3C trace IDs, 32 lowercase hex characters, instead of UUIDs. A
  UUID in `X-Koderift-Trace-ID` or a job's `koderift_trace_id` is still
  accepted and normalised (dashes removed, lowercased). A value there that is
  not a UUID is now ignored and a new trace starts; before, any string was used
  as it was.
- Three specs that asserted the UUID format now assert the 32-hex format.

### Fixed
- Each request and job recorded the SQL queries, partial renders and Searchkick
  searches of every other request and job running at the same time in the
  process (multi-threaded Puma, Sidekiq). ActiveSupport::Notifications
  subscribers are process-wide, and the gem's were not limited to their own
  thread. Each unit now records only its own. Per-request query counts may drop
  slightly after you upgrade, because other threads' queries are no longer
  included. Queries a request runs on threads or fibers it starts itself
  (Concurrent::Promises, Parallel, `Enumerator#next`, Async tasks) are no
  longer counted either; `load_async` queries still are.
- A transaction started inside a request no longer stops the request recording
  HTTP calls, custom spans and manual breadcrumbs once it finishes. Its queries
  now appear on the transaction's line only, not on both lines.
- A non-block transaction left unfinished can no longer leak into a later
  request on the same thread. Before, finishing it there restored the earlier
  request's trace ID and capture context, so later manual captures carried the
  earlier request's ID and user. The abandoned transaction's own line, written
  when the next transaction starts, still picks up that later request's path,
  method, user and tags, as in 2.1.
- A job run with `perform_inline` inside another job no longer clears that
  job's trace and capture context. Its Koderift scope (tags and user set with
  `set_tag` and `set_user`) is still reset, as before.
- An exception inside one of the gem's notification callbacks can no longer
  fail the query or render being instrumented.
- On Rails 7.1.0-7.1.3, `load_async` queries reported durations 1000 times too
  long.

### Notes
- No configuration needed.
- Older Koderift app and agent versions ignore the new keys until the Koderift
  app update that uses them. Services on older gem versions store UUID trace IDs
  with dashes and 2.2.0 stores 32 hex, so traces across mixed versions link once
  that update normalises stored trace IDs.
- A caller on an older gem version that also runs Sentry, OpenTelemetry,
  Datadog or New Relic sends that tool's trace header next to its Koderift
  trace ID. A 2.2 service follows the Koderift trace ID, so the trace still
  links, but the older header carries no parent span, so those requests sit
  under the trace's root until the caller upgrades.
- A job that enqueues itself (for example with `perform_in` at the end of
  `perform`) stays in the trace it started in, so a self-scheduling job builds
  one ever-growing trace.
- Span-heavy requests grow slightly in logged bytes: each span gains about 45
  bytes (`span_id`, `start_ms`), and a span nested in a `with_child_span` block
  about 35 more (`parent_span_id`).
- A Sentry browser SDK keeps one trace ID for a whole page, so every request a
  page makes now shares a trace ID and they appear together in Koderift's
  cross-service trace view.
- New traces are sent as sampled (`01`), and a `sentry-trace` without a sampled
  flag is read as sampled. A downstream service using OpenTelemetry's
  parent-based sampler therefore records the calls it receives from your app.
- Only Net::HTTP, and clients built on it such as Faraday's default adapter,
  sends trace headers. They go to every host your app calls, including
  third-party APIs. Trace and span IDs are random, but an incoming `tracestate`
  is passed on as received.
- A call that raises (a timeout, a refused connection) records no span, so the
  service it reached may name a parent span that is not in your trace.
- On Rails 7.2, an ActiveJob enqueued inside a database transaction is pushed
  when the transaction commits, so its parent is the span open at commit.

## [2.1.2] - 2026-11-19

Fixes missing request detail for controllers that inherit from
`ActionController::API`.

### Fixed
- Controllers that inherit from `ActionController::API` are now instrumented,
  not just those that inherit from `ActionController::Base`. That covers every
  controller in an API-only app, and API namespaces in a normal app.
  `ActionController::API` is a separate base class, not a subclass of
  `ActionController::Base`, so before this fix their requests were never
  instrumented. Lograge still logged each request with its duration, DB and
  view time and status. But the line had no SQL, partial, search or HTTP
  spans, no breadcrumbs, params, user, IP, user agent or trace ID. In Koderift
  their traces showed the whole request as Ruby time with nothing to explain
  it.

### Notes
- Requests logged before you upgrade keep the missing detail. It was never
  collected.
- If your API base controller fills Koderift's fields itself, through
  `append_info_to_payload` or by including `Koderift::Rails::Controller`, you
  can remove that after upgrading. Leaving it in does no harm. The concern runs
  once per request, and an override that calls `super` gets the gem's fields
  first.

## [2.1.1] - 2026-11-12

Fixes missing request data in apps where another gem defines `Object#logger`.

### Fixed
- Request data no longer goes missing when another gem defines a public
  `logger` method on every object. data-anonymization does this when it
  is loaded at boot. That method shadowed `config.lograge.logger`, so lograge
  took the other gem's logger. The Koderift JSON request line went to STDOUT
  instead of the log the agent tails, and nothing warned. At boot the gem now
  points lograge back at what your app configured (`Rails.logger`, unless you
  set `config.lograge.logger`), and logs one warning naming the module and file
  that define the method.

### Notes
- The same method usually redirects `ActionController::Base.logger`,
  `ActiveRecord::Base.logger` and Rails' own "Processing by", "Completed" and
  SQL lines too. Koderift does not change those. Fix them by not loading that
  gem at boot, for example `gem 'data-anonymization', require: false`.
- If that gem also defines `logger=` (data-anonymization does), a
  `config.lograge.logger` you set was handed to the gem and never reached
  lograge, so lograge now uses `Rails.logger`.

## [2.1.0] - 2026-11-06

Security fix: the Browser RUM meta tag no longer publishes your project token.

### Security
- `koderift_rum_meta_tag` used to render `config.project_token` into page HTML.
  That token is the log agent's ingest secret, so anyone reading your page
  source could use it to send log lines to your Koderift project, including
  lines that count against its log quota. The tag now renders only the new
  `config.rum_token`, a public token that can only send browser RUM data.
- If you rendered the RUM tag on 2.0 or older, treat your project token as
  public. Once this version is deployed with `rum_token` set, rotate the ingest
  token in Koderift (Log Analytics settings, "Rotate ingest token"), then update
  `webhook_url` in the agent's `agent.yml` and `KODERIFT_PROJECT_TOKEN` in your
  app, and restart the agent.

### Added
- `config.rum_token`: your project's public RUM token, from the Log Analytics
  setup page in Koderift. It starts with `rum_`.

### Changed
- **Action needed if you use Browser RUM:** set `config.rum_token`. Without it
  the meta tag renders nothing, and the gem logs one warning per process the
  first time a page renders it. There is deliberately no fallback to
  `project_token`. The tag also refuses a `rum_token` equal to `project_token`.

### Notes
- Koderift keeps accepting RUM data sent with the old token until
  1 February 2027, so pages not yet upgraded keep reporting until then.
- `project_token` is still required to turn the gem on. The gem never sends it
  anywhere; the log agent uses its own copy in `agent.yml`.

## [2.0.0] - 2026-11-04

Manual error reporting, with a Sentry-compatible API.

Requires koderift-agent >= 1.4.0. Against an older agent, captures still reach
Raw Logs but not the Log Explorer or the Errors page.

### Added
- `Koderift.capture_exception` and `Koderift.capture_message` for reporting
  errors your code already handles. `capture_exception` returns an event with an
  `event_id`, or nil when nothing was emitted.
- Scope (`configure_scope`, `with_scope`, `set_user`, `set_tags`, `set_tag`,
  `set_extras`, `set_extra`, `set_context`), breadcrumbs
  (`add_breadcrumb`, `Koderift::Breadcrumb`), and `exception_captured?`.
- Custom instrumentation: `with_child_span` records a span that renders in the
  APM trace beside the SQL and HTTP spans, and `start_transaction` traces work
  that is neither a request nor a Sidekiq job — a rake task or cron script.
- Uncaught rake task failures are now captured automatically. Previously a task
  that raised wrote only to STDERR, which under cron is never in the Rails log,
  so those failures were invisible.
- Configuration: `max_captures_per_minute` (default 100), `sample_rate`,
  `before_send` and `excluded_exceptions`.

### Fixed
- Sidekiq jobs enqueued through ActiveJob are reported under their own class
  (`job["wrapped"]`, as Sidekiq logs them) instead of the adapter's wrapper,
  which filed every ActiveJob under one `Sidekiq::ActiveJob::Wrapper` row.

### Notes
- Captures appear under a new `manual` log source, and are excluded from the
  APM request aggregates by it, so they cannot skew throughput, p95 or Apdex.
- The gem does not define `Sentry`. Migration is a namespace find-and-replace;
  see the README for the full mapping and the short list of Sentry APIs with no
  Koderift equivalent.

## [1.3.4] - 2026-08-27

First release published to RubyGems.

### Fixed
- An external HTTP call could be recorded twice on a single request, inflating
  the external-call count and the time attributed to it.

### Changed
- Packaging only: added a LICENSE file, gem metadata (source, changelog and
  issue links, MFA required for publishing) and this changelog. No change to
  what the gem captures or emits.

## [1.3.3] - 2026-05-25
### Added
- The current Rails environment is emitted with each request, so traces can be
  filtered by environment rather than inferring it from the host.

## [1.3.2] - 2026-05-25
### Changed
- Improved internal logging.

## [1.3.1] - 2026-05-25
### Added
- External HTTP calls made from Sidekiq jobs are tracked, not just those made
  during a web request.

## [1.3.0] - 2026-05-25
### Changed
- Removed the per-request limits on captured spans; the full set is emitted and
  trimmed downstream by the ingest agent.

## [1.2.2] - 2026-05-25
### Fixed
- Maintenance release.

## [1.2.1] - 2026-05-24
### Fixed
- Searchkick instrumentation issue reported by a client.

## [1.2.0] - 2026-05-24
### Added
- Search query instrumentation (`search.searchkick` and
  `multi_search.searchkick`).

## [1.0.6] - 2026-05-24
### Added
- RUM token support.

## [1.0.5] - 2026-05-24
### Added
- Browser RUM instrumentation.

## [1.0.4] - 2026-05-24
### Added
- Distributed tracing: a trace id is propagated across services via the
  `X-Koderift-Trace-ID` header.

## [1.0.3] - 2026-05-23
### Added
- External HTTP call tracking via a `Net::HTTP` patch.

## [1.0.2] - 2026-05-22
### Fixed
- Maintenance release.

## [1.0.1] - 2025-12-10
### Fixed
- Load-order issue when the gem initialised before Lograge.

## [1.0.0] - 2025-08-11
### Added
- Initial release: request instrumentation, partial and SQL span capture,
  breadcrumbs, and automatic Lograge configuration.
