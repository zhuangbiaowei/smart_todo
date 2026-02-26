# frozen_string_literal: true

require 'redis'

module SmartTodo
  class Client
    def initialize(redis_url: ENV.fetch('SMART_TODO_REDIS_URL', 'redis://127.0.0.1:6379/0'))
      redis = Redis.new(url: redis_url)
      @service = Service.new(store: Store.new(redis: redis))
    end

    def add_task(**kwargs) = service.add_task(**kwargs)
    def reshape_task(**kwargs) = service.reshape_task(**kwargs)
    def seek_tasks(**kwargs) = service.seek_tasks(**kwargs)
    def report_task(**kwargs) = service.report_task(**kwargs)
    def fetch_task(task_id:) = service.fetch_task(task_id)

    private

    attr_reader :service
  end
end
