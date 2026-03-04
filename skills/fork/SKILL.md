---
name: fork
description: "Fork current Claude Code session into N new tmux panes (or windows with --window). Triggers: /fork"
user-invocable: true
allowed-tools: Bash,Write
argument-hint: "[tasks or count]"
---

Fork branches the current conversation into N parallel child sessions, each inheriting
full conversation history via --resume --fork-session.

By default, children are created as **panes** in the current tmux window (parent on left,
children stacked on right). Use `--window` to create independent tmux windows instead.

Parse the user's input to extract tasks (list of strings), plan mode (boolean), watch mode (boolean),
and count (default 1). For each task, generate a short ASCII slug (lowercase, hyphenated, descriptive)
for naming (also used as worktree directory name in git repos).

  bash ~/.claude/scripts/claude-fork.sh [--plan] [--watch] [--window] [--no-worktree] [--count N] $PWD ["task1"] ["task2"] ...

- --window: create independent tmux windows instead of panes (override default pane behavior)
- --plan: all panes enter plan mode (maps to --permission-mode plan)
- --watch: enable status monitoring (child sessions report progress via Stop hook)
- --no-worktree: disable worktree isolation (enabled by default in git repos)
- --count N: blank fork, N panes without tasks (only when no tasks given)
- Positional args after $PWD: each task becomes one pane, N = number of tasks
- plan: prefix on individual task: that pane enters plan mode (stripped before sending)
- wt:slug: prefix on individual task: set name and worktree name (stripped before sending)
- @/path: file reference, script reads task content from file (use for multi-line prompts)
- Prefixes can combine: plan:wt:slug:@/tmp/fork-task-N.txt (plan: first, then wt:slug:, then @file)
- For multi-line or long task prompts (more than one sentence), write content to
  /tmp/fork-task-N.txt using the Write tool first, then pass @/tmp/fork-task-N.txt
  as the task argument. This prevents shell quoting issues.
- Short single-line tasks can still be passed directly as arguments.
- No tasks + no count: fork 1 blank pane

For each task, always prepend wt:slug: — the slug sets the pane title (or window name with --window)
in all cases, and additionally serves as the worktree directory name in git repos. Non-git directories
or --no-worktree skip worktree creation but the slug still sets the name.

## Pane Mode (default)

Children are created as panes in the current window. Layout: parent occupies left half,
children stacked evenly on the right half (tmux main-vertical layout). Pane borders show
titles (`{number}:{slug}`) for identification.

Limits: max 4 child panes per window. If the request exceeds available slots, excess
children are automatically created as windows. If no pane slots are available, all children
fall back to windows.

## Watch Mode (--watch)

When --watch is passed, the script:
1. Sets env vars (`CLAUDE_FORK_CHILD_ID`, `CLAUDE_FORK_STATUS_DIR`) in each pane's launch script
2. Writes `/tmp/claude-fork-status/{child-id}/pane.json` with tmux pane info
3. A Stop hook (`fork-status.sh`) writes `status.json` each time the child session completes a turn

After forking with --watch, start a `run_in_background` watcher for each child:

  s=/tmp/claude-fork-status/{child-id}/status.json; while [ ! -f "$s" ]; do fswatch -1 "$(dirname "$s")" > /dev/null; done; cat "$s"

Watches the **directory** (not the file) because `status.json` doesn't exist yet when the watcher
starts. macOS kqueue can't monitor non-existent files, but can monitor the directory for new file
creation. The while loop handles TOCTOU races and spurious directory events.

For multi-round interaction:
1. Delete the old status.json: `rm /tmp/claude-fork-status/{child-id}/status.json`
2. Send follow-up instruction: `bash ~/.claude/scripts/send-to-pane.sh {child-id} "your message"`
3. Start a new watcher (same command as above — directory still exists, watches for file recreation)

## Sending Messages to Panes

  bash ~/.claude/scripts/send-to-pane.sh <child-id> <message>

Looks up the pane's tmux_pane_id from pane.json and sends text via tmux send-keys.

Examples:

  # /fork 3 (creates 3 panes in current window)
  bash ~/.claude/scripts/claude-fork.sh --count 3 $PWD

  # /fork 分别实施 plan A 和 plan B (panes)
  bash ~/.claude/scripts/claude-fork.sh $PWD "wt:implement-plan-a:实施 plan A" "wt:implement-plan-b:实施 plan B"

  # /fork --window 后台跑 (creates independent windows)
  bash ~/.claude/scripts/claude-fork.sh --window $PWD "wt:impl-a:实施 A" "wt:research-b:研究 B"

  # /fork 进 plan mode 分别研究方案 A 和方案 B (all panes in plan mode)
  bash ~/.claude/scripts/claude-fork.sh --plan $PWD "wt:research-plan-a:研究方案 A" "wt:research-plan-b:研究方案 B"

  # /fork pane 1 实施 A, pane 2 进 plan mode 研究 B (per-pane mode + worktree)
  bash ~/.claude/scripts/claude-fork.sh $PWD "wt:impl-a:实施 A" "plan:wt:research-b:研究 B"

  # /fork without worktree isolation (slug still used for naming)
  bash ~/.claude/scripts/claude-fork.sh --no-worktree $PWD "wt:impl-a:实施 A" "wt:research-b:研究 B"

  # /fork with watch mode — delegate and wait for results
  bash ~/.claude/scripts/claude-fork.sh --watch $PWD "wt:research-a:研究方案 A" "wt:research-b:研究方案 B"

Never pass --fresh. Fork always inherits the current conversation via --resume --fork-session.

## Hierarchical Naming

The script automatically assigns hierarchical numbers based on the parent's position in the tree.
The slug you provide via `wt:slug:` becomes the name suffix: `{number}:{slug}` (e.g., `1.2:try-redis`).

- Forking from an untracked window (manually created): children get root-level numbers (1, 2, 3...)
- Forking from a tracked window (e.g., `1:research`): children get `1.1`, `1.2`, etc.
- The script handles numbering automatically — just provide the slug

All fork operations are recorded in `~/.claude/fork-tree.jsonl` for causal chain tracking.
Use `bash ~/.claude/scripts/claude-tree.sh` to visualize the tree.

Report session ID, pane count, assigned numbers, and child IDs (when --watch). Nothing else.
