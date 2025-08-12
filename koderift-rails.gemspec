require_relative 'lib/koderift/rails/version'

Gem::Specification.new do |spec|
  spec.name        = 'koderift-rails'
  spec.version     = Koderift::Rails::VERSION
  spec.authors     = ['Koderift']
  spec.email       = ['hello@koderift.com']
  spec.summary     = 'Rails instrumentation for Koderift log analytics'
  spec.description = 'Automatically captures request context, performance ' \
                     'data, and error information for Koderift log analytics.'
  spec.homepage    = 'https://github.com/koderift/koderift-rails'
  spec.license     = 'MIT'

  spec.required_ruby_version = '>= 2.7'

  spec.files = Dir[
    'lib/**/*',
    'README.md',
    'LICENSE'
  ]

  spec.require_paths = ['lib']

  spec.add_dependency 'railties', '>= 7.1'
  spec.add_dependency 'lograge',  '>= 0.11'

  spec.add_development_dependency 'rspec',       '~> 3.12'
  spec.add_development_dependency 'rspec-rails', '~> 7.1'
  spec.add_development_dependency 'rails',       '>= 7.1'
end
