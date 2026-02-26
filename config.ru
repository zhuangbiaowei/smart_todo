# frozen_string_literal: true

require 'redis'
require_relative 'lib/smart_todo'

redis = Redis.new(url: ENV.fetch('SMART_TODO_REDIS_URL', 'redis://127.0.0.1:6379/0'))
service = SmartTodo::Service.new(store: SmartTodo::Store.new(redis: redis))

run SmartTodo::HTTP::App.new.tap { |app| app.set :service, service }
