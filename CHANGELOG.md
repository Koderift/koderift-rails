# Changelog

All notable changes to `koderift-rails` are documented here.

This project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
Releases before 1.3.4 were installed from git and were never published to
RubyGems; they are listed for continuity.

## [2.4.1] - 2026-11-24

### Fixed
- A second controller dispatched on the same request env, such as an
  `exceptions_app` error page, no longer takes the first controller's
  `trace_id`, `span_id`, `parent_span_id` and `started_at` when the gem's hook
  did not run for it (a `prepend_before_action` or CSRF failure, or a skipped
  hook). Its request line, and the captures in its `rescue_from` handler, now
  carry no trace, as for any request whose hook never ran. Before, its line
  pointed at the first line's span, so a join of spans to lines could count the
  first request's spans twice. Each dispatch now reads its trace from its own
  request object. The env keys are unchanged, and the sentry-ruby bridge still
  reads them.

### Development
- Specs for both cases in `spec/koderift/rails/errored_units_spec.rb`.

## [2.4.0] - 2026-11-24

A request or job that raises keeps what it recorded before the raise, so its
trace shows the queries that led to the error.

### Fixed
- The request line of an action that raised carries its `spans`,
  `query_count`, `partial_count`, `search_count` and `breadcrumbs` up to the
  raise, whether a `rescue_from` handler took the error or not. Before, it had
  none of them, so the counts were stored as 0. The caps are the same as on a
  successful request. Queries and renders in the handler itself are not
  recorded, as before.
- A failed Sidekiq job's line carries that attempt's spans, counts and
  breadcrumbs. Before, it reported none and counts of 0. Its keys are
  unchanged.
- A capture in a `rescue_from` handler carries the action's breadcrumbs up to
  the raise, then the handler's own, capped at `max_breadcrumbs`.
  `before_send` sees all of them. A handler that clears breadcrumbs clears them
  from its captures, not from the request line. There are none of the action's
  for an exception raised after the gem's hook has finished, and a controller
  run inside a Sidekiq job keeps the job's trail, as in 2.3.1.
- A failure inside the gem while it starts or stops a request's or job's
  capture, or builds its result, no longer fails a request or job that
  succeeded, and never replaces the exception of one that failed. Without a
  result the line goes out without spans.
- `config.max_breadcrumbs` set to `nil` or `Float::INFINITY` (no cap), or to a
  String such as `"20"`, no longer makes every request and job fail, nor drops
  transaction lines. A value that is not a number falls back to 20. Zero or
  less keeps none, as zero always did. Breadcrumbs added outside a request or
  job are trimmed by the same rule.
- Spans and breadcrumbs are no longer left in `request.env`, where tools that
  dump the env (exception_notification) printed them, SQL literals included.
  Only the trace keys stay there.
- `Scope#clear_breadcrumbs` empties the trail of the innermost running
  request, job or transaction in place. Crumbs an action clears no longer go
  out on its request line, and SQL recorded after the clear still reaches
  captures. Before, the cleared crumbs stayed on the line, and later SQL never
  reached captures.
  - Unlike sentry-ruby, a clear inside `with_scope` or a capture block clears
    that trail too, not only the one event's.
  - A clear inside a transaction, an inline job or a handler clears that
    unit's trail and leaves the request line's.
- A capture's breadcrumbs are capped at `max_breadcrumbs`, as the request
  line's are. Before, a capture late in a long action carried every SQL crumb.
- The keys `controller`, `method`, `job_class` and `koderift_capture` are
  dropped from a breadcrumb's `data` (Hashes and Arrays, at any depth). The
  first three were already dropped from a capture's context. The Koderift agent
  looks for those keys anywhere in a line, so one inside a crumb could make it
  misread or drop the whole line. Data that refers back to itself no longer
  raises from `add_breadcrumb`.
- `SidekiqMiddleware` returns the job's own value. Before, it returned the
  capture's result, which Sidekiq's `perform_inline` checks.

### Added
- `rescued` on the request line when a `rescue_from` handler took the
  exception: the exception's class. When a handler passes another error to
  `rescue_with_handler`, the outermost one is named. An explicit
  `rescue_with_handler` called inside the action adds nothing.

### Changed
- An errored line is larger. In a test app, without the stack trace, it was
  about 1.9 KB with 5 queries, 10.5 KB with 50 and 78 KB with 500, against
  about 0.4 KB before. Longer SQL makes it larger. A failed job writes one line
  for each attempt.
- Successful request and job lines are unchanged, except for the
  breadcrumb fixes above.
- A request that ends in `throw` instead of an exception, such as Warden's 401
  from Devise's `authenticate_user!`, carries the spans, counts and breadcrumbs
  it recorded before the throw, as an action that raised does. Rails logs no
  status for these, as before.
- A `before_send` that edits breadcrumb Hashes in place also edits the request
  line written after it, as before. That now includes a handler's captures on
  an errored request.

### Development
- `spec/koderift/rails/errored_units_spec.rb`.

## [2.3.1] - 2026-11-24

Captures in `rescue_from` handlers keep their request, so an error a handler
reports both ways counts once.

### Fixed
- `Koderift.capture_exception` and `capture_message` in a controller's
  `rescue_from` handler carry the request's `request_id`, `component`, `action`,
  `path`, `http_method` and user, and the `trace_id` and `span_id` its request
  line carries, as a capture in the action does. Rails runs the handler after
  the gem has finished with the request, so these captures used to have none of
  them. Sentry's event from the same handler has the request ID, so that pair
  counted twice.
  - This covers handlers on a parent controller, in a concern, on
    `ActionController::API` and in `ActionController::Live` controllers. It
    also covers a handler found through the exception's cause, and a handler
    that calls `rescue_with_handler` itself.
  - When the action, or a callback inside the gem's hook, raised, the handler
    sees the scope the action had: `Koderift.set_user`, tags and extras set in
    the action or its callbacks.
  - A transaction started in the handler carries its own context inside it, as
    in an action.
  - Some exceptions are raised before the gem's hook runs: Rails' default CSRF
    check, a `prepend_before_action`, or a controller that skips the hook. For
    those the capture has the request ID and user and no trace, as the request
    line does.
- A tag, user or breadcrumb set in a `rescue_from` handler no longer reaches
  the next request served by the same thread.
- A non-block transaction a handler starts and never finishes has its frames
  dropped when the handler ends, as one the action leaves open does at the end
  of the request. Before, a later `start_transaction` on the thread could cut
  the next request's context and trace short. The abandoned transaction's own
  line is still written when a later one finishes it.
- A transaction an earlier request left open, finished from a later request's
  `rescue_from` handler, takes none of that request's user, path or scope.

### Changed
- With the sentry-ruby bridge, a Sentry event captured in a `rescue_from`
  handler with no `request_id` of its own (no Rack env) gets the request's
  `request_id`, and, when the request line has a trace, its
  `koderift_trace_id` and `koderift_span_id`. Events that carry sentry-rails'
  `request_id` get the same tags as before.
- A handler in a controller that a Sidekiq job dispatches in-process keeps the
  job's context, as before. sentry-sidekiq tags every event in the job with its
  jid, which Koderift pairs on first, so the handler's report still pairs.
- Errors reported from `rescue_from` handlers now group by controller and
  action. Before, every handler report of one exception class shared one group
  with no controller. After the upgrade that group stops growing and one group
  per controller and action appears, which a deploy's impact view shows as new
  errors.
- Rails 8.1: a capture made in a `rescue_from_callback.action_controller`
  subscriber carries the request.
- Request lines are unchanged. On a request a handler took, lograge's
  `allocations` count can be slightly higher.
- Outbound HTTP calls, jobs enqueued and transactions started in a handler
  still don't join the request's trace.

### Development
- `spec/koderift/rails/rescue_from_spec.rb` and
  `spec_sentry/rescue_from_bridge_spec.rb`.
- `spec/fixtures/sentry_bridge/` gains `rescue_from` and `rescue_from_csrf`, a
  Sentry envelope and the log lines for each, from the same Rails 8.1 app on
  2.3.1.

## [2.3.0] - 2026-11-23

Works alongside sentry-ruby. Sentry's error events now carry the keys Koderift
pairs them on, so an error reported both ways counts once, rake failures
included, and an SDK error can be linked to the Koderift trace.

### Added
- **sentry-ruby bridge.** When sentry-ruby is initialised, and this gem is
  enabled with a project token, Sentry's error events gain three tags. Each
  comes from the gem's line for the same request, job or rake run.
  - `request_id`, only when Sentry has none. For a job it is the jid, and in a
    rake run the run ID.
  - `koderift_trace_id`.
  - `koderift_span_id`.

  An app's own tags are never overwritten. At most three are added, never
  taking an event past 50. Check-ins and transactions are left as they are.
- sentry-rails and sentry-sidekiq report after the request or job has
  finished, and their events still get its IDs:
  - A request's IDs come from the Rack env Sentry is reporting, when that
    request's ID is the event's. This covers `ActionController::Live`. A
    request that failed before the controller ran gets none, even under a
    reused `X-Request-Id`.
  - A job's IDs come from the job that last finished on that thread, when the
    event's jid names it and Sentry reports on the hub that job ran on. With
    sentry-sidekiq, which gives every attempt its own hub, a retry that failed
    before reaching the gem's middleware gets none.
  - An event whose key names another request or job gets nothing.
- The bridge registers one Sentry event processor once the app's initializers
  have run, and checks again cheaply at each request, job and rake failure in
  case Sentry is initialised later. It is added back if something clears
  Sentry's processor list, as `Sentry::TestHelper` does. If adding it fails,
  the bridge stays off rather than retrying on every request. An app's own
  autoloadable `Sentry` constant is never loaded by the check.
- The processor never raises, never drops an event and allocates nothing
  beyond the tags it adds.
- `config.sentry_bridge` (default `true`) turns the bridge off.
- The gem never requires sentry-ruby. Without it, or with it loaded but not
  initialised, nothing changes.
- **Rake run ID.** With the bridge active, each rake run gets one request ID, a
  UUID. The capture line for an uncaught failure carries it, and so does
  Sentry's rake event.
- A task invoked twice in one process keeps the same ID, and so do threads the
  task starts.
- A run that includes a long-running worker task gets none. The list is
  `config.rake_worker_tasks`, which defaults to `jobs:work`, `jobs:workoff`,
  `resque:work`, `resque:workers`, `resque:scheduler`, `solid_queue:start`,
  `sneakers:run`, `qc:work`, `que:work`, and Backburner's `backburner:work`
  and `backburner:<strategy>:work`. Task arguments are ignored.
- Tested with sentry-ruby 7.3.0 and 5.22.4.

### Changed
- When the bridge is active, a rake failure's capture line carries a
  `request_id`, the rake run ID. So does any other capture made during a rake
  run outside a request, job or transaction. `before_send` callbacks see it
  too. Without sentry-ruby, capture lines are unchanged.
- `Koderift.capture_exception` and `capture_message` are not forwarded to
  Sentry, and behave exactly as before. Both reporting paths stay on, because
  Koderift counts an error reported both ways once.

### Development
- `bundle exec rspec spec_sentry` runs the bridge's suite with sentry-ruby
  7.3.0. sentry-ruby is a development dependency (`require: false`), never a
  runtime one. The main suite stays free of sentry-ruby and fails if it gets
  loaded.
- `spec/fixtures/sentry_bridge/` holds real envelopes and log lines from a Rails
  8.1 app running sentry-ruby, sentry-rails and sentry-sidekiq 7.3.0, one each
  for a request, a job and a rake run.

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
