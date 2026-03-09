# Agent SDK 系统性对比分析

## Claude Agent SDK vs PyAgent vs OpenCode vs OpenAI Agent SDK

---

## 一、总览

| 维度 | Claude Agent SDK | OpenAI Agent SDK | OpenCode | PyAgent |
|------|-----------------|------------------|----------|---------|
| 开发者 | Anthropic | OpenAI | sst (开源社区) | acodercat (开源社区) |
| 语言支持 | TypeScript/Python | Python / TypeScript | Go (Golang) | Python |
| 定位 | 编程 Agent 基础设施 | 通用 Agent 编排框架 | 终端 AI 编程助手 | 工具增强型 Agent 框架 |
| 模型绑定 | Claude 专属 | 默认 OpenAI，支持多模型 | 多模型 (Claude/OpenAI/Gemini 等) | 多模型 (通过 LLM 抽象层) |
| 开源状态 | SDK 开源，核心 Agent 闭源 | 完全开源 | 完全开源 | 完全开源 |
| GitHub Stars | ~30k+ (Claude Code) | ~20k+ | ~5k+ | ~500+ |

---

## 二、核心架构对比

### 1. Claude Agent SDK

**架构模式：进程级 Agent 编排**

Claude Agent SDK 的核心设计理念是**将 Claude Code 本身作为一个可编程的子进程**来调用。它不是传统意义上的"框架"，而是一个 SDK 接口层，封装了对 Claude Code CLI 的调用。

```typescript
// TypeScript SDK
import { claude } from "@anthropic-ai/claude-code-sdk";

const conversation = claude({
  prompt: "Fix the bug in auth.ts",
  options: {
    maxTurns: 10,
    allowedTools: ["Read", "Edit", "Bash"],
    systemPrompt: "You are a senior engineer."
  }
});

for await (const event of conversation) {
  if (event.type === "assistant") {
    console.log(event.message);
  }
}
```

**Agent Loop（核心循环）：**
1. 用户 prompt 发送给 Claude 模型
2. 模型返回文本 + 工具调用请求
3. SDK 在受控环境中执行工具（文件读写、Bash 命令、搜索等）
4. 工具结果反馈给模型
5. 重复直到模型不再请求工具调用，或达到 `maxTurns` 上限

**关键特性：**
- **子 Agent 模式**：可以在 Agent 内部启动新的 Agent 子进程（通过 `Agent` tool），实现任务分解和并行处理
- **流式输出**：基于 AsyncIterator 的事件流，实时获取 Agent 行为
- **工具权限控制**：通过 `allowedTools` / `disallowedTools` 精细控制 Agent 可用工具
- **沙箱执行**：Bash 命令在沙箱中运行，限制网络访问和文件系统操作
- **MCP 集成**：支持 Model Context Protocol 服务器作为工具源
- **Hooks 系统**：在工具调用前后注入自定义逻辑

---

### 2. OpenAI Agent SDK

**架构模式：声明式 Agent 编排框架**

OpenAI Agent SDK（前身为 Swarm 项目）是一个完整的 Agent 编排框架，基于四个核心原语：**Agent、Tool、Runner、Handoff**。

```python
from agents import Agent, Runner, function_tool

@function_tool
def get_weather(city: str) -> str:
    """Get the weather for a city."""
    return f"Sunny in {city}"

agent = Agent(
    name="WeatherBot",
    instructions="You help with weather queries.",
    tools=[get_weather],
    model="gpt-4o"
)

result = Runner.run_sync(agent, "What's the weather in Tokyo?")
print(result.final_output)
```

**Agent Loop（核心循环）由 Runner 管理：**
1. 以当前 Agent 的 instructions + 对话历史调用 LLM
2. 如果输出匹配 `output_type` 且无工具调用 → 终止
3. 如果有工具调用 → 执行工具 → 结果追加到对话 → 继续迭代
4. 如果触发 Handoff → 切换到新 Agent → 重启循环
5. `max_turns` 安全限制防止无限循环

**关键特性：**
- **Handoff 机制**：Agent 间的控制权转移，实现去中心化的多 Agent 协作
- **Guardrails 三层防护**：输入守卫、输出守卫、工具守卫
- **Agent-as-Tool 模式**：将 Agent 作为工具暴露给其他 Agent，调用者保持控制权
- **多模型支持**：通过 LiteLLM 集成支持 100+ 模型提供商
- **Tracing 系统**：内置完整的执行追踪和可观测性
- **Human-in-the-loop**：流式执行中支持暂停等待人工审批

---

### 3. OpenCode

**架构模式：终端原生 AI 编程 Agent**

OpenCode 是一个用 Go 编写的开源终端 AI 编程助手，定位类似于 Claude Code 的开源替代品。它是一个完整的应用程序而非 SDK 框架。

```bash
# 安装和使用
go install github.com/sst/opencode@latest
opencode

# 在终端中直接与 AI 对话进行编程
> Fix the null pointer exception in handler.go
```

**架构特点：**
- **TUI 应用**：基于 BubbleTea（Go 的终端 UI 框架）构建的交互式终端界面
- **Provider 抽象层**：统一适配 Anthropic、OpenAI、Google Gemini、AWS Bedrock、OpenRouter 等多种模型
- **LSP 集成**：与语言服务器协议集成，提供代码智能感知
- **会话管理**：基于 SQLite 的本地会话持久化
- **文件监控**：实时监控项目文件变化

**工具系统：**
- 内置工具集：文件读写、Bash 执行、Glob 搜索、Grep 搜索、LSP 诊断等
- 工具定义为 Go 接口，不支持用户自定义扩展工具（区别于 SDK 框架）
- 无 MCP 支持（截至最新版本）

**关键差异点：**
- 这是一个**应用**而非**框架**：用户直接使用，不用于构建其他 Agent
- Go 语言实现，启动快，内存占用低
- 多模型支持是核心设计目标
- 无多 Agent / 子 Agent 机制

---

### 4. PyAgent

**架构模式：代码生成式工具调用 Agent 框架**

PyAgent（acodercat/PyAgent，现已演化为 `py-calling-agent` / CaveAgent）采用了一种独特的架构：**让 LLM 生成可执行 Python 代码来调用工具**，而非传统的 JSON Schema 工具调用协议。这是它最核心的创新。

```python
from py_calling_agent import CaveAgent, PythonRuntime, Function, Variable

# 创建运行时并注入工具和变量
runtime = PythonRuntime()
runtime.inject(Function(search_web))       # 注入可调用函数
runtime.inject(Variable("results", [], "Search results"))  # 注入持久变量

agent = CaveAgent(runtime=runtime, model=OpenAIServerModel(...))

# LLM 不会输出 JSON 工具调用，而是生成 Python 代码：
# results = search_web("Tokyo population")
# population = int(results[0]["value"])
# answer = population / 2
response = await agent.run("What is the population of Tokyo divided by 2?")
```

**三层架构：**
- **Runtime 层 (`PythonRuntime`)**：维护持久 Python 执行环境，管理 `Variable()`（真实 Python 对象）、`Function()`（可调用函数包装）、`Type()`（数据类 Schema 暴露），通过 AST 分析进行安全验证
- **Agent 编排层 (`CaveAgent`)**：管理多轮对话，协调 LLM 代码生成 → AST 安全检查 → 沙箱执行 → 结果反馈的循环
- **Skills 系统**：实现 Agent Skills 开放标准（agentskills.io），支持渐进式加载（启动时仅加载元数据 ~100 tokens，按需加载完整指令）

**核心创新 —— 代码生成 vs JSON 工具调用：**

| 维度 | PyAgent（代码生成） | 传统框架（JSON 工具调用） |
|------|-------------------|----------------------|
| 多步操作 | 一次代码生成可包含循环、条件、多次调用 | 需要多次 LLM 往返 |
| 状态管理 | 真实 Python 对象在内存中持久存在 | 通常无状态或序列化 |
| 表达能力 | 完整 Python 语法 | 受限于 JSON Schema |
| 安全性 | AST 级别验证（ImportRule/FunctionRule/AttributeRule/RegexRule） | Schema 验证 |

**多 Agent 支持：**
- 采用 **Agent-as-Object** 模式：子 Agent 作为 `Variable` 注入编排者的 Runtime
- 编排者的 LLM 生成代码直接调用 `sub_agent.run()`
- 各 Agent 维护独立 Runtime 状态

**其他特性：**
- 异步优先（`async/await`）
- 流式事件：`'code'`（生成的代码）、`'execution_output'`（执行结果）、`'reasoning'`（推理过程）
- 多模型：通过 LiteLLM 支持 100+ 模型
- **注意：这是一个小众项目**，GitHub Stars 较少，社区活跃度有限

---

## 三、关键维度深度对比

### 1. 工具系统（Tool System）

| 特性 | Claude Agent SDK | OpenAI Agent SDK | OpenCode | PyAgent |
|------|-----------------|------------------|----------|---------|
| 工具定义方式 | 内置预定义工具集 | 装饰器 + 类型推断自动生成 Schema | Go 接口实现 | Function()/Variable()/Type() 注入 Runtime |
| 调用机制 | JSON 工具调用 | JSON 工具调用 | JSON 工具调用 | **LLM 生成 Python 代码直接调用** |
| 自定义工具 | 通过 MCP Server | 函数装饰器 / Pydantic 模型 | 不支持 | Function() 包装器 |
| MCP 支持 | 原生支持 | 原生支持 | 不支持 | 不支持 |
| 工具权限控制 | allowedTools/disallowedTools | 无内置（通过 Guardrails 间接实现） | 无 | AST 规则验证 |
| Agent-as-Tool | 子 Agent 进程 | 原生 Agent-as-Tool 原语 | 无 | Agent-as-Variable |
| 托管工具 | 无 | WebSearch/FileSearch/CodeInterpreter 等 | 无 | 无 |

### 2. 多 Agent 编排

| 特性 | Claude Agent SDK | OpenAI Agent SDK | OpenCode | PyAgent |
|------|-----------------|------------------|----------|---------|
| 多 Agent 支持 | 子进程 Agent 树 | Handoff + Agent-as-Tool | 无 | Agent-as-Variable（代码生成调用） |
| 编排模式 | 层级式（父-子） | 对等式（Handoff）+ 层级式（Agent-as-Tool） | N/A | 层级式（代码生成驱动） |
| Agent 间通信 | 通过父 Agent 上下文 | 共享对话历史 + Context 对象 | N/A | 通过 Runtime 变量 |
| 并发执行 | 支持并行子 Agent | 顺序 Handoff（无并行） | N/A | 取决于生成的代码 |
| 动态路由 | 模型自主选择 | Handoff 声明 + 模型选择 | N/A | 代码逻辑决定 |

### 3. 执行模型

| 特性 | Claude Agent SDK | OpenAI Agent SDK | OpenCode | PyAgent |
|------|-----------------|------------------|----------|---------|
| 异步支持 | AsyncIterator 流式 | async/await (Runner.run) | Go goroutine | async/await 优先 |
| 同步支持 | 通过收集迭代器 | Runner.run_sync() | 原生同步 | 支持 |
| 流式输出 | 原生事件流 | RunResultStreaming | 终端实时渲染 | stream_events (code/output/reasoning) |
| 人机交互 | 工具权限审批 | interruptions 机制 | 终端交互 | 无 |
| 上下文窗口管理 | 自动压缩 + 摘要 | 手动 (to_input_list) | Provider 依赖 | Skills 渐进式加载 |

### 4. 安全与沙箱

| 特性 | Claude Agent SDK | OpenAI Agent SDK | OpenCode | PyAgent |
|------|-----------------|------------------|----------|---------|
| 沙箱执行 | 内置沙箱（Bash 命令） | 无内置沙箱 | 无 | AST 预执行验证 |
| 权限模型 | 精细工具权限 | Guardrails 三层防护 | 终端确认 | ImportRule/FunctionRule/AttributeRule |
| 网络隔离 | 可配置 | 无 | 无 | 通过 AST 规则限制 |
| 输入验证 | 工具参数验证 | Input/Output/Tool Guardrails | 基础验证 | AST + RegexRule |

---

## 四、架构哲学对比

### Claude Agent SDK — "给你一个能干活的 Agent"
- **核心思想**：不是让你「构建」Agent，而是让你「使用」一个已经非常强大的 Agent（Claude Code）
- **抽象层级最高**：开发者不需要关心 prompt engineering、工具实现、上下文管理等底层细节
- **适合场景**：自动化编程任务、CI/CD 集成、构建基于 Claude Code 的产品
- **局限**：绑定 Claude 模型，无法自定义 Agent 行为的底层逻辑

### OpenAI Agent SDK — "给你一套积木去搭 Agent"
- **核心思想**：提供原语（Agent/Tool/Handoff/Guardrails），让开发者自由组合构建 Agent 系统
- **抽象层级中等**：开发者掌控 Agent 定义、工具实现、编排逻辑
- **适合场景**：客服系统、多步骤工作流、复杂业务 Agent
- **局限**：需要更多工程投入，Agent 能力取决于开发者的 prompt 和工具设计

### OpenCode — "给你一个开源的 Claude Code"
- **核心思想**：提供完整的终端 AI 编程体验，不绑定特定模型
- **不是 SDK**：它是最终用户产品，不是开发者工具
- **适合场景**：想用开源方案替代 Claude Code / Cursor 的开发者
- **局限**：无法作为库集成，无编排能力，扩展性有限

### PyAgent — "给你一种新的工具调用范式"
- **核心思想**：让 LLM 生成代码而非 JSON 来调用工具，减少往返次数，提高表达能力
- **抽象层级独特**：不是"更简单"或"更复杂"，而是"不同的范式"——代码即工具调用
- **适合场景**：需要复杂多步工具编排（循环、条件）、对 Python 运行时状态有需求的场景
- **局限**：小众项目，社区有限；代码生成的安全性依赖 AST 验证的完备性

---

## 五、技术选型建议

| 需求场景 | 推荐选择 | 原因 |
|----------|---------|------|
| 自动化编程 / CI 集成 | Claude Agent SDK | 开箱即用的编程 Agent，工具权限精细控制 |
| 多 Agent 业务系统 | OpenAI Agent SDK | 成熟的多 Agent 编排原语（Handoff/Guardrails） |
| 开源终端编程助手 | OpenCode | 多模型支持，无供应商锁定 |
| 复杂多步工具编排 | PyAgent | 代码生成式调用，一次生成可完成多步操作 |
| 需要多模型 Agent 框架 | OpenAI Agent SDK | LiteLLM 集成支持 100+ 模型 |
| 需要严格安全控制 | Claude Agent SDK | 内置沙箱 + 工具权限模型 |

---

## 六、总结

四个项目代表了 Agent 生态中的不同层次：

1. **Claude Agent SDK** 是**最高层抽象**——它封装了一个完整的、已经过大量优化的编程 Agent，开发者获得的是"能力"而非"组件"
2. **OpenAI Agent SDK** 是**中间层框架**——它提供构建 Agent 的原语和编排能力，开发者获得的是"灵活性"
3. **OpenCode** 是**应用层产品**——它是一个可以直接使用的终端编程工具，开发者获得的是"工具"
4. **PyAgent** 是**范式创新者**——它用"LLM 生成代码"替代"JSON 工具调用"，在减少往返次数和提高表达能力方面有独到之处，但仍是小众项目

从系统架构角度看，最核心的差异在于 **"封装 vs 开放"的权衡**：
- Claude Agent SDK 选择了高度封装，以牺牲灵活性换取开箱即用的强大能力
- OpenAI Agent SDK 选择了适度开放，提供足够的原语让开发者构建多样化的 Agent 系统
- OpenCode 选择了完全开放源代码但封闭使用方式（应用而非库）
- PyAgent 选择了完全开放但功能有限
