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

**架构模式：轻量级工具增强 Agent 框架**

PyAgent（acodercat/PyAgent）是一个较为简单的 Python Agent 框架，专注于工具增强的 LLM 交互。

```python
from pyagent import Agent, Tool

agent = Agent(
    llm_provider="openai",
    model="gpt-4",
    tools=[search_tool, calculator_tool]
)

response = agent.run("What is the population of Tokyo divided by 2?")
```

**架构特点：**
- **简单 ReAct 循环**：基于 Reasoning + Acting 模式的单 Agent 循环
- **工具注册机制**：通过 Tool 基类或装饰器注册自定义工具
- **多 LLM 支持**：通过 Provider 抽象层支持 OpenAI、Anthropic 等
- **轻量级设计**：核心代码量小，依赖少，易于理解和修改

**关键差异点：**
- 项目规模小，社区活跃度有限
- 无多 Agent 编排能力
- 无流式输出支持
- 无沙箱或安全机制
- 适合学习和小规模应用

---

## 三、关键维度深度对比

### 1. 工具系统（Tool System）

| 特性 | Claude Agent SDK | OpenAI Agent SDK | OpenCode | PyAgent |
|------|-----------------|------------------|----------|---------|
| 工具定义方式 | 内置预定义工具集 | 装饰器 + 类型推断自动生成 Schema | Go 接口实现 | 装饰器/基类注册 |
| 自定义工具 | 通过 MCP Server | 函数装饰器 / Pydantic 模型 | 不支持 | 函数装饰器 |
| MCP 支持 | 原生支持 | 原生支持 | 不支持 | 不支持 |
| 工具权限控制 | allowedTools/disallowedTools | 无内置（通过 Guardrails 间接实现） | 无 | 无 |
| Agent-as-Tool | 子 Agent 进程 | 原生 Agent-as-Tool 原语 | 无 | 无 |
| 托管工具 | 无 | WebSearch/FileSearch/CodeInterpreter 等 | 无 | 无 |

### 2. 多 Agent 编排

| 特性 | Claude Agent SDK | OpenAI Agent SDK | OpenCode | PyAgent |
|------|-----------------|------------------|----------|---------|
| 多 Agent 支持 | 子进程 Agent 树 | Handoff + Agent-as-Tool | 无 | 无 |
| 编排模式 | 层级式（父-子） | 对等式（Handoff）+ 层级式（Agent-as-Tool） | N/A | N/A |
| Agent 间通信 | 通过父 Agent 上下文 | 共享对话历史 + Context 对象 | N/A | N/A |
| 并发执行 | 支持并行子 Agent | 顺序 Handoff（无并行） | N/A | N/A |
| 动态路由 | 模型自主选择 | Handoff 声明 + 模型选择 | N/A | N/A |

### 3. 执行模型

| 特性 | Claude Agent SDK | OpenAI Agent SDK | OpenCode | PyAgent |
|------|-----------------|------------------|----------|---------|
| 异步支持 | AsyncIterator 流式 | async/await (Runner.run) | Go goroutine | 同步为主 |
| 同步支持 | 通过收集迭代器 | Runner.run_sync() | 原生同步 | 原生同步 |
| 流式输出 | 原生事件流 | RunResultStreaming | 终端实时渲染 | 无 |
| 人机交互 | 工具权限审批 | interruptions 机制 | 终端交互 | 无 |
| 上下文窗口管理 | 自动压缩 + 摘要 | 手动 (to_input_list) | Provider 依赖 | 无特殊处理 |

### 4. 安全与沙箱

| 特性 | Claude Agent SDK | OpenAI Agent SDK | OpenCode | PyAgent |
|------|-----------------|------------------|----------|---------|
| 沙箱执行 | 内置沙箱（Bash 命令） | 无内置沙箱 | 无 | 无 |
| 权限模型 | 精细工具权限 | Guardrails 三层防护 | 终端确认 | 无 |
| 网络隔离 | 可配置 | 无 | 无 | 无 |
| 输入验证 | 工具参数验证 | Input/Output/Tool Guardrails | 基础验证 | 基础验证 |

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

### PyAgent — "给你一个简单的起点"
- **核心思想**：最小化的 Agent 框架，快速上手
- **抽象层级最低**：简单的 ReAct 循环 + 工具注册
- **适合场景**：学习 Agent 开发、原型验证、小规模应用
- **局限**：功能有限，缺乏生产级特性（无流式、无安全、无多 Agent）

---

## 五、技术选型建议

| 需求场景 | 推荐选择 | 原因 |
|----------|---------|------|
| 自动化编程 / CI 集成 | Claude Agent SDK | 开箱即用的编程 Agent，工具权限精细控制 |
| 多 Agent 业务系统 | OpenAI Agent SDK | 成熟的多 Agent 编排原语（Handoff/Guardrails） |
| 开源终端编程助手 | OpenCode | 多模型支持，无供应商锁定 |
| 学习/教学/原型 | PyAgent | 代码简单，容易理解和修改 |
| 需要多模型 Agent 框架 | OpenAI Agent SDK | LiteLLM 集成支持 100+ 模型 |
| 需要严格安全控制 | Claude Agent SDK | 内置沙箱 + 工具权限模型 |

---

## 六、总结

四个项目代表了 Agent 生态中的不同层次：

1. **Claude Agent SDK** 是**最高层抽象**——它封装了一个完整的、已经过大量优化的编程 Agent，开发者获得的是"能力"而非"组件"
2. **OpenAI Agent SDK** 是**中间层框架**——它提供构建 Agent 的原语和编排能力，开发者获得的是"灵活性"
3. **OpenCode** 是**应用层产品**——它是一个可以直接使用的终端编程工具，开发者获得的是"工具"
4. **PyAgent** 是**基础层示例**——它展示了 Agent 的基本模式，适合学习和小规模使用

从系统架构角度看，最核心的差异在于 **"封装 vs 开放"的权衡**：
- Claude Agent SDK 选择了高度封装，以牺牲灵活性换取开箱即用的强大能力
- OpenAI Agent SDK 选择了适度开放，提供足够的原语让开发者构建多样化的 Agent 系统
- OpenCode 选择了完全开放源代码但封闭使用方式（应用而非库）
- PyAgent 选择了完全开放但功能有限
