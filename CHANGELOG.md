# Changelog

All notable changes to `koderift-rails` are documented here.

This project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
Releases before 1.3.4 were installed from git and were never published to
RubyGems; they are listed for continuity.

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
