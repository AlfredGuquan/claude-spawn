---
name: new
description: "Launch fresh Claude Code sessions in iTerm2 panes with context-rich prompts. Triggers: /new"
user-invocable: true
allowed-tools: Bash
argument-hint: "[tasks]"
---

For each task, construct a **self-contained prompt** that a fresh Claude Code session
(with zero prior context) can execute independently. Include relevant background,
key file paths, constraints, and acceptance criteria drawn from your current context.
Also generate a short ASCII slug (lowercase, hyphenated, descriptive) for worktree naming.

Then call:

  bash ~/.claude/scripts/claude-fork.sh --fresh [--plan] [--no-worktree] [--count N] $PWD ["prompt1"] ["prompt2"] ...

- --plan, --count, plan: prefix work identically to /fork
- --no-worktree: disable worktree isolation (enabled by default in git repos)
- wt:slug: prefix on individual task: set worktree name for that pane (stripped before sending)
- Prefixes can combine: plan:wt:slug:prompt (plan: first, then wt:slug:)
- No tasks + no count: launch 1 blank fresh session
- Each positional arg should be a complete, self-contained prompt (not a short label)

Worktree isolation is enabled by default when CWD is a git repository.
For each task, generate a short descriptive slug and prepend wt:slug: to the prompt string.
Non-git directories skip worktree and share the same CWD.

However, when CWD is already inside a git worktree (check: `git rev-parse --git-dir`
differs from `git rev-parse --git-common-dir`), default to `--no-worktree`. This starts
the fresh session in the same worktree directory, preserving all existing file changes —
typical when the previous session's context is full and the task needs to continue.
If the user explicitly wants a separate worktree for a different direction, omit --no-worktree.

Examples:

  # /new 3
  bash ~/.claude/scripts/claude-fork.sh --fresh --count 3 $PWD

  # /new 重构 auth 模块
  # → construct rich prompt from current context, then:
  bash ~/.claude/scripts/claude-fork.sh --fresh $PWD "wt:refactor-auth:<self-contained prompt with context>"

  # /new without worktree isolation
  bash ~/.claude/scripts/claude-fork.sh --fresh --no-worktree $PWD "<prompt>"

  # /new from inside a worktree (continues in same directory by default)
  # LLM detects worktree → auto-adds --no-worktree
  bash ~/.claude/scripts/claude-fork.sh --fresh --no-worktree $PWD "<self-contained prompt>"

Report pane count and summarize what each pane was tasked with.
