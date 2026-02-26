# frozen_string_literal: true

require 'json'
require 'sinatra/base'

module SmartTodo
  module HTTP
    class App < Sinatra::Base
      configure do
        set :show_exceptions, false
      end

      before do
        content_type :json
      end

      post '/tasks' do
        payload = json_params
        task = service.add_task(
          title: payload.fetch('title'),
          description: payload['description'],
          parent_id: payload['parent_id'],
          dependencies: payload.fetch('dependencies', []),
          required_skills: payload.fetch('required_skills', []),
          priority: payload.fetch('priority', 0),
          metadata: payload.fetch('metadata', {})
        )
        status 201
        JSON.generate(task)
      end

      patch '/tasks/:id' do
        payload = json_params
        task = service.reshape_task(
          task_id: params['id'],
          updates: payload.fetch('updates', {}),
          add_dependencies: payload.fetch('add_dependencies', []),
          remove_dependencies: payload.fetch('remove_dependencies', [])
        )
        JSON.generate(task)
      end

      post '/tasks/seek' do
        payload = json_params
        tasks = service.seek_tasks(
          agent_id: payload.fetch('agent_id'),
          skills: payload.fetch('skills', []),
          limit: payload.fetch('limit', 1)
        )
        JSON.generate(tasks)
      end

      post '/tasks/:id/report' do
        payload = json_params
        task = service.report_task(
          task_id: params['id'],
          agent_id: payload.fetch('agent_id'),
          result: payload.fetch('result'),
          summary: payload['summary'],
          detail: payload.fetch('detail', {})
        )
        JSON.generate(task)
      end

      post '/tasks/:id/subtasks' do
        payload = json_params
        subtasks = service.add_subtasks(
          parent_task_id: params['id'],
          subtasks: payload.fetch('subtasks')
        )
        status 201
        JSON.generate(subtasks)
      end

      patch '/tasks/:id/subtasks/:subtask_id' do
        payload = json_params
        task = service.reshape_subtask(
          parent_task_id: params['id'],
          subtask_id: params['subtask_id'],
          updates: payload.fetch('updates', {}),
          add_dependencies: payload.fetch('add_dependencies', []),
          remove_dependencies: payload.fetch('remove_dependencies', [])
        )
        JSON.generate(task)
      end

      delete '/tasks/:id/subtasks/:subtask_id' do
        JSON.generate(
          service.delete_subtask(
            parent_task_id: params['id'],
            subtask_id: params['subtask_id']
          )
        )
      end

      get '/tasks' do
        JSON.generate(service.list_tasks(status: params['status']))
      end

      get '/tasks/:id' do
        JSON.generate(service.fetch_task(task_id: params['id']))
      end

      error SmartTodo::NotFoundError do
        status 404
        JSON.generate(error: env['sinatra.error'].message)
      end

      error SmartTodo::ValidationError, KeyError, JSON::ParserError do
        status 422
        JSON.generate(error: env['sinatra.error'].message)
      end

      not_found do
        status 404
        JSON.generate(error: 'not found')
      end

      error do
        status 500
        JSON.generate(error: env['sinatra.error'].message)
      end

      private

      def service
        settings.service
      end

      def json_params
        body = request.body.read
        return {} if body.nil? || body.empty?

        JSON.parse(body)
      end
    end
  end
end
