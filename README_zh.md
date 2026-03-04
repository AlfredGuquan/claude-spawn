# claude-spawn

两个 skills 将编程 agent 会话 fork 或 spawn 到多个并行 tmux pane 或 window——自动携带上下文，自带 git worktree 隔离。支持 Claude Code（默认）、OpenAI CodeX 和 Google Gemini CLI。

<p align="center">
  <img src="assets/fork-demo.gif" alt="Fork 演示 — 3 个并行 pane" width="720">
</p>

## 为什么需要这个

当你在一个 Claude Code 会话里积累了丰富的上下文，想分出一部分工作——尝试不同方案、交接子任务、或者在不丢失已有信息的情况下开一个干净的会话——传统流程很繁琐。你得手动开终端、切目录、启动 Claude、写交接文档、粘贴过去，然后祈祷信息没有在传递中丢失。你变成了两个 AI 会话之间的翻译。

claude-spawn 消除了这些摩擦。`/new` 把当前上下文提炼成一个自包含的 prompt，一步启动全新会话。`/fork` 把整个对话克隆到多个并行 pane，每个 pane 都有独立的 git worktree，agent 之间不会互相干扰。

## `/new` — 携带上下文启动新会话

<p align="center">
  <img src="assets/new-demo.gif" alt="New 会话演示" width="720">
</p>

`/new` 启动一个全新的 agent 会话，只携带真正需要的上下文——不带完整对话历史的包袱。

你描述新会话要做什么，Claude 会从当前对话中提炼出相关的背景信息、文件路径和约束条件，生成一个自包含的 prompt，然后在新的 tmux window 中启动干净的会话。不需要手动写交接文档，不需要在窗口间复制粘贴，不需要你充当两个 AI 之间的翻译。

```
# 启动一个会话处理特定任务
/new 用我们刚讨论的模式重构 auth 模块

# 同时启动多个会话
/new 实现 API 接口, 写集成测试

# 启动 3 个空白会话
/new 3

# 指定其他引擎
/new codex: 实现 REST API
/new gemini: 做仪表盘 UI

# 混合派发——一次调用使用不同引擎
/new 写 auth 测试, codex: 实现 API, gemini: 做登录页

# 在独立 tmux session 中启动（不相关的工作）
/new --session-name db-migration 规划 schema 变更
```

每个 Claude 会话默认拥有独立的 git worktree，并行工作不会冲突。

## `/fork` — Fork 到并行 Pane

`/fork` 把当前会话拆分到当前 tmux window 内的 N 个新 pane。每个 pane 继承完整的对话历史，从你当前的位置继续——但在独立的 git worktree 中。

这对并行探索多种方案非常有用：不同的实现策略、不同的 UI 设计、不同的架构取舍——同时运行，互不冲突。每个 fork 都有自己的 worktree，agent 可以自由编辑、构建、测试，不会踩到彼此的文件。

```
# Fork 到 3 个空白 pane（每个都带完整对话上下文）
/fork 3

# Fork 并分配任务
/fork 实现 auth 模块, 给 auth 模块写测试

# 以 plan mode fork（所有 pane 进入 plan mode）
/fork --plan 研究方案 A, 研究方案 B

# 混合模式：一个 pane 实施，另一个规划
/fork 实施方案 A, plan: 研究方案 B

# 以独立 window 而非 pane 创建
/fork --window 实施方案 A, 研究方案 B

# 带 watch mode fork——子会话完成时收到通知
/fork --watch 研究方案 A, 研究方案 B
```

## Pane 与 Window 模式

默认情况下，`/fork` 创建 **pane**（当前 window 内分屏），`/new` 创建 **window**（独立 tmux 标签页）。可以用 `--window` 或 `--pane` 参数覆盖默认行为。

Pane 布局：父会话占左半边，子会话在右半边均匀堆叠（tmux main-vertical 布局）。每个 window 最多 4 个子 pane——超出部分自动溢出为 window。

## Watch 模式

传入 `--watch` 让父会话监控子会话进度。每个子会话通过 Stop hook 在完成一轮操作时报告状态。父会话可以读取状态文件并发送后续指令。

```
# 带 watch 的 fork——父会话等待结果
/fork --watch 研究方案 A, 研究方案 B

# 给特定子会话发送后续指令
bash ~/.claude/scripts/send-to-pane.sh <child-id> "现在实施方案 A"
```

## 层级命名

会话自动按树形结构编号。从 window `1:research` fork 出的子会话会得到 `1.1:try-redis`、`1.2:try-postgres` 等编号。用 `bash ~/.claude/scripts/claude-tree.sh` 可视化完整会话树。

## 多引擎支持

默认使用 Claude Code。可以用 `codex:` 或 `gemini:` 前缀将任务路由到 OpenAI CodeX 或 Google Gemini CLI。引擎选择是按任务粒度的，可以在一次 `/new` 调用中混合使用不同引擎。

| 引擎 | 前缀 | Plan mode | Worktree |
|------|------|-----------|----------|
| Claude Code | *（默认）* | `--permission-mode plan` | 支持 |
| OpenAI CodeX | `codex:` | `--sandbox read-only` | 不支持 |
| Google Gemini | `gemini:` | `--approval-mode plan` | 不支持 |

## 工作原理

`/fork` 使用 `claude --resume --fork-session --worktree` 让每个 pane 获得完整对话历史和独立 worktree。它包含了一个针对 [已知 Claude Code bug](https://github.com/anthropics/claude-code/issues/5768) 的 workaround——`--worktree` 会在 `--resume` 查找 session 文件之前切换工作目录，导致查找失败。脚本会预先将 session 文件 symlink 到 worktree 的项目目录中，使查找成功。

`/new` 从当前上下文构建自包含 prompt，通过 `claude --fresh --worktree` 启动干净会话，不需要 session 文件的特殊处理。

两个 skill 共用一个 bash 脚本（`scripts/claude-fork.sh`），负责 tmux pane/window 创建、worktree 设置、plan mode 标志、watch 模式、引擎派发、层级命名以及孤立 symlink 的清理。

## 环境要求

- macOS 或 Linux，安装 [tmux](https://github.com/tmux/tmux)
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) CLI
- Git 仓库（worktree 隔离需要）
- [fswatch](https://github.com/emcrisostomo/fswatch)（`--watch` 模式需要）
- *（可选）* [OpenAI CodeX](https://github.com/openai/codex) CLI，用于 `codex:` 引擎
- *（可选）* [Google Gemini](https://github.com/google-gemini/gemini-cli) CLI，用于 `gemini:` 引擎

## 安装

```bash
# 克隆
git clone https://github.com/AlfredGuquan/claude-spawn.git

# 将 skill 链接到 Claude Code 的 skill 目录
ln -s "$(pwd)/claude-spawn/skills/fork" ~/.claude/skills/fork
ln -s "$(pwd)/claude-spawn/skills/new" ~/.claude/skills/new

# 链接脚本
mkdir -p ~/.claude/scripts
ln -s "$(pwd)/claude-spawn/scripts/claude-fork.sh" ~/.claude/scripts/claude-fork.sh
ln -s "$(pwd)/claude-spawn/scripts/send-to-pane.sh" ~/.claude/scripts/send-to-pane.sh
ln -s "$(pwd)/claude-spawn/scripts/claude-tree.sh" ~/.claude/scripts/claude-tree.sh
```

## 项目结构

```
claude-spawn/
├── scripts/
│   ├── claude-fork.sh      # 核心启动器 — pane/window 创建、worktree、watch 模式
│   ├── send-to-pane.sh     # 给子 pane 发送消息
│   └── claude-tree.sh      # 可视化会话树
├── skills/
│   ├── fork/SKILL.md       # /fork skill 定义
│   └── new/SKILL.md        # /new skill 定义
```

## 许可证

MIT
