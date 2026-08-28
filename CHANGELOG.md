# Changelog

All notable changes to `koderift-rails` are documented here.

This project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
Releases before 1.3.4 were installed from git and were never published to
RubyGems; they are listed for continuity.

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
