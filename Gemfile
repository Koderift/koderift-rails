source 'https://rubygems.org'

gemspec

group :development, :test do
  gem 'rspec', '~> 3.12'
  gem 'rails', '~> 7.1'
  gem 'sqlite3'
  # Specs run real client and server middleware chains through Sidekiq::Testing.
  gem 'sidekiq', '>= 6.5', '< 9'
  # Only the spec_sentry suite loads it (bundle exec rspec spec_sentry). The
  # main suite must run without ::Sentry defined, so it is never required here.
  gem 'sentry-ruby', '7.3.0', require: false
end
