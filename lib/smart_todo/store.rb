# frozen_string_literal: true

require 'json'
require 'securerandom'

module SmartTodo
  class Store
    def initialize(redis:)
      @redis = redis
    end

    def create_task(attributes)
      id = attributes.fetch('id', SecureRandom.uuid)
      now = Time.now.utc.iso8601
      task = {
        'id' => id,
        'title' => attributes.fetch('title'),
        'description' => attributes['description'],
        'status' => attributes.fetch('status', 'pending'),
        'parent_id' => attributes['parent_id'],
        'priority' => attributes.fetch('priority', 0).to_i,
        'task_type' => attributes.fetch('task_type', 'simple'),
        'requirements' => attributes.fetch('requirements', {}),
        'acceptance_criteria' => Array(attributes.fetch('acceptance_criteria', [])),
        'success_criteria' => Array(attributes.fetch('success_criteria', [])),
        'failure_criteria' => Array(attributes.fetch('failure_criteria', [])),
        'required_skills' => Array(attributes['required_skills']),
        'metadata' => attributes.fetch('metadata', {}),
        'created_at' => now,
        'updated_at' => now,
        'actual_executor' => nil,
        'completion_status' => attributes['completion_status'],
        'task_result' => attributes['task_result'],
        'execution_logs' => Array(attributes.fetch('execution_logs', []))
      }

      redis.multi do |tx|
        tx.hset(task_key(id), flatten_task(task))
        tx.sadd(tasks_key, id)
        tx.zadd(index_by_created_key, now.to_f, id)
        tx.sadd(status_key(task['status']), id)
        tx.sadd(children_key(task['parent_id']), id) if task['parent_id']
      end

      task
    end

    def task(id)
      raw = redis.hgetall(task_key(id))
      return nil if raw.empty?

      hydrate_task(raw)
    end

    def all_task_ids
      redis.smembers(tasks_key)
    end

    def update_task(id, updates)
      current = task(id)
      raise NotFoundError, "task #{id} not found" unless current

      patched = current.merge(updates.compact)
      patched['updated_at'] = Time.now.utc.iso8601

      if updates.key?('status') && updates['status'] != current['status']
        redis.srem(status_key(current['status']), id)
        redis.sadd(status_key(updates['status']), id)
      end

      if updates.key?('parent_id') && updates['parent_id'] != current['parent_id']
        redis.srem(children_key(current['parent_id']), id) if current['parent_id']
        redis.sadd(children_key(updates['parent_id']), id) if updates['parent_id']
      end

      flattened = flatten_task(patched)
      redis.hset(task_key(id), flattened)
      clear_nil_fields(task_key(id), patched)
      patched
    end

    def delete_task(id)
      current = task(id)
      raise NotFoundError, "task #{id} not found" unless current

      dependency_ids = dependencies(id)
      dependent_ids = redis.smembers(dependents_key(id))

      redis.multi do |tx|
        dependency_ids.each { |dep_id| tx.srem(dependents_key(dep_id), id) }
        dependent_ids.each { |dependent_id| tx.srem(dependencies_key(dependent_id), id) }

        tx.srem(tasks_key, id)
        tx.srem(status_key(current['status']), id)
        tx.srem(children_key(current['parent_id']), id) if current['parent_id']
        tx.zrem(index_by_created_key, id)
        tx.del(
          task_key(id),
          dependencies_key(id),
          dependents_key(id),
          children_key(id),
          assignments_key(id),
          reports_key(id)
        )
      end

      current
    end

    def add_dependency(task_id, dependency_id)
      redis.sadd(dependencies_key(task_id), dependency_id)
      redis.sadd(dependents_key(dependency_id), task_id)
    end

    def remove_dependency(task_id, dependency_id)
      redis.srem(dependencies_key(task_id), dependency_id)
      redis.srem(dependents_key(dependency_id), task_id)
    end

    def dependencies(task_id)
      redis.smembers(dependencies_key(task_id))
    end

    def children(task_id)
      redis.smembers(children_key(task_id))
    end

    def add_assignment(task_id, agent_id, payload = {})
      assignment = payload.merge('agent_id' => agent_id, 'assigned_at' => Time.now.utc.iso8601)
      redis.hset(assignments_key(task_id), agent_id, JSON.generate(assignment))
      assignment
    end

    def assignments(task_id)
      redis.hgetall(assignments_key(task_id)).transform_values { |v| JSON.parse(v) }
    end

    def append_report(task_id, report)
      redis.rpush(reports_key(task_id), JSON.generate(report))
      report
    end

    def reports(task_id)
      redis.lrange(reports_key(task_id), 0, -1).map { |entry| JSON.parse(entry) }
    end

    private

    attr_reader :redis

    def flatten_task(task)
      {
        'id' => task['id'],
        'title' => task['title'],
        'description' => task['description'],
        'status' => task['status'],
        'parent_id' => task['parent_id'],
        'priority' => task['priority'],
        'task_type' => task['task_type'],
        'requirements' => JSON.generate(task['requirements']),
        'acceptance_criteria' => JSON.generate(task['acceptance_criteria']),
        'success_criteria' => JSON.generate(task['success_criteria']),
        'failure_criteria' => JSON.generate(task['failure_criteria']),
        'required_skills' => JSON.generate(task['required_skills']),
        'metadata' => JSON.generate(task['metadata']),
        'created_at' => task['created_at'],
        'updated_at' => task['updated_at'],
        'actual_executor' => task['actual_executor'],
        'completion_status' => task['completion_status'],
        'task_result' => JSON.generate(task['task_result']),
        'execution_logs' => JSON.generate(task['execution_logs'])
      }.compact
    end

    def hydrate_task(raw)
      {
        'id' => raw['id'],
        'title' => raw['title'],
        'description' => raw['description'],
        'status' => raw['status'],
        'parent_id' => raw['parent_id'],
        'priority' => raw['priority'].to_i,
        'task_type' => raw.fetch('task_type', 'simple'),
        'requirements' => JSON.parse(raw.fetch('requirements', '{}')),
        'acceptance_criteria' => JSON.parse(raw.fetch('acceptance_criteria', '[]')),
        'success_criteria' => JSON.parse(raw.fetch('success_criteria', '[]')),
        'failure_criteria' => JSON.parse(raw.fetch('failure_criteria', '[]')),
        'required_skills' => JSON.parse(raw.fetch('required_skills', '[]')),
        'metadata' => JSON.parse(raw.fetch('metadata', '{}')),
        'created_at' => raw['created_at'],
        'updated_at' => raw['updated_at'],
        'actual_executor' => raw['actual_executor'],
        'completion_status' => raw['completion_status'],
        'task_result' => raw.key?('task_result') ? JSON.parse(raw['task_result']) : nil,
        'execution_logs' => JSON.parse(raw.fetch('execution_logs', '[]'))
      }
    end

    def task_key(id) = "smart_todo:task:#{id}"
    def tasks_key = 'smart_todo:tasks:all'
    def status_key(status) = "smart_todo:tasks:status:#{status}"
    def index_by_created_key = 'smart_todo:index:created_at'
    def dependencies_key(task_id) = "smart_todo:task:#{task_id}:dependencies"
    def dependents_key(task_id) = "smart_todo:task:#{task_id}:dependents"
    def children_key(task_id) = "smart_todo:task:#{task_id || 'root'}:children"
    def assignments_key(task_id) = "smart_todo:task:#{task_id}:assignments"
    def reports_key(task_id) = "smart_todo:task:#{task_id}:reports"

    def clear_nil_fields(key, task)
      nil_fields = %w[description parent_id actual_executor completion_status task_result].select do |field|
        task[field].nil?
      end
      return if nil_fields.empty?

      redis.hdel(key, *nil_fields)
    end
  end
end
