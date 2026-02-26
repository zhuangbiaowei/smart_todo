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
        'required_skills' => Array(attributes['required_skills']),
        'metadata' => attributes.fetch('metadata', {}),
        'created_at' => now,
        'updated_at' => now,
        'actual_executor' => nil
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

      redis.hset(task_key(id), flatten_task(patched))
      patched
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
        'required_skills' => JSON.generate(task['required_skills']),
        'metadata' => JSON.generate(task['metadata']),
        'created_at' => task['created_at'],
        'updated_at' => task['updated_at'],
        'actual_executor' => task['actual_executor']
      }
    end

    def hydrate_task(raw)
      {
        'id' => raw['id'],
        'title' => raw['title'],
        'description' => raw['description'],
        'status' => raw['status'],
        'parent_id' => raw['parent_id'],
        'priority' => raw['priority'].to_i,
        'required_skills' => JSON.parse(raw.fetch('required_skills', '[]')),
        'metadata' => JSON.parse(raw.fetch('metadata', '{}')),
        'created_at' => raw['created_at'],
        'updated_at' => raw['updated_at'],
        'actual_executor' => raw['actual_executor']
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
  end
end
