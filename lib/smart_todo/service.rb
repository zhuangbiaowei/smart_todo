# frozen_string_literal: true

require 'time'

module SmartTodo
  class Service
    TASK_TYPES = %w[simple sequential parallel recurring branching].freeze
    TERMINAL_STATUSES = %w[completed failed suspended].freeze

    def initialize(store:)
      @store = store
    end

    def add_task(title:, description: nil, parent_id: nil, dependencies: [], required_skills: [], priority: 0, metadata: {},
                 task_type: 'simple', requirements: {}, acceptance_criteria: [], success_criteria: [], failure_criteria: [])
      validate_parent!(parent_id) if parent_id
      dependencies.each { |dep| validate_exists!(dep) }
      validate_task_type!(task_type)

      task = store.create_task(
        'title' => title,
        'description' => description,
        'parent_id' => parent_id,
        'task_type' => task_type,
        'requirements' => requirements,
        'acceptance_criteria' => acceptance_criteria,
        'success_criteria' => success_criteria,
        'failure_criteria' => failure_criteria,
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
      validate_parent!(updates['parent_id']) if updates.key?('parent_id') && updates['parent_id']
      validate_task_type!(updates['task_type']) if updates.key?('task_type')
      ensure_children_completed!(task_id) if updates['status'] == 'completed'

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

    def report_task(task_id:, agent_id:, result:, summary: nil, detail: {}, completion_status: nil, task_result: nil,
                    execution_logs: nil)
      task = store.task(task_id)
      raise NotFoundError, "task #{task_id} not found" unless task

      next_status = map_result_to_status(result)
      ensure_children_completed!(task_id) if next_status == 'completed'

      report = {
        'agent_id' => agent_id,
        'result' => result,
        'summary' => summary,
        'detail' => detail,
        'reported_at' => Time.now.utc.iso8601
      }
      store.append_report(task_id, report)

      task_updates = {}
      task_updates['status'] = next_status if next_status
      task_updates['completion_status'] = completion_status || inferred_completion_status(result)
      task_updates['task_result'] = task_result unless task_result.nil?
      task_updates['execution_logs'] = Array(execution_logs) unless execution_logs.nil?
      store.update_task(task_id, task_updates) unless task_updates.empty?
      resolve_executor!(task_id)
      enrich(store.task(task_id))
    end

    def fetch_task(task_id:)
      task = store.task(task_id)
      raise NotFoundError, "task #{task_id} not found" unless task

      enrich(task)
    end

    def list_tasks(filters: {})
      tasks = store.all_task_ids.filter_map { |id| store.task(id) }
      tasks = tasks.select { |task| match_filters?(task, filters) }
      tasks.sort_by { |task| [-task['priority'], task['created_at']] }
           .map { |task| enrich(task) }
    end

    def add_subtasks(parent_task_id:, subtasks:)
      validate_exists!(parent_task_id)
      raise ValidationError, 'subtasks must be a non-empty array' unless subtasks.is_a?(Array) && !subtasks.empty?

      subtasks.map do |attrs|
        add_task(
          title: attrs.fetch('title'),
          description: attrs['description'],
          parent_id: parent_task_id,
          dependencies: attrs.fetch('dependencies', []),
          task_type: attrs.fetch('task_type', 'simple'),
          requirements: attrs.fetch('requirements', {}),
          acceptance_criteria: attrs.fetch('acceptance_criteria', []),
          success_criteria: attrs.fetch('success_criteria', []),
          failure_criteria: attrs.fetch('failure_criteria', []),
          required_skills: attrs.fetch('required_skills', []),
          priority: attrs.fetch('priority', 0),
          metadata: attrs.fetch('metadata', {})
        )
      end
    end

    def list_subtasks(parent_task_id:)
      validate_exists!(parent_task_id)
      store.children(parent_task_id)
           .filter_map { |id| store.task(id) }
           .sort_by { |task| [-task['priority'], task['created_at']] }
           .map { |task| enrich(task) }
    end

    def reshape_subtask(parent_task_id:, subtask_id:, updates: {}, add_dependencies: [], remove_dependencies: [])
      validate_subtask_of_parent!(parent_task_id, subtask_id)
      if updates.key?('parent_id') && updates['parent_id'] != parent_task_id
        raise ValidationError, 'subtask parent_id cannot be changed via this endpoint'
      end

      updates = updates.merge('parent_id' => parent_task_id)
      reshape_task(
        task_id: subtask_id,
        updates: updates,
        add_dependencies: add_dependencies,
        remove_dependencies: remove_dependencies
      )
    end

    def delete_subtask(parent_task_id:, subtask_id:)
      validate_subtask_of_parent!(parent_task_id, subtask_id)
      raise ValidationError, "subtask #{subtask_id} has children and cannot be deleted" unless store.children(subtask_id).empty?

      deleted = store.delete_task(subtask_id)
      {
        'deleted_task_id' => deleted['id'],
        'parent_task_id' => parent_task_id
      }
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

    def match_filters?(task, filters)
      filters.all? do |key, value|
        next true if value.nil? || value == ''

        case key.to_s
        when 'status', 'task_type', 'parent_id', 'actual_executor', 'completion_status'
          return task['parent_id'].nil? if key.to_s == 'parent_id' && value == 'root'

          task[key.to_s] == value
        when 'required_skill'
          task['required_skills'].include?(value)
        when 'suggested_tool'
          Array(task.dig('requirements', 'suggested_tools')).include?(value)
        else
          true
        end
      end
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

    def inferred_completion_status(result)
      return nil unless map_result_to_status(result)

      result
    end

    def resolve_executor!(task_id)
      reports = store.reports(task_id)
      winner = reports.select { |r| r['result'] == 'success' }
                      .min_by { |r| Time.parse(r['reported_at']) }
      return unless winner

      updates = { 'actual_executor' => winner['agent_id'] }
      updates['status'] = 'completed' if children_completed?(task_id)
      store.update_task(task_id, updates)
    end

    def ensure_children_completed!(task_id)
      return if children_completed?(task_id)

      raise ValidationError, "task #{task_id} cannot be completed until all subtasks are completed"
    end

    def children_completed?(task_id)
      store.children(task_id).all? do |child_id|
        child = store.task(child_id)
        child && child['status'] == 'completed'
      end
    end

    def validate_subtask_of_parent!(parent_task_id, subtask_id)
      validate_exists!(parent_task_id)
      child = store.task(subtask_id)
      raise NotFoundError, "task #{subtask_id} not found" unless child
      raise ValidationError, "task #{subtask_id} is not a subtask of #{parent_task_id}" unless child['parent_id'] == parent_task_id
    end

    def validate_parent!(parent_id)
      validate_exists!(parent_id)
    end

    def validate_task_type!(task_type)
      return if TASK_TYPES.include?(task_type)

      raise ValidationError, "task_type must be one of: #{TASK_TYPES.join(', ')}"
    end

    def validate_exists!(task_id)
      raise NotFoundError, "task #{task_id} not found" unless store.task(task_id)
    end
  end
end
