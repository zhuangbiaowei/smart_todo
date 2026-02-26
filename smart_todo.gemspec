# frozen_string_literal: true

require_relative 'lib/smart_todo/version'

Gem::Specification.new do |spec|
  spec.name          = 'smart_todo'
  spec.version       = SmartTodo::VERSION
  spec.authors       = ['Smart Todo Team']
  spec.email         = ['dev@example.com']

  spec.summary       = 'Redis-backed multi-agent todo orchestration toolkit'
  spec.description   = 'A Ruby gem and HTTP API for hierarchical, dependency-aware task orchestration across many agents.'
  spec.homepage      = 'https://example.com/smart_todo'
  spec.license       = 'MIT'

  spec.required_ruby_version = '>= 3.1'

  spec.files         = Dir.glob('{bin,lib}/**/*') + %w[README.md LICENSE config.ru]
  spec.bindir        = 'bin'
  spec.executables   = ['smart_todo_server']
  spec.require_paths = ['lib']

  spec.add_dependency 'json', '>= 2.6'
  spec.add_dependency 'rackup', '>= 2.1'
  spec.add_dependency 'redis', '>= 5.0'
  spec.add_dependency 'sinatra', '>= 3.0'
  spec.add_dependency 'webrick', '>= 1.8'
end
