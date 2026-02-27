---
name: fork
description: "Fork current Claude Code session into N new iTerm2 panes with optional task assignment. Triggers: /fork"
user-invocable: true
allowed-tools: Bash
argument-hint: "[tasks or count]"
---

Parse the user's input to extract tasks (list of strings), plan mode (boolean), and count (default 1).
For each task, generate a short ASCII slug (lowercase, hyphenated, descriptive) for worktree naming.

  bash ~/.claude/scripts/claude-fork.sh [--plan] [--no-worktree] [--count N] $PWD ["task1"] ["task2"] ...

- --plan: all panes enter plan mode (maps to --permission-mode plan)
- --no-worktree: disable worktree isolation (enabled by default in git repos)
- --count N: blank fork, N panes without tasks (only when no tasks given)
- Positional args after $PWD: each task becomes one pane, N = number of tasks
- plan: prefix on individual task: that pane enters plan mode (stripped before sending)
- wt:slug: prefix on individual task: set worktree name for that pane (stripped before sending)
- Prefixes can combine: plan:wt:slug:task (plan: first, then wt:slug:)
- No tasks + no count: fork 1 blank pane

Worktree isolation is enabled by default when CWD is a git repository.
For each task, generate a short descriptive slug and prepend wt:slug: to the task string.
Non-git directories skip worktree and share the same CWD.

Examples:

  # /fork 3
  bash ~/.claude/scripts/claude-fork.sh --count 3 $PWD

  # /fork 分别实施 plan A 和 plan B
  bash ~/.claude/scripts/claude-fork.sh $PWD "wt:implement-plan-a:实施 plan A" "wt:implement-plan-b:实施 plan B"

  # /fork 进 plan mode 分别研究方案 A 和方案 B (all panes in plan mode)
  bash ~/.claude/scripts/claude-fork.sh --plan $PWD "wt:research-plan-a:研究方案 A" "wt:research-plan-b:研究方案 B"

  # /fork pane 1 实施 A, pane 2 进 plan mode 研究 B (per-pane mode + worktree)
  bash ~/.claude/scripts/claude-fork.sh $PWD "wt:impl-a:实施 A" "plan:wt:research-b:研究 B"

  # /fork without worktree isolation
  bash ~/.claude/scripts/claude-fork.sh --no-worktree $PWD "实施 A" "研究 B"

Report session ID, pane count, and assigned tasks. Nothing else.
