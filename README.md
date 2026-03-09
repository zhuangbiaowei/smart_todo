# SmartTodo

SmartTodo 是一个面向 multi-agent / LLM 协作场景的任务编排系统。它支持：

- 分层任务，父子结构
- 任务依赖关系，DAG 风格
- 多 Agent 并发领取同一任务
- 基于结果与先后顺序的实际执行者判定
- Ruby Gem API 和 HTTP API
- Redis 作为底层存储

如果你的目标是让另一个 AI Coding 工具稳定接入本服务，建议优先阅读本文的 `Agent Integration Guide`、`任务对象模型`、`状态语义` 和 `HTTP API`。

## 安装

```bash
bundle install
```

## 机器可消费规范

如果你要让 AI agent、代码生成器、工作流引擎直接消费本服务，优先使用下面两个规范文件：

- OpenAPI 3.1: [docs/openapi.yaml](/home/mlf/smart_ai/smart_todo/docs/openapi.yaml)
- JSON Schema 任务对象: [docs/schemas/task.schema.json](/home/mlf/smart_ai/smart_todo/docs/schemas/task.schema.json)

## 快速开始

### 作为 Ruby Gem 使用

```ruby
require 'smart_todo'

client = SmartTodo::Client.new(redis_url: 'redis://127.0.0.1:6479/0')

root = client.add_task(
  title: '发布 v1',
  task_type: 'sequential',
  requirements: {
    suggested_tools: ['terminal', 'editor'],
    skill_instructions: ['先拆分子任务，再逐项交付']
  },
  acceptance_criteria: ['所有子任务完成'],
  success_criteria: ['版本发布成功'],
  failure_criteria: ['关键任务失败']
)

child = client.add_task(
  title: '实现 API',
  parent_id: root['id'],
  dependencies: [],
  task_type: 'simple',
  required_skills: ['ruby', 'backend'],
  requirements: {
    suggested_tools: ['editor', 'terminal'],
    skill_instructions: ['先补测试，再实现接口']
  },
  acceptance_criteria: ['接口测试通过'],
  success_criteria: ['返回契约满足设计'],
  failure_criteria: ['核心用例失败'],
  priority: 10
)

candidates = client.seek_tasks(agent_id: 'agent-a', skills: %w[ruby backend], limit: 3)

client.report_task(
  task_id: child['id'],
  agent_id: 'agent-a',
  result: 'success',
  summary: '接口已交付',
  completion_status: 'accepted',
  task_result: { artifact: 'api-v1', coverage: 0.92 },
  execution_logs: ['实现接口', '执行测试', '整理输出']
)
```

### 启动 HTTP 服务

```bash
bundle exec ruby bin/smart_todo_server
```

## Agent Integration Guide

这一节是给另一个 AI Coding 工具用的。建议按下面的约定接入。

### 推荐调用顺序

1. 用 `POST /tasks` 创建任务，写清楚 `task_type`、`requirements`、验收条件。
2. 用 `POST /tasks/seek` 让 agent 根据技能领取可执行任务。
3. 执行完成后，用 `POST /tasks/:id/report` 回报执行结果、完成状态、产出物和可选日志。
4. 用 `GET /tasks/:id` 或 `GET /tasks` 查询当前任务树、执行记录和筛选结果。
5. 如果需要进一步拆解父任务，用 `POST /tasks/:id/subtasks` 批量创建子任务。

### 推荐字段约定

虽然 `requirements` 和 `task_result` 是开放结构，但为了让多个 AI 工具协作时保持一致，建议统一使用下面这些 key。

`requirements` 建议结构：

```json
{
  "suggested_tools": ["terminal", "editor", "browser"],
  "skill_instructions": [
    "先阅读相关代码",
    "优先补测试",
    "实现后执行验证"
  ],
  "notes": ["可选补充说明"]
}
```

`task_result` 建议结构：

```json
{
  "summary": "本次执行的结果摘要",
  "artifacts": ["src/api.rb", "test/api_test.rb"],
  "metrics": {"coverage": 0.92},
  "next_actions": ["等待代码评审"]
}
```

`execution_logs` 建议是字符串数组，每一项是一条简短、可追踪的执行记录。

### AI Agent 最佳实践

- 创建任务时尽量把 `acceptance_criteria` 写成可验证的条件，而不是笼统描述。
- 如果任务需要指定工具或操作方式，把内容写进 `requirements.suggested_tools` 和 `requirements.skill_instructions`。
- 回报任务时不要只写 `result`，同时写 `completion_status` 和 `task_result`，这样查询接口更有价值。
- 查询任务列表时优先使用过滤参数，而不是一次拉全量后在本地筛选。
- 如果任务是父任务且仍有未完成子任务，不要尝试直接上报 `success`，服务会拒绝。

## 任务对象模型

一个任务节点当前会返回以下字段。

### 基础字段

| 字段 | 类型 | 必填 | 默认值 | 说明 |
| --- | --- | --- | --- | --- |
| `id` | string | 系统生成 | 无 | 任务唯一 ID |
| `title` | string | 是 | 无 | 任务标题 |
| `description` | string/null | 否 | `null` | 任务描述 |
| `status` | string | 系统维护 | `pending` | 任务运行状态 |
| `parent_id` | string/null | 否 | `null` | 父任务 ID |
| `priority` | integer | 否 | `0` | 优先级，越大越优先 |
| `required_skills` | string[] | 否 | `[]` | 领取任务所需技能 |
| `metadata` | object | 否 | `{}` | 附加元数据 |
| `created_at` | string | 系统生成 | 无 | UTC ISO8601 时间 |
| `updated_at` | string | 系统维护 | 无 | UTC ISO8601 时间 |
| `actual_executor` | string/null | 系统维护 | `null` | 最早成功完成该任务的 agent |

### 新增的任务定义字段

| 字段 | 类型 | 必填 | 默认值 | 说明 |
| --- | --- | --- | --- | --- |
| `task_type` | string | 否 | `simple` | 任务类型 |
| `requirements` | object | 否 | `{}` | 推荐工具、技能操作说明等 |
| `acceptance_criteria` | string[] | 否 | `[]` | 验收条件 |
| `success_criteria` | string[] | 否 | `[]` | 成功判定条件 |
| `failure_criteria` | string[] | 否 | `[]` | 失败判定条件 |

### 新增的执行结果字段

| 字段 | 类型 | 必填 | 默认值 | 说明 |
| --- | --- | --- | --- | --- |
| `completion_status` | string/null | 否 | `null` | 完成后的业务结论 |
| `task_result` | object/null | 否 | `null` | 本次执行产出、摘要、指标等 |
| `execution_logs` | string[] | 否 | `[]` | 可选的节点级执行日志 |

### 富化返回字段

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `dependencies` | string[] | 当前任务依赖的任务 ID 列表 |
| `children` | string[] | 当前任务的直接子任务 ID 列表 |
| `assignments` | object[] | 任务被哪些 agent 领取过 |
| `reports` | object[] | 所有执行上报记录 |

## 枚举与状态语义

### `task_type`

合法值如下：

- `simple`: 简单任务
- `sequential`: 复杂顺序任务
- `parallel`: 复杂并行任务
- `recurring`: 循环或定时任务
- `branching`: 分支任务

如果传入非法值，服务会返回 `422`。

### `result`

`POST /tasks/:id/report` 时支持：

- `success`
- `failed`
- `suspended`
- `blocked`
- `in_progress`

### `result` 与 `status` 的关系

服务会把上报的 `result` 映射到任务 `status`：

| `result` | `status` |
| --- | --- |
| `success` | `completed` |
| `failed` | `failed` |
| `suspended` | `suspended` |
| `blocked` | `blocked` |
| `in_progress` | `in_progress` |

补充说明：

- 如果 `result` 不是上述值，报告仍会保存，但 `status` 不会变化。
- 如果任务存在未完成的直接子任务，则 `result=success` 会被拒绝。

### `completion_status`

`completion_status` 是对完成结果的业务补充，不参与调度逻辑。当前服务允许你自定义写入。

建议使用统一值，例如：

- `accepted`
- `rejected`
- `partial`
- `needs_review`

如果不传，当前实现会在 `result` 可映射时自动回填同名值，例如 `success`。

## 并发和归属规则

- 同一任务允许多个 agent 领取。
- 所有上报记录都会保留在 `reports` 中。
- 如果有多个 `success`，`actual_executor` 取最早成功上报的 agent。
- 任务有直接子任务时，只有所有直接子任务都为 `completed`，该任务才能推进为 `completed`。
- `seek` 只会返回 `pending` 且依赖已完成、技能匹配的任务。

## HTTP API

所有接口返回 `application/json`。

### 1) 创建任务

`POST /tasks`

请求体示例：

```json
{
  "title": "实现支付模块",
  "description": "支持多渠道",
  "task_type": "parallel",
  "dependencies": [],
  "required_skills": ["ruby", "payments"],
  "requirements": {
    "suggested_tools": ["terminal", "browser"],
    "skill_instructions": ["先阅读支付协议，再实现回调"]
  },
  "acceptance_criteria": ["集成测试通过"],
  "success_criteria": ["支付与退款链路打通"],
  "failure_criteria": ["对账失败或回调异常"],
  "priority": 8,
  "metadata": {"sprint": "S1"}
}
```

也支持使用 `parent_task_id` 作为 `parent_id` 的别名。

响应示例：

```json
{
  "id": "task-123",
  "title": "实现支付模块",
  "description": "支持多渠道",
  "status": "pending",
  "parent_id": null,
  "priority": 8,
  "task_type": "parallel",
  "requirements": {
    "suggested_tools": ["terminal", "browser"],
    "skill_instructions": ["先阅读支付协议，再实现回调"]
  },
  "acceptance_criteria": ["集成测试通过"],
  "success_criteria": ["支付与退款链路打通"],
  "failure_criteria": ["对账失败或回调异常"],
  "required_skills": ["ruby", "payments"],
  "metadata": {"sprint": "S1"},
  "created_at": "2026-03-09T08:00:00Z",
  "updated_at": "2026-03-09T08:00:00Z",
  "actual_executor": null,
  "completion_status": null,
  "task_result": null,
  "execution_logs": [],
  "dependencies": [],
  "children": [],
  "assignments": [],
  "reports": []
}
```

### 2) 更新或重排任务

`PATCH /tasks/:id`

请求体示例：

```json
{
  "updates": {
    "parent_id": "new-parent-id",
    "priority": 9,
    "task_type": "sequential",
    "requirements": {
      "suggested_tools": ["editor"],
      "skill_instructions": ["按顺序完成三个步骤"]
    },
    "acceptance_criteria": ["人工验收通过"]
  },
  "add_dependencies": ["task-a"],
  "remove_dependencies": ["task-b"]
}
```

说明：

- `updates` 中的字段会直接写回任务节点。
- 可以通过 `add_dependencies` 和 `remove_dependencies` 动态维护依赖。
- 如果在 `updates` 中把 `status` 改成 `completed`，但子任务未全部完成，会返回 `422`。

### 3) 寻求任务

`POST /tasks/seek`

请求体示例：

```json
{
  "agent_id": "agent-ml-1",
  "skills": ["ruby", "payments"],
  "limit": 5
}
```

行为说明：

- 只返回 `pending` 任务。
- 只返回所有依赖已 `completed` 的任务。
- 只返回技能匹配的任务。
- 结果按 `priority` 倒序、`created_at` 升序排序。
- 每次 `seek` 会写入 assignment 记录。

### 4) 回报任务结果

`POST /tasks/:id/report`

请求体示例：

```json
{
  "agent_id": "agent-ml-1",
  "result": "success",
  "summary": "测试通过",
  "detail": {"coverage": 0.91},
  "completion_status": "accepted",
  "task_result": {
    "summary": "支付链路已经打通",
    "artifacts": ["lib/payments/service.rb", "test/payments_test.rb"],
    "metrics": {"coverage": 0.91}
  },
  "execution_logs": ["执行单测", "执行集成测试", "整理产物"]
}
```

响应是更新后的完整任务对象。

### 5) 批量新增子任务

`POST /tasks/:id/subtasks`

请求体示例：

```json
{
  "subtasks": [
    {
      "title": "实现接口 A",
      "task_type": "simple",
      "priority": 5
    },
    {
      "title": "实现接口 B",
      "task_type": "simple",
      "required_skills": ["ruby"]
    }
  ]
}
```

说明：

- 传入的每个子任务都支持与 `POST /tasks` 相同的大部分字段。
- 子任务本身也可以继续作为父任务使用。

### 6) 修改子任务

`PATCH /tasks/:id/subtasks/:subtask_id`

请求体示例：

```json
{
  "updates": {
    "priority": 9,
    "requirements": {
      "suggested_tools": ["terminal"]
    }
  },
  "add_dependencies": ["task-a"],
  "remove_dependencies": []
}
```

说明：

- 只能修改当前父任务下的子任务。
- 不能通过这个接口把子任务改挂到别的父任务下。

### 7) 删除子任务

`DELETE /tasks/:id/subtasks/:subtask_id`

说明：

- 只能删除当前父任务下的子任务。
- 如果这个子任务仍有直接子任务，会返回 `422`。

### 8) 查询某个任务

`GET /tasks/:id`

返回完整任务对象。

### 9) 列出某个任务的直接子任务

`GET /tasks/:id/subtasks`

返回按 `priority` 倒序、`created_at` 升序排列的直接子任务列表。

### 10) 改进后的任务查询

`GET /tasks`

支持以下查询参数：

| 参数 | 说明 |
| --- | --- |
| `status` | 按任务运行状态过滤 |
| `task_type` | 按任务类型过滤 |
| `parent_id` | 按父任务过滤，根任务可传 `root` |
| `actual_executor` | 按实际执行者过滤 |
| `completion_status` | 按业务完成状态过滤 |
| `required_skill` | 任务 `required_skills` 包含该值 |
| `suggested_tool` | 任务 `requirements.suggested_tools` 包含该值 |

请求示例：

```bash
curl "http://127.0.0.1:4567/tasks?task_type=branching&completion_status=accepted"
curl "http://127.0.0.1:4567/tasks?parent_id=root"
curl "http://127.0.0.1:4567/tasks?suggested_tool=terminal"
```

## 错误处理

### `404 Not Found`

典型场景：

- 查询不存在的任务
- 修改不存在的任务
- 上报不存在的任务

响应示例：

```json
{
  "error": "task not-exists not found"
}
```

### `422 Unprocessable Entity`

典型场景：

- JSON 非法
- 缺少必填字段，例如 `title`
- `task_type` 不合法
- 父任务或依赖任务不存在
- 子任务未全部完成时尝试把父任务置为 `completed`
- 子任务不属于指定父任务

响应示例：

```json
{
  "error": "task_type must be one of: simple, sequential, parallel, recurring, branching"
}
```

### `500 Internal Server Error`

表示服务内部异常。响应格式同样为：

```json
{
  "error": "internal error message"
}
```

## 一个完整的 AI 协作示例

下面是一个推荐的流程：

1. 创建父任务 `发布 v1`，`task_type=sequential`。
2. 在父任务下创建子任务：`实现 API`、`补测试`、`更新文档`。
3. 让不同 agent 调用 `POST /tasks/seek` 领取适合自己的任务。
4. 每个 agent 完成后，用 `POST /tasks/:id/report` 回传：
   - `result`
   - `completion_status`
   - `task_result`
   - `execution_logs`
5. 用 `GET /tasks/:id` 查看父任务的 `children`、`reports`、`actual_executor`。
6. 当所有直接子任务都是 `completed` 后，再关闭父任务。

## 测试

```bash
bundle exec rake test
# 或
rake test
```
