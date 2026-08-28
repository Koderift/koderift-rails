require_relative 'lib/koderift/rails/version'

Gem::Specification.new do |spec|
  spec.name        = 'koderift-rails'
  spec.version     = Koderift::Rails::VERSION
  spec.authors     = ['Koderift']
  spec.email       = ['support@koderift.com']
  spec.summary     = 'Rails instrumentation for Koderift log analytics'
  spec.description = 'Automatically captures request context, performance ' \
                     'data, and error information for Koderift log analytics.'
  spec.homepage    = 'https://github.com/koderift/koderift-rails'
  spec.license     = 'MIT'

  spec.required_ruby_version = '>= 2.7'

  spec.metadata = {
    'source_code_uri'       => spec.homepage,
    'changelog_uri'         => "#{spec.homepage}/blob/main/CHANGELOG.md",
    'bug_tracker_uri'       => "#{spec.homepage}/issues",
    'rubygems_mfa_required' => 'true'
  }

  spec.files = Dir[
    'lib/**/*',
    'README.md',
    'CHANGELOG.md',
    'LICENSE'
  ]

  spec.require_paths = ['lib']

  spec.add_dependency 'railties', '>= 7.1', '< 9'
  spec.add_dependency 'lograge',  '>= 0.11', '< 2'

  spec.add_development_dependency 'rspec',       '~> 3.12'
  spec.add_development_dependency 'rspec-rails', '~> 7.1'
  spec.add_development_dependency 'rails',       '>= 7.1', '< 9'
end
