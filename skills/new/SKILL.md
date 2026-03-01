---
name: new
description: "Launch fresh agent sessions (Claude/CodeX/Gemini) in iTerm2 panes with context-rich prompts. Triggers: /new"
user-invocable: true
allowed-tools: Bash,Write
argument-hint: "[tasks]"
---

For each task, construct a **self-contained prompt** that a fresh agent session
(with zero prior context) can execute independently. Include relevant background,
key file paths, constraints, and acceptance criteria drawn from your current context.
Also generate a short ASCII slug (lowercase, hyphenated, descriptive) for worktree naming
(Claude tasks only).

IMPORTANT: Always write prompts to temp files before calling the script. Use the Write
tool to create /tmp/new-task-N.txt (N = 1-based task index), then pass @/tmp/new-task-N.txt
as the prompt argument. This prevents shell quoting issues with multi-line strings and
special characters. Do NOT pass prompt text directly as a command-line argument.

Then call:

  bash ~/.claude/scripts/claude-fork.sh --fresh [--plan] [--no-worktree] [--count N] $PWD ["wt:slug:@/tmp/new-task-1.txt"] ...

- --plan, --count, plan: prefix work identically to /fork
- --no-worktree: disable worktree isolation (enabled by default in git repos)
- wt:slug: prefix on individual task: set worktree name for that pane (stripped before sending)
- @/path: file reference, script reads content from file (use for all prompts)
- Prefixes can combine: plan:wt:slug:@/tmp/new-task-N.txt (plan: first, then wt:slug:, then @file)
- No tasks + no count: launch 1 blank fresh session
- Each positional arg should reference a file containing a complete, self-contained prompt

Engine prefixes (codex: / gemini:):
- Default engine is Claude. Only use codex: or gemini: when the user explicitly requests it.
- codex: prefix routes the task to OpenAI CodeX (interactive TUI). Good for backend tasks.
- gemini: prefix routes the task to Google Gemini CLI (interactive REPL). Good for UI/frontend.
- Engine prefix is the outermost: codex:plan:@/tmp/file or gemini:@/tmp/file
- CodeX/Gemini tasks do NOT get wt:slug: prefix (no worktree isolation).
- Plan mode mapping: codex: uses --sandbox read-only, gemini: uses --approval-mode plan.
- Mixed dispatch is supported: different tasks in one call can target different engines.

Worktree isolation is enabled by default when CWD is a git repository.
For each task, generate a short descriptive slug and prepend wt:slug: to the argument.
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
  # Step 1: Write tool → /tmp/new-task-1.txt (self-contained prompt with context)
  # Step 2:
  bash ~/.claude/scripts/claude-fork.sh --fresh $PWD "wt:refactor-auth:@/tmp/new-task-1.txt"

  # /new 两个任务
  # Step 1: Write tool → /tmp/new-task-1.txt, /tmp/new-task-2.txt
  # Step 2:
  bash ~/.claude/scripts/claude-fork.sh --fresh $PWD \
    "wt:task-a:@/tmp/new-task-1.txt" \
    "wt:task-b:@/tmp/new-task-2.txt"

  # /new without worktree isolation
  # Step 1: Write tool → /tmp/new-task-1.txt
  # Step 2:
  bash ~/.claude/scripts/claude-fork.sh --fresh --no-worktree $PWD "@/tmp/new-task-1.txt"

  # /new from inside a worktree (continues in same directory by default)
  # LLM detects worktree → auto-adds --no-worktree
  # Step 1: Write tool → /tmp/new-task-1.txt
  # Step 2:
  bash ~/.claude/scripts/claude-fork.sh --fresh --no-worktree $PWD "@/tmp/new-task-1.txt"

  # /new 派 CodeX 做后端 API
  # Step 1: Write tool → /tmp/new-task-1.txt
  # Step 2:
  bash ~/.claude/scripts/claude-fork.sh --fresh $PWD "codex:@/tmp/new-task-1.txt"

  # /new 混合派发: Claude 写测试, CodeX 做 API, Gemini 做 UI
  # Step 1: Write tool → /tmp/new-task-1.txt, /tmp/new-task-2.txt, /tmp/new-task-3.txt
  # Step 2:
  bash ~/.claude/scripts/claude-fork.sh --fresh $PWD \
    "wt:write-tests:@/tmp/new-task-1.txt" \
    "codex:@/tmp/new-task-2.txt" \
    "gemini:@/tmp/new-task-3.txt"

  # /new CodeX with plan mode
  bash ~/.claude/scripts/claude-fork.sh --fresh $PWD "codex:plan:@/tmp/new-task-1.txt"

Report pane count and summarize what each pane was tasked with (including which engine).
