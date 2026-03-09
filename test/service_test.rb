# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../lib/smart_todo/errors'
require_relative '../lib/smart_todo/store'
require_relative '../lib/smart_todo/service'
require_relative 'support/fake_redis'

class ServiceTest < Minitest::Test
  def setup
    @redis = FakeRedis.new
    @store = SmartTodo::Store.new(redis: @redis)
    @service = SmartTodo::Service.new(store: @store)
  end

  def test_add_seek_and_report_flow
    prereq = @service.add_task(title: 'prereq')
    root = @service.add_task(title: 'root')
    child = @service.add_task(
      title: 'child',
      parent_id: root['id'],
      dependencies: [prereq['id']],
      task_type: 'sequential',
      requirements: { 'suggested_tools' => ['editor'], 'skill_instructions' => ['use ruby'] },
      acceptance_criteria: ['tests green'],
      success_criteria: ['api responds 200'],
      failure_criteria: ['contract broken'],
      required_skills: ['ruby'],
      priority: 5
    )

    selected = @service.seek_tasks(agent_id: 'agent-1', skills: ['ruby'], limit: 5)
    assert_equal [prereq['id'], root['id']], selected.map { |t| t['id'] }

    @service.report_task(task_id: prereq['id'], agent_id: 'agent-1', result: 'success')

    tasks = @service.seek_tasks(agent_id: 'agent-2', skills: ['ruby'], limit: 2)
    assert_equal child['id'], tasks.first['id']

    @service.report_task(task_id: child['id'], agent_id: 'agent-3', result: 'failed')
    done = @service.report_task(
      task_id: child['id'],
      agent_id: 'agent-2',
      result: 'success',
      completion_status: 'accepted',
      task_result: { 'artifact' => 'api-v1' },
      execution_logs: ['implemented endpoint', 'verified response']
    )
    root_done = @service.report_task(task_id: root['id'], agent_id: 'agent-1', result: 'success')

    assert_equal 'completed', done['status']
    assert_equal 'agent-2', done['actual_executor']
    assert_equal 2, done['reports'].size
    assert_equal 'sequential', done['task_type']
    assert_equal ['editor'], done.dig('requirements', 'suggested_tools')
    assert_equal ['tests green'], done['acceptance_criteria']
    assert_equal 'accepted', done['completion_status']
    assert_equal({ 'artifact' => 'api-v1' }, done['task_result'])
    assert_equal ['implemented endpoint', 'verified response'], done['execution_logs']
    assert_equal 'completed', root_done['status']
  end

  def test_add_task_with_unknown_parent_raises_not_found
    error = assert_raises(SmartTodo::NotFoundError) do
      @service.add_task(title: 'child', parent_id: 'missing')
    end
    assert_match('not found', error.message)
  end

  def test_reshape_task_updates_parent_and_dependencies
    parent_a = @service.add_task(title: 'parent-a')
    parent_b = @service.add_task(title: 'parent-b')
    dep_a = @service.add_task(title: 'dep-a')
    dep_b = @service.add_task(title: 'dep-b')

    task = @service.add_task(title: 'task', parent_id: parent_a['id'], dependencies: [dep_a['id']])

    reshaped = @service.reshape_task(
      task_id: task['id'],
      updates: { 'parent_id' => parent_b['id'], 'priority' => 9 },
      add_dependencies: [dep_b['id']],
      remove_dependencies: [dep_a['id']]
    )

    assert_equal parent_b['id'], reshaped['parent_id']
    assert_equal 9, reshaped['priority']
    assert_equal [dep_b['id']], reshaped['dependencies']
    assert_equal [task['id']], @store.children(parent_b['id'])
    assert_empty @store.children(parent_a['id'])
  end

  def test_seek_tasks_filters_by_dependency_and_skills_and_priority
    dep = @service.add_task(title: 'dep')
    high = @service.add_task(title: 'high', required_skills: %w[ruby], priority: 10)
    blocked = @service.add_task(title: 'blocked', required_skills: %w[ruby], dependencies: [dep['id']], priority: 100)
    low = @service.add_task(title: 'low', required_skills: %w[ruby], priority: 1)
    _other_skill = @service.add_task(title: 'other', required_skills: %w[go], priority: 99)

    selected = @service.seek_tasks(agent_id: 'agent-1', skills: %w[ruby], limit: 2)
    assert_equal [high['id'], low['id']], selected.map { |t| t['id'] }
    assert_equal 'pending', @service.fetch_task(task_id: blocked['id'])['status']
  end

  def test_list_tasks_filters_by_new_fields
    parent = @service.add_task(title: 'parent')
    @service.add_task(
      title: 'parallel-task',
      parent_id: parent['id'],
      task_type: 'parallel',
      requirements: { 'suggested_tools' => ['browser'] },
      required_skills: ['ruby']
    )
    target = @service.add_task(
      title: 'branch-task',
      task_type: 'branching',
      requirements: { 'suggested_tools' => ['cursor'] },
      required_skills: ['planning']
    )

    @service.report_task(
      task_id: target['id'],
      agent_id: 'agent-x',
      result: 'success',
      completion_status: 'accepted'
    )

    assert_equal [target['id']], @service.list_tasks(filters: { 'task_type' => 'branching' }).map { |task| task['id'] }
    assert_equal [target['id']], @service.list_tasks(filters: { 'actual_executor' => 'agent-x' }).map { |task| task['id'] }
    assert_equal [target['id']], @service.list_tasks(filters: { 'completion_status' => 'accepted' }).map { |task| task['id'] }
    assert_equal [target['id']], @service.list_tasks(filters: { 'suggested_tool' => 'cursor' }).map { |task| task['id'] }
    root_task_ids = @service.list_tasks(filters: { 'parent_id' => 'root' }).map { |task| task['id'] }
    assert_includes root_task_ids, parent['id']
    assert_includes root_task_ids, target['id']
  end

  def test_report_task_keeps_first_success_as_executor
    task = @service.add_task(title: 'task')

    first = @service.report_task(task_id: task['id'], agent_id: 'agent-1', result: 'success')
    second = @service.report_task(task_id: task['id'], agent_id: 'agent-2', result: 'success')

    assert_equal 'agent-1', first['actual_executor']
    assert_equal 'agent-1', second['actual_executor']
    assert_equal 2, second['reports'].size
  end

  def test_report_task_with_unknown_result_does_not_change_status
    task = @service.add_task(title: 'task')

    reported = @service.report_task(task_id: task['id'], agent_id: 'agent-1', result: 'unknown')
    assert_equal 'pending', reported['status']
    assert_nil reported['actual_executor']
    assert_nil reported['completion_status']
    assert_equal 'unknown', reported['reports'].first['result']
  end

  def test_add_task_rejects_invalid_task_type
    error = assert_raises(SmartTodo::ValidationError) do
      @service.add_task(title: 'invalid', task_type: 'unsupported')
    end

    assert_match('task_type must be one of', error.message)
  end

  def test_parent_cannot_be_completed_until_all_subtasks_completed
    parent = @service.add_task(title: 'parent')
    child = @service.add_task(title: 'child', parent_id: parent['id'])

    error = assert_raises(SmartTodo::ValidationError) do
      @service.report_task(task_id: parent['id'], agent_id: 'agent-1', result: 'success')
    end
    assert_match('cannot be completed', error.message)
    assert_equal 'pending', @service.fetch_task(task_id: parent['id'])['status']

    @service.report_task(task_id: child['id'], agent_id: 'agent-2', result: 'success')
    done = @service.report_task(task_id: parent['id'], agent_id: 'agent-1', result: 'success')
    assert_equal 'completed', done['status']
  end

  def test_add_reshape_and_delete_subtask
    parent = @service.add_task(title: 'parent')
    dep = @service.add_task(title: 'dep')

    created = @service.add_subtasks(
      parent_task_id: parent['id'],
      subtasks: [
        { 'title' => 'child-a', 'priority' => 2 },
        { 'title' => 'child-b', 'required_skills' => ['ruby'] }
      ]
    )
    assert_equal 2, created.size
    child = created.first

    reshaped = @service.reshape_subtask(
      parent_task_id: parent['id'],
      subtask_id: child['id'],
      updates: { 'priority' => 9 },
      add_dependencies: [dep['id']]
    )
    assert_equal 9, reshaped['priority']
    assert_equal [dep['id']], reshaped['dependencies']

    deleted = @service.delete_subtask(parent_task_id: parent['id'], subtask_id: child['id'])
    assert_equal child['id'], deleted['deleted_task_id']
    assert_nil @store.task(child['id'])
  end

  def test_subtask_cannot_be_recompleted_via_executor_resolution_when_its_child_is_pending
    parent = @service.add_task(title: 'parent')
    child = @service.add_task(title: 'child', parent_id: parent['id'])

    @service.report_task(task_id: child['id'], agent_id: 'agent-1', result: 'success')
    grandchild = @service.add_task(title: 'grandchild', parent_id: child['id'])

    reported = @service.report_task(task_id: child['id'], agent_id: 'agent-1', result: 'failed')
    assert_equal 'failed', reported['status']
    assert_equal 'agent-1', reported['actual_executor']

    error = assert_raises(SmartTodo::ValidationError) do
      @service.report_task(task_id: child['id'], agent_id: 'agent-1', result: 'success')
    end
    assert_match('cannot be completed', error.message)
    assert_equal grandchild['id'], @service.fetch_task(task_id: child['id'])['children'].first
  end
end
