# frozen_string_literal: true

require 'time'

module SmartTodo
  class Service
    TERMINAL_STATUSES = %w[completed failed suspended].freeze

    def initialize(store:)
      @store = store
    end

    def add_task(title:, description: nil, parent_id: nil, dependencies: [], required_skills: [], priority: 0, metadata: {})
      validate_parent!(parent_id) if parent_id
      dependencies.each { |dep| validate_exists!(dep) }

      task = store.create_task(
        'title' => title,
        'description' => description,
        'parent_id' => parent_id,
        'required_skills' => required_skills,
        'priority' => priority,
        'metadata' => metadata
      )
      dependencies.each { |dep| store.add_dependency(task['id'], dep) }
      enrich(task)
    end

    def reshape_task(task_id:, updates: {}, add_dependencies: [], remove_dependencies: [])
      validate_exists!(task_id)
      add_dependencies.each { |dep| validate_exists!(dep) }
      remove_dependencies.each { |dep| validate_exists!(dep) }

      task = store.update_task(task_id, updates)
      add_dependencies.each { |dep| store.add_dependency(task_id, dep) }
      remove_dependencies.each { |dep| store.remove_dependency(task_id, dep) }
      enrich(task)
    end

    def seek_tasks(agent_id:, skills: [], limit: 1)
      candidates = store.all_task_ids.filter_map { |id| store.task(id) }
      selected = candidates.select do |task|
        task['status'] == 'pending' &&
          deps_done?(task['id']) &&
          skill_match?(task, skills)
      end.sort_by { |task| [-task['priority'], task['created_at']] }.first(limit)

      selected.each do |task|
        store.add_assignment(task['id'], agent_id, 'agent_skills' => skills)
      end

      selected.map { |task| enrich(task) }
    end

    def report_task(task_id:, agent_id:, result:, summary: nil, detail: {})
      task = store.task(task_id)
      raise NotFoundError, "task #{task_id} not found" unless task

      report = {
        'agent_id' => agent_id,
        'result' => result,
        'summary' => summary,
        'detail' => detail,
        'reported_at' => Time.now.utc.iso8601
      }
      store.append_report(task_id, report)

      next_status = map_result_to_status(result)
      store.update_task(task_id, 'status' => next_status) if next_status
      resolve_executor!(task_id)
      enrich(store.task(task_id))
    end

    def fetch_task(task_id)
      task = store.task(task_id)
      raise NotFoundError, "task #{task_id} not found" unless task

      enrich(task)
    end

    private

    attr_reader :store

    def enrich(task)
      task.merge(
        'dependencies' => store.dependencies(task['id']),
        'children' => store.children(task['id']),
        'assignments' => store.assignments(task['id']).values,
        'reports' => store.reports(task['id'])
      )
    end

    def deps_done?(task_id)
      store.dependencies(task_id).all? do |dep_id|
        dep = store.task(dep_id)
        dep && dep['status'] == 'completed'
      end
    end

    def skill_match?(task, skills)
      required = task['required_skills']
      required.empty? || required.all? { |skill| skills.include?(skill) }
    end

    def map_result_to_status(result)
      mapping = {
        'success' => 'completed',
        'failed' => 'failed',
        'suspended' => 'suspended',
        'blocked' => 'blocked',
        'in_progress' => 'in_progress'
      }
      mapping[result]
    end

    def resolve_executor!(task_id)
      reports = store.reports(task_id)
      winner = reports.select { |r| r['result'] == 'success' }
                      .min_by { |r| Time.parse(r['reported_at']) }
      return unless winner

      store.update_task(task_id, 'actual_executor' => winner['agent_id'], 'status' => 'completed')
    end

    def validate_parent!(parent_id)
      validate_exists!(parent_id)
    end

    def validate_exists!(task_id)
      raise NotFoundError, "task #{task_id} not found" unless store.task(task_id)
    end
  end
end
