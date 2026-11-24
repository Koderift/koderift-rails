# koderift-rails

Rails instrumentation gem for [Koderift](https://koderift.com) log analytics.

Automatically captures request context, performance data, and error
information — no manual `ApplicationController` changes needed. Controllers
that inherit from `ActionController::Base` and from `ActionController::API`
are both covered (the second needs 2.1.2 or newer).

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
* Trace ID, span IDs and start offsets (see [Distributed tracing](#distributed-tracing))
* Request params (filtered — passwords, tokens etc removed)
* Top 5 slowest partials with render times
* Top 5 slowest SQL queries
* Last 20 breadcrumbs (ordered partial renders + SQL queries)
* Exception class, message, and cause chain
* Stack traces (requires `keep_original_rails_log: true`)

## Distributed tracing

The gem continues a trace that reaches your app and passes it on. There is
nothing to configure.

Incoming requests continue the first usable trace header, in this order:

1. `X-Koderift-Traceparent`: the gem's own copy, sent by another app running
   koderift-rails 2.2 or later
2. `traceparent`: W3C Trace Context, sent by OpenTelemetry, recent Sentry SDKs
   and other tracing tools
3. `sentry-trace`: sent by Sentry SDKs, including the browser SDK
4. `X-Koderift-Trace-ID`: sent by koderift-rails before 2.2 (a UUID)

A Koderift trace ID wins whenever it disagrees with `traceparent` or
`sentry-trace`, because nothing else sets it. That keeps a caller on an older
version linked when it also runs Sentry or an APM; its requests sit under the
trace's root, since the older header carries no parent span. With none of the
headers, the request starts a new trace. A malformed header is ignored.

Outbound Net::HTTP calls carry the trace on:

* `traceparent` names the call's own span as the parent (or the span around the
  call, when the call itself is not recorded), and any `tracestate` that came in
  with the trace goes with it. If the request already has a
  `traceparent`, set by OpenTelemetry, Datadog, New Relic, a Sentry SDK or your
  own code, the gem leaves it alone, so it works alongside those tools.
* `X-Koderift-Traceparent` carries the same context in a header those tools
  don't touch. When one of them rewrites `traceparent`, a Koderift app
  downstream still nests under the exact call that reached it, which is why
  this header comes first above.
* `X-Koderift-Trace-ID` carries the trace ID alone, for apps on older versions.

Only Net::HTTP, and clients built on it such as Faraday's default adapter,
sends these headers. They go to every host your app calls, including
third-party APIs; trace and span IDs are random, but an incoming `tracestate` is
passed on as received.

Sidekiq jobs enqueued inside a request, job or transaction carry its trace.
The job's line shares the trace ID and names the span that enqueued it as its
parent. That includes `perform_in` (the trace is stored when the job is
scheduled), bulk pushes and ActiveJob on the Sidekiq adapter. A job that
already carries a trace keeps it, so a retry stays in its original trace. On
Rails 7.2, an ActiveJob enqueued inside a database transaction is pushed at
commit, so its parent is the span open then. A job that enqueues itself stays in
the trace it started in.

In the log lines, every request, job and transaction line has a `trace_id`
(32 hex), its own `span_id`, a `started_at` time, and a `parent_span_id` when
the trace came from a caller. Every span has a `span_id` and, unless its start
cannot be placed inside the unit, a `start_ms` offset; a span inside a
`with_child_span` block names that block as its `parent_span_id`.

New traces are marked sampled, so a downstream service using OpenTelemetry's
parent-based sampler records the calls your app makes to it.

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

With sentry-ruby initialised as well (and a project token set), each rake run
outside the long-running worker tasks gets a request ID, which both reports of
a failure carry (see [Using with sentry-ruby](#using-with-sentry-ruby)).

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
To keep sentry-ruby running beside this gem instead, see
[Using with sentry-ruby](#using-with-sentry-ruby).

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
| `get_traceparent`, `get_baggage` | Trace context is read and sent automatically (see [Distributed tracing](#distributed-tracing)); there is no call to read it. |
| Profiling, release health | Configured inside `Sentry.init` with no call sites, so nothing to replace. Release comparison is on the Koderift deploy-impact view, keyed by the agent's `app_version`. |

## Using with sentry-ruby

You can run sentry-ruby, with sentry-rails and sentry-sidekiq, beside this
gem. Both keep reporting: the gem keeps writing its log lines, so your logs stay
complete and searchable, and Sentry keeps sending its events. Koderift counts an
error that reaches it both ways once. It pairs the Sentry event with the gem's
line when the two share a key (the jid, else the request ID) and the same
exception class.

`Koderift.capture_exception` and `capture_message` are never forwarded to
Sentry. Forwarding would only add a second Sentry report beside sentry-ruby's
own integrations.

When sentry-ruby is initialised, and this gem is enabled with a project token,
Sentry's error events get these tags:

| Tag | Value |
| --- | --- |
| `request_id` | Added only when Sentry has none. sentry-rails sets it inside a request. For a Sidekiq job it is the jid, and in a rake run the run ID (below). |
| `koderift_trace_id` | The trace of the gem's line for the same request or job. |
| `koderift_span_id` | That line's span. For a capture made inside a `with_child_span` block, it is that block's span. |

A tag that is already set is never overwritten. At most three tags are added,
never taking an event past 50. Check-ins and transactions are left as they are.

sentry-rails reports a request's exception from Rack middleware, and
sentry-sidekiq reports a job's failure from Sidekiq's error handlers. Both run
after the gem has finished with that request or job, so the trace comes from
where the gem left it.

* **Requests.** The gem reads the trace from the request Sentry is reporting
  (its Rack env, where the controller stores it), and only when that request's
  ID is the event's request ID. This covers `ActionController::Live` actions.
  A request that fails before the controller runs (in a middleware, or a
  `prepend_before_action`) has no trace there and gets none, even if a client
  reused the ID of an earlier request.
* **Jobs.** The gem keeps the IDs of the job that last finished on each thread,
  and uses them only when the event's jid names that job and Sentry reports on
  the hub the job ran on. sentry-sidekiq gives every attempt its own hub, so a
  retry that fails before it reaches the gem's middleware never takes the
  previous attempt's trace. Each Sidekiq thread keeps its own, so concurrent
  threads never see each other's.

An event whose key names another request or job gets no tags.

**Rake.** Each rake run gets one request ID, a UUID. Three things carry it:

* the gem's capture line for an uncaught failure;
* any other capture made during the run outside a request, job or transaction;
* Sentry's rake event.

So a rake failure reported both ways counts once. A task invoked twice in one
process keeps the same ID, and so do threads the task starts. Jobs the task
enqueues keep their own jid.

A run that includes a long-running worker task gets no run ID: one ID for weeks
of unrelated errors would pair errors that are not the same occurrence. The
worker tasks are `jobs:work`, `jobs:workoff`, `resque:work`, `resque:workers`,
`resque:scheduler`, `solid_queue:start`, `sneakers:run`, `qc:work`, `que:work`,
and Backburner's `backburner:work` and `backburner:<strategy>:work` tasks. Add
your own:

```ruby
Koderift::Rails.configure do |config|
  config.rake_worker_tasks += %w[mailroom:poll]
  # config.sentry_bridge = false   # leave Sentry's events exactly as Sentry builds them
end
```

Limits:

* An event with no request ID or jid of its own, captured after its request or
  job has finished, gets no tags.
* A capture inside `Koderift.start_transaction` carries the transaction's own
  request ID, not the request's or job's.
* `Koderift.capture_exception` inside a `rescue_from` handler runs after the
  request's context has closed, so its line has no `request_id`. Sentry's event
  from the same handler has one, so that pair still counts twice.
* Under Spring, a rake command usually computes its run ID in the forked
  command, but if the preloaded app worked it out first, every command it forks
  goes without one.
* sentry-ruby keeps one hub per thread unless told otherwise (5.x always
  does). On a fiber-per-request server such as Falcon, concurrent requests
  then share it, and Sentry can report one request's error with another
  request's env and request ID; the bridge then adds that request's trace too.
  Set sentry-ruby's `config.hub_isolation_level = :fiber` there (7.x, Ruby 3.2+).
* With `:fiber`, a pooled thread started during a request keeps that
  request's Sentry scope (Rails 8.0+ runs `ActionController::Live` actions on
  such a pool). Sentry can then report later errors on that thread under the
  earlier request's ID, and the bridge may add that request's trace.

The gem never requires sentry-ruby. Without it, or with it loaded but not
initialised, nothing changes. Tested with sentry-ruby 7.3.0 and 5.22.4, and with
sentry-rails and sentry-sidekiq 7.3.0 in a Rails 8.1 app.

## Requirements

* Ruby >= 2.7
* Rails 7.1-8.x
* lograge >= 0.11
* koderift-agent >= 1.4.0 for manual captures to reach the Log Explorer
  (older agents ship them as raw log lines only)
