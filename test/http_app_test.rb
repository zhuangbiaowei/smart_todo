# frozen_string_literal: true

require 'json'
require 'minitest/autorun'
require 'rack/mock'
require_relative '../lib/smart_todo/errors'
require_relative '../lib/smart_todo/store'
require_relative '../lib/smart_todo/service'
require_relative '../lib/smart_todo/http/app'
require_relative 'support/fake_redis'

class HttpAppTest < Minitest::Test
  def setup
    store = SmartTodo::Store.new(redis: FakeRedis.new)
    service = SmartTodo::Service.new(store: store)
    app_class = Class.new(SmartTodo::HTTP::App) do
      set :service, service
    end
    @request = Rack::MockRequest.new(app_class)
  end

  def test_create_and_fetch_task
    response = json_request(
      'POST',
      '/tasks',
      {
        'title' => 't1',
        'priority' => 3,
        'task_type' => 'parallel',
        'requirements' => { 'suggested_tools' => ['terminal'], 'skill_instructions' => ['run tests first'] },
        'acceptance_criteria' => ['all tests pass']
      }
    )
    assert_equal 201, response.status

    task = JSON.parse(response.body)
    assert_equal 't1', task['title']
    assert_equal 3, task['priority']
    assert_equal 'parallel', task['task_type']
    assert_equal ['terminal'], task.dig('requirements', 'suggested_tools')
    assert_equal ['all tests pass'], task['acceptance_criteria']

    fetched = @request.get("/tasks/#{task['id']}")
    assert_equal 200, fetched.status
    assert_equal task['id'], JSON.parse(fetched.body)['id']
  end

  def test_create_task_accepts_parent_task_id_alias
    parent = JSON.parse(json_request('POST', '/tasks', { 'title' => 'parent' }).body)
    child = JSON.parse(
      json_request('POST', '/tasks', { 'title' => 'child', 'parent_task_id' => parent['id'] }).body
    )

    assert_equal parent['id'], child['parent_id']
  end

  def test_list_tasks_and_filter_by_status
    pending = JSON.parse(json_request('POST', '/tasks', { 'title' => 'todo', 'priority' => 1 }).body)
    completed = JSON.parse(json_request('POST', '/tasks', { 'title' => 'done', 'priority' => 5 }).body)
    json_request('POST', "/tasks/#{completed['id']}/report", { 'agent_id' => 'a1', 'result' => 'success' })

    all = @request.get('/tasks')
    assert_equal 200, all.status
    all_ids = JSON.parse(all.body).map { |t| t['id'] }
    assert_equal [completed['id'], pending['id']], all_ids

    filtered = @request.get('/tasks?status=completed')
    assert_equal 200, filtered.status
    assert_equal [completed['id']], JSON.parse(filtered.body).map { |t| t['id'] }
  end

  def test_list_tasks_filters_by_new_query_params
    parent = JSON.parse(json_request('POST', '/tasks', { 'title' => 'parent' }).body)
    other = JSON.parse(
      json_request(
        'POST',
        '/tasks',
        { 'title' => 'other', 'task_type' => 'parallel', 'requirements' => { 'suggested_tools' => ['browser'] } }
      ).body
    )
    target = JSON.parse(
      json_request(
        'POST',
        '/tasks',
        {
          'title' => 'target',
          'parent_id' => parent['id'],
          'task_type' => 'branching',
          'required_skills' => ['planning'],
          'requirements' => { 'suggested_tools' => ['cursor'] }
        }
      ).body
    )
    json_request(
      'POST',
      "/tasks/#{target['id']}/report",
      { 'agent_id' => 'a2', 'result' => 'success', 'completion_status' => 'accepted' }
    )

    by_type = @request.get('/tasks?task_type=branching')
    assert_equal [target['id']], JSON.parse(by_type.body).map { |task| task['id'] }

    by_tool = @request.get('/tasks?suggested_tool=cursor')
    assert_equal [target['id']], JSON.parse(by_tool.body).map { |task| task['id'] }

    by_skill = @request.get('/tasks?required_skill=planning')
    assert_equal [target['id']], JSON.parse(by_skill.body).map { |task| task['id'] }

    by_parent = @request.get("/tasks?parent_id=#{parent['id']}")
    assert_equal [target['id']], JSON.parse(by_parent.body).map { |task| task['id'] }

    by_executor = @request.get('/tasks?actual_executor=a2')
    assert_equal [target['id']], JSON.parse(by_executor.body).map { |task| task['id'] }

    by_completion_status = @request.get('/tasks?completion_status=accepted')
    assert_equal [target['id']], JSON.parse(by_completion_status.body).map { |task| task['id'] }

    root_only = @request.get('/tasks?parent_id=root')
    root_ids = JSON.parse(root_only.body).map { |task| task['id'] }
    assert_includes root_ids, parent['id']
    assert_includes root_ids, other['id']
  end

  def test_seek_and_report_task
    task = JSON.parse(json_request('POST', '/tasks', { 'title' => 'worker', 'required_skills' => ['ruby'] }).body)
    seek = json_request('POST', '/tasks/seek', { 'agent_id' => 'a1', 'skills' => ['ruby'], 'limit' => 1 })
    assert_equal 200, seek.status
    assert_equal [task['id']], JSON.parse(seek.body).map { |t| t['id'] }

    report = json_request(
      'POST',
      "/tasks/#{task['id']}/report",
      {
        'agent_id' => 'a1',
        'result' => 'success',
        'completion_status' => 'accepted',
        'task_result' => { 'summary' => 'worker completed' },
        'execution_logs' => ['claim task', 'finish task']
      }
    )
    body = JSON.parse(report.body)
    assert_equal 200, report.status
    assert_equal 'completed', body['status']
    assert_equal 'a1', body['actual_executor']
    assert_equal 'accepted', body['completion_status']
    assert_equal({ 'summary' => 'worker completed' }, body['task_result'])
    assert_equal ['claim task', 'finish task'], body['execution_logs']
  end

  def test_subtask_batch_create_update_and_delete
    parent = JSON.parse(json_request('POST', '/tasks', { 'title' => 'parent' }).body)
    dep = JSON.parse(json_request('POST', '/tasks', { 'title' => 'dep' }).body)

    create = json_request(
      'POST',
      "/tasks/#{parent['id']}/subtasks",
      { 'subtasks' => [{ 'title' => 'child-a' }, { 'title' => 'child-b', 'priority' => 3 }] }
    )
    assert_equal 201, create.status
    subtasks = JSON.parse(create.body)
    child = subtasks.first

    listed = @request.get("/tasks/#{parent['id']}/subtasks")
    assert_equal 200, listed.status
    expected_ids = subtasks.sort_by { |t| [-t['priority'], t['created_at']] }.map { |t| t['id'] }
    assert_equal expected_ids, JSON.parse(listed.body).map { |t| t['id'] }

    patch = json_request(
      'PATCH',
      "/tasks/#{parent['id']}/subtasks/#{child['id']}",
      { 'updates' => { 'priority' => 9 }, 'add_dependencies' => [dep['id']] }
    )
    assert_equal 200, patch.status
    assert_equal 9, JSON.parse(patch.body)['priority']

    deleted = @request.delete("/tasks/#{parent['id']}/subtasks/#{child['id']}")
    assert_equal 200, deleted.status
    assert_equal child['id'], JSON.parse(deleted.body)['deleted_task_id']
  end

  def test_list_subtasks_works_for_subtask_id
    parent = JSON.parse(json_request('POST', '/tasks', { 'title' => 'parent' }).body)
    child = JSON.parse(json_request('POST', '/tasks', { 'title' => 'child', 'parent_id' => parent['id'] }).body)
    grandchild_a = JSON.parse(json_request('POST', '/tasks', { 'title' => 'gc-a', 'parent_id' => child['id'], 'priority' => 2 }).body)
    grandchild_b = JSON.parse(json_request('POST', '/tasks', { 'title' => 'gc-b', 'parent_id' => child['id'], 'priority' => 5 }).body)

    response = @request.get("/tasks/#{child['id']}/subtasks")
    assert_equal 200, response.status
    assert_equal [grandchild_b['id'], grandchild_a['id']], JSON.parse(response.body).map { |t| t['id'] }
  end

  def test_create_subtasks_works_for_subtask_id
    parent = JSON.parse(json_request('POST', '/tasks', { 'title' => 'parent' }).body)
    child = JSON.parse(json_request('POST', '/tasks', { 'title' => 'child', 'parent_id' => parent['id'] }).body)

    response = json_request(
      'POST',
      "/tasks/#{child['id']}/subtasks",
      { 'subtasks' => [{ 'title' => 'grandchild-1' }, { 'title' => 'grandchild-2' }] }
    )
    assert_equal 201, response.status

    created = JSON.parse(response.body)
    assert_equal 2, created.size
    assert_equal [child['id']], created.map { |t| t['parent_id'] }.uniq
  end

  def test_parent_cannot_be_completed_when_subtasks_not_all_done
    parent = JSON.parse(json_request('POST', '/tasks', { 'title' => 'parent' }).body)
    child = JSON.parse(json_request('POST', '/tasks', { 'title' => 'child', 'parent_id' => parent['id'] }).body)

    blocked = json_request('POST', "/tasks/#{parent['id']}/report", { 'agent_id' => 'a1', 'result' => 'success' })
    assert_equal 422, blocked.status
    assert_match('cannot be completed', JSON.parse(blocked.body)['error'])

    json_request('POST', "/tasks/#{child['id']}/report", { 'agent_id' => 'a2', 'result' => 'success' })
    done = json_request('POST', "/tasks/#{parent['id']}/report", { 'agent_id' => 'a1', 'result' => 'success' })
    assert_equal 200, done.status
    assert_equal 'completed', JSON.parse(done.body)['status']
  end

  def test_patch_task_reshape
    parent_a = JSON.parse(json_request('POST', '/tasks', { 'title' => 'pa' }).body)
    parent_b = JSON.parse(json_request('POST', '/tasks', { 'title' => 'pb' }).body)
    dep = JSON.parse(json_request('POST', '/tasks', { 'title' => 'dep' }).body)
    task = JSON.parse(json_request('POST', '/tasks', { 'title' => 'child', 'parent_id' => parent_a['id'] }).body)

    patch = json_request(
      'PATCH',
      "/tasks/#{task['id']}",
      { 'updates' => { 'parent_id' => parent_b['id'] }, 'add_dependencies' => [dep['id']] }
    )
    body = JSON.parse(patch.body)
    assert_equal 200, patch.status
    assert_equal parent_b['id'], body['parent_id']
    assert_equal [dep['id']], body['dependencies']
  end

  def test_returns_404_for_missing_task
    response = @request.get('/tasks/not-exists')
    assert_equal 404, response.status
    assert_match('not found', JSON.parse(response.body)['error'])
  end

  def test_returns_422_for_bad_json_and_missing_required_fields
    bad_json = @request.request(
      'POST',
      '/tasks',
      input: '{"title":',
      'CONTENT_TYPE' => 'application/json'
    )
    assert_equal 422, bad_json.status

    missing_title = json_request('POST', '/tasks', { 'priority' => 1 })
    assert_equal 422, missing_title.status
  end

  private

  def json_request(method, path, payload)
    @request.request(
      method,
      path,
      input: JSON.generate(payload),
      'CONTENT_TYPE' => 'application/json'
    )
  end
end
