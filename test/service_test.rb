# frozen_string_literal: true

require 'minitest/autorun'
require 'fakeredis/minitest'
require_relative '../lib/smart_todo'

class ServiceTest < Minitest::Test
  def setup
    @redis = Redis.new
    @store = SmartTodo::Store.new(redis: @redis)
    @service = SmartTodo::Service.new(store: @store)
  end

  def test_add_seek_and_report_flow
    root = @service.add_task(title: 'root')
    child = @service.add_task(
      title: 'child',
      parent_id: root['id'],
      dependencies: [root['id']],
      required_skills: ['ruby'],
      priority: 5
    )

    none = @service.seek_tasks(agent_id: 'agent-1', skills: ['ruby'], limit: 2)
    assert_equal 1, none.size
    assert_equal root['id'], none.first['id']

    @service.report_task(task_id: root['id'], agent_id: 'agent-1', result: 'success')

    tasks = @service.seek_tasks(agent_id: 'agent-2', skills: ['ruby'], limit: 2)
    assert_equal child['id'], tasks.first['id']

    @service.report_task(task_id: child['id'], agent_id: 'agent-3', result: 'failed')
    done = @service.report_task(task_id: child['id'], agent_id: 'agent-2', result: 'success')

    assert_equal 'completed', done['status']
    assert_equal 'agent-2', done['actual_executor']
    assert_equal 2, done['reports'].size
  end
end
