# koderift-rails

Rails instrumentation gem for [Koderift](https://koderift.com) log analytics.

Automatically captures request context, performance data, and error
information — no manual `ApplicationController` changes needed.

## Installation

Requires Ruby >= 2.7 and Rails 7.1-8.x.

Add to your `Gemfile`:

```ruby
gem 'koderift-rails', '~> 2.1'
```

Run `bundle install`. Lograge is a dependency of this gem and is installed
with it - you do not need to add it yourself.

## Configuration

Create `config/initializers/koderift.rb`:

```ruby
Koderift::Rails.configure do |config|
  config.project_token = ENV['KODERIFT_PROJECT_TOKEN']

  # Optional: customise how the current user is resolved
  # config.current_user = ->(controller) { controller.current_user }
end
```

Set `KODERIFT_PROJECT_TOKEN` in your environment to the token from your
project's Log Analytics settings page in Koderift. It is the log agent's
ingest secret: keep it out of your repository and your page HTML.

## Browser RUM

To collect Core Web Vitals and JS error counts from real browsers, set your
project's public RUM token (from the Log Analytics setup page; it starts with
`rum_`) and add the meta tag and snippet inside your layout's `<head>`:

```ruby
Koderift::Rails.configure do |config|
  config.project_token = ENV['KODERIFT_PROJECT_TOKEN']
  config.rum_token     = 'rum_...'
end
```

```erb
<%= koderift_rum_meta_tag %>
<script src="https://<your Koderift host>/ingest/rum.js" async defer></script>
```

The meta tag publishes `rum_token` only. It can only send browser RUM data, so
it is safe in page HTML and safe to commit. The gem never renders
`project_token`, and it refuses a `rum_token` equal to it. Without a
`rum_token` the tag renders nothing and the gem logs one warning per process.
Set `config.rum_enabled = false` for API-only apps.

Upgrading from 2.0 or older with RUM in use? Those versions published
`project_token` in the meta tag. Set `rum_token`, deploy, then rotate the
ingest token in Koderift (Log Analytics settings) and update `webhook_url` in
the agent's `agent.yml`. See the [changelog](CHANGELOG.md).

## What it captures

* Controller, action, path, method, status, duration
* DB runtime, view runtime, allocations
* Current user ID
* Request ID, IP address, user agent, referer
* Request params (filtered — passwords, tokens etc removed)
* Top 5 slowest partials with render times
* Top 5 slowest SQL queries
* Last 20 breadcrumbs (ordered partial renders + SQL queries)
* Exception class, message, and cause chain
* Stack traces (requires `keep_original_rails_log: true`)

## Reporting handled errors

Automatic instrumentation only sees what reaches Rails: a request, a Sidekiq
job, or something logged at ERROR. An error your code *handles* — rescued,
retried, degraded gracefully, returned as a 200 — is exactly the kind worth
knowing about, and nothing reports it for you.

```ruby
begin
  sync_contractors
rescue StandardError => e
  Rails.logger.error "contractor sync failed: #{e.class} - #{e.message}"
  Koderift.capture_exception(e)
end
```

`capture_exception` returns an event, or `nil` when nothing was emitted:

```ruby
event_id = Koderift.capture_exception(error)&.event_id
```

Paste that id into the Log Explorer search box to find the event.

### Errors vs. messages

`capture_exception` produces a tracked Error — grouped by exception class and
`component#action`, counted, and resolvable. `capture_message` produces a
searchable log line, and *also* a tracked Error at `:error` or `:fatal`:

```ruby
Koderift.capture_message("cache warm skipped", level: :info)   # Log Explorer only
Koderift.capture_message("panel schema drifted",               # a tracked Error
                         level: :error, name: "PanelSchemaDrift")
```

`name:` is what separates one message group from another. Without it, every
unnamed error-level message from the same place groups together — deliberately,
because grouping on the message text itself would either mint a new Error per
interpolated value or collapse unrelated messages into one bucket.

`:warn` and `:info` messages never become tracked Errors; they are searchable in
the Log Explorer.

### Context

```ruby
Koderift.capture_exception(e,
  tags:  { region: "eu-west" },
  extra: { order_id: order.id },
  user:  { id: current_user.id, email: current_user.email })
```

Anything matching `config.filter_params` is stripped at every depth, as are the
keys `controller`, `method` and `job_class` (they collide with how the log agent
identifies request and job lines).

### Scope, breadcrumbs and custom spans

```ruby
Koderift.set_user(id: current_user.id)
Koderift.set_tag(:tenant, current_tenant.slug)
Koderift.with_scope { |scope| scope.set_tag(:step, "import") }

Koderift.add_breadcrumb(Koderift::Breadcrumb.new(category: "payment",
                                                 message: "charging card"))

Koderift.with_child_span(op: "stripe", description: "charge") do |span|
  span.set_data(:amount, 500)
  gateway.charge!
end
```

Scope is per-thread and reset at the end of every request and job. Breadcrumbs
interleave with the SQL and render crumbs the gem already collects. A child span
becomes a `custom` span in the APM trace, next to the SQL and HTTP spans.

### Rake tasks and cron

Uncaught rake failures are captured automatically — no task changes needed. This
matters because a task that raises writes to STDERR, which under cron goes to a
mail spool or `/dev/null`, so it was previously invisible.

To trace a task as a unit of work, wrap it:

```ruby
Koderift.start_transaction(name: "ringley_panel:sync_recent_contractors", op: "rake") do
  sync_contractors
end
```

Its queries, outbound HTTP calls and custom spans then render as one trace.
Prefer this block form: `start_transaction` without a block returns a
transaction you must `finish` yourself, and an abandoned one leaves notification
subscribers attached to the process.

### Configuration

```ruby
Koderift::Rails.configure do |config|
  config.max_captures_per_minute = 100          # nil to disable the cap
  config.sample_rate             = 1.0
  config.excluded_exceptions     = %w[ActiveRecord::RecordNotFound]
  config.before_send             = ->(payload, hint) { payload }   # nil to drop
end
```

A capture never raises, and drops are never silent — the rate limiter says on
the log when it starts dropping and how many it dropped.

## Migrating from Sentry

Replace the `Sentry` namespace with `Koderift`; the call sites keep working.

| Sentry | Koderift |
| --- | --- |
| `Sentry.capture_exception(e, **opts, &blk)` | `Koderift.capture_exception` |
| `Sentry.capture_message(msg, **opts, &blk)` | `Koderift.capture_message` |
| `Sentry.capture_event(event)` | `Koderift.capture_event` |
| `Sentry.last_event_id` / `initialized?` | same |
| `Sentry.configure_scope` / `with_scope` | same |
| `Sentry.set_user` / `set_tags` / `set_tag` / `set_extras` / `set_extra` / `set_context` | same |
| `Sentry.get_current_scope` | same |
| `Sentry.add_breadcrumb` / `Sentry::Breadcrumb` | `Koderift.add_breadcrumb` / `Koderift::Breadcrumb` |
| `Sentry.start_transaction` / `with_child_span` | same |
| `Sentry.exception_captured?` | same |
| `Sentry.init { |c| ... }` | `Koderift::Rails.configure { |c| ... }` |
| `config.before_send` / `sample_rate` / `excluded_exceptions` | same |

Capture options are the same: `level:`, `tags:`, `extra:`, `user:`, `contexts:`,
`fingerprint:`, `backtrace:`, `hint:`, and `message:` on `capture_exception`.
Levels accept Sentry's names — `:warning` and `:debug` fold to `warn` and `info`.

`fingerprint:` is honoured by synthesising a grouping class, so
`fingerprint: %w[stripe timeout]` reports as `StripeTimeout: Net::ReadTimeout: ...`.

### Not provided

These have no stub: a method either does something real or is absent, so you
find out at migration time rather than from a silent no-op.

| Sentry | Why |
| --- | --- |
| `capture_check_in` | Cron *monitors* — alerting when a job never runs. Cron errors and slowness are covered (above); detecting an absence needs schedule definitions Koderift does not have yet. |
| `close`, `clone_hub_to_current_thread`, `with_session_tracking` | Nothing to do behind them: captures are written synchronously with no in-process buffer, and all state is already thread-local. |
| `get_traceparent`, `get_baggage` | Distributed tracing works, via the `X-Koderift-Trace-ID` header this gem already propagates. |
| Profiling, release health | Configured inside `Sentry.init` with no call sites, so nothing to replace. Release comparison is on the Koderift deploy-impact view, keyed by the agent's `app_version`. |

## Requirements

* Ruby >= 2.7
* Rails 7.1-8.x
* lograge >= 0.11
* koderift-agent >= 1.4.0 for manual captures to reach the Log Explorer
  (older agents ship them as raw log lines only)
