# SmartTodo

SmartTodo 是一个面向 multi-agent / LLM 协作场景的任务编排系统，支持：

- 分层任务（父子结构）
- 任务依赖关系（DAG 风格）
- 多 Agent 并发领取同一任务
- 基于结果与先后顺序的实际执行者判定
- 两种接口模式：Ruby Gem API + HTTP API
- Redis 作为底层存储，适配高并发请求

## 安装

```bash
bundle install
```

## 作为 Ruby Gem 使用

```ruby
require 'smart_todo'

client = SmartTodo::Client.new(redis_url: 'redis://127.0.0.1:6379/0')

root = client.add_task(title: '发布v1', required_skills: ['planning'])
child = client.add_task(
  title: '实现API',
  parent_id: root['id'],
  dependencies: [],
  required_skills: ['ruby', 'backend'],
  priority: 10
)

candidates = client.seek_tasks(agent_id: 'agent-a', skills: %w[ruby backend], limit: 3)

client.report_task(
  task_id: child['id'],
  agent_id: 'agent-a',
  result: 'success',
  summary: '接口已交付'
)
```

## HTTP API

启动服务：

```bash
bundle exec ruby bin/smart_todo_server
```

### 1) 添加任务

`POST /tasks`

```json
{
  "title": "实现支付模块",
  "description": "支持多渠道",
  "dependencies": [],
  "required_skills": ["ruby", "payments"],
  "priority": 8,
  "metadata": {"sprint": "S1"}
}
```

### 2) 分解/重排任务

`PATCH /tasks/:id`

```json
{
  "updates": {"parent_id": "<new_parent_id>", "priority": 9},
  "add_dependencies": ["<task_id_1>"],
  "remove_dependencies": []
}
```

### 3) 寻求任务

`POST /tasks/seek`

```json
{
  "agent_id": "agent-ml-1",
  "skills": ["ruby", "payments"],
  "limit": 5
}
```

### 4) 回报任务结果

`POST /tasks/:id/report`

```json
{
  "agent_id": "agent-ml-1",
  "result": "success",
  "summary": "测试通过",
  "detail": {"coverage": 0.91}
}
```

其中 `result` 支持：`success`, `failed`, `suspended`, `blocked`, `in_progress`。

## 任务归属策略

同一任务允许多个 Agent 领取并上报。

- 所有上报会被保留
- 若有多个 `success`，默认选择最早成功上报者作为 `actual_executor`
- 任务状态会被推进为 `completed`

## 测试

```bash
bundle exec rake test
```
