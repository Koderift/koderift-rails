# koderift-rails

Rails instrumentation gem for [Koderift](https://koderift.com) log analytics.

Automatically captures request context, performance data, and error
information — no manual `ApplicationController` changes needed.

## Installation

Requires Ruby >= 2.7 and Rails 7.1-8.x.

Add to your `Gemfile`:

```ruby
gem 'koderift-rails', '~> 1.3'
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
project's Log Analytics settings page in Koderift.

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

## Requirements

* Ruby >= 2.7
* Rails >= 6.1
* lograge >= 0.11
