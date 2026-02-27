#!/bin/bash
# claude-fork.sh — Fork/launch Claude Code sessions in N new iTerm2 panes
# with optional task assignment, plan mode, and worktree isolation.
# Dependencies: jq, osascript (macOS)
# Usage: claude-fork.sh [--fresh] [--plan] [--no-worktree] [--count N] CWD [TASK...]

# --- Parse options ---
PLAN_MODE=""
EXPLICIT_COUNT=""
FRESH_MODE=""
NO_WORKTREE=""
while [[ "$1" == --* ]]; do
  case "$1" in
    --plan) PLAN_MODE=1; shift ;;
    --count) EXPLICIT_COUNT="$2"; shift 2 ;;
    --fresh) FRESH_MODE=1; shift ;;
    --no-worktree) NO_WORKTREE=1; shift ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

CWD="$1"; shift

if [ -z "$CWD" ]; then
  echo "Usage: claude-fork.sh [--fresh] [--plan] [--no-worktree] [--count N] CWD [TASK...]" >&2
  exit 1
fi

# Remaining args are tasks
TASKS=("$@")

# Determine pane count: task count > explicit count > default 1
if [ ${#TASKS[@]} -gt 0 ]; then
  COUNT=${#TASKS[@]}
elif [ -n "$EXPLICIT_COUNT" ]; then
  COUNT=$EXPLICIT_COUNT
else
  COUNT=1
fi

# --- Prune orphaned session symlinks from previous fork invocations ---
# Symlinks (*.jsonl -> original session file) are created for the --resume
# workaround below. They're only needed at Claude startup; safe to remove after.
# Runs on each invocation, like git-worktree-prune.
prune_fork_symlinks() {
  local projects_dir="$HOME/.claude/projects"
  [ -d "$projects_dir" ] || return 0

  local count=0
  while IFS= read -r link; do
    local target
    target=$(readlink "$link" 2>/dev/null)
    # Only remove symlinks pointing into projects dir (our creation pattern)
    if [[ "$target" == "$projects_dir"/* ]]; then
      rm -f "$link"
      ((count++))
    fi
  done < <(find "$projects_dir" -type l -name "*.jsonl" 2>/dev/null)

  # Remove now-empty directories left behind
  find "$projects_dir" -mindepth 1 -maxdepth 1 -type d -empty -delete 2>/dev/null

  if [ "$count" -gt 0 ]; then
    echo "Pruned $count orphaned session symlink(s)" >&2
  fi
}

# --- Worktree isolation ---
if [ -n "$NO_WORKTREE" ]; then
  USE_WORKTREE=""
elif git -C "$CWD" rev-parse --git-dir &>/dev/null; then
  USE_WORKTREE=1
  prune_fork_symlinks
else
  USE_WORKTREE=""
  echo "WARNING: $CWD is not a git repository, skipping worktree isolation" >&2
fi

# --- Get session ID ---
if [ -z "$FRESH_MODE" ]; then
  SESSION_ID=$(tail -r ~/.claude/history.jsonl | jq -r --arg cwd "$CWD" \
    'select(.project == $cwd) | .sessionId // empty' | head -1)

  if [ -z "$SESSION_ID" ]; then
    echo "ERROR: no session found for $CWD" >&2
    exit 1
  fi
fi

# --- Generate temp launch scripts (avoids AppleScript string escaping) ---
SCRIPT_FILES=()
for i in $(seq 1 "$COUNT"); do
  SCRIPT_FILE="/tmp/claude-fork-${$}-${i}.sh"
  TASK="${TASKS[$((i-1))]}"

  # Determine per-pane plan mode: global --plan or plan: prefix
  PANE_PLAN=""
  if [ -n "$PLAN_MODE" ]; then
    PANE_PLAN="--permission-mode plan"
  elif [[ "$TASK" == plan:* ]]; then
    PANE_PLAN="--permission-mode plan"
    TASK="${TASK#plan:}"
  fi

  # Extract worktree slug from wt:slug: prefix
  SLUG=""
  if [[ "$TASK" == wt:*:* ]]; then
    _remainder="${TASK#wt:}"
    SLUG="${_remainder%%:*}"
    TASK="${_remainder#*:}"
  fi

  # Build launch command with permission flags
  if [ -n "$FRESH_MODE" ]; then
    CMD="claude"
  else
    CMD="claude --resume ${SESSION_ID} --fork-session"
  fi
  if [ -n "$PANE_PLAN" ]; then
    # Plan mode: allow read-only tools to avoid authorization prompts
    CMD="$CMD --permission-mode plan --allowed-tools Read,Grep,Glob,WebFetch,WebSearch,Task,ToolSearch"
  else
    # Normal mode: bypass all permission checks
    CMD="$CMD --dangerously-skip-permissions"
  fi

  # Add worktree isolation via Claude's native --worktree flag.
  # Bug workaround: --worktree does process.chdir() before --resume looks up the
  # session file at ~/.claude/projects/<ZP(CWD)>/<sessionId>.jsonl. The CWD change
  # makes --resume fail with "No conversation found". Fix: pre-symlink the session
  # file into the worktree path's project dir so --resume finds it after chdir.
  # See: https://github.com/anthropics/claude-code/issues/5768
  PANE_CWD="$CWD"
  if [ -n "$USE_WORKTREE" ]; then
    if [ -z "$SLUG" ]; then
      SLUG="fork-${$}-${i}"
    fi
    CMD="$CMD --worktree ${SLUG}"
    if [ -z "$FRESH_MODE" ]; then
      # Pre-symlink session file for --resume compatibility
      REPO_ROOT=$(git -C "$CWD" rev-parse --show-toplevel)
      WT_PATH="${REPO_ROOT}/.claude/worktrees/${SLUG}"
      ORIG_ZP=$(echo "$CWD" | sed 's/[^a-zA-Z0-9]/-/g')
      WT_ZP=$(echo "$WT_PATH" | sed 's/[^a-zA-Z0-9]/-/g')
      ORIG_SESSION_FILE="$HOME/.claude/projects/${ORIG_ZP}/${SESSION_ID}.jsonl"
      if [ -f "$ORIG_SESSION_FILE" ]; then
        mkdir -p "$HOME/.claude/projects/${WT_ZP}"
        ln -sf "$ORIG_SESSION_FILE" "$HOME/.claude/projects/${WT_ZP}/${SESSION_ID}.jsonl"
      else
        echo "WARNING: session file not found at ${ORIG_SESSION_FILE}, skipping symlink" >&2
      fi
    fi
  fi

  if [ -n "$TASK" ]; then
    TASK_FILE="/tmp/claude-fork-task-${$}-${i}.txt"
    printf '%s' "$TASK" > "$TASK_FILE"
    {
      echo "#!/bin/bash"
      echo "_task=\$(cat '${TASK_FILE}')"
      echo "rm -f '${TASK_FILE}' '${SCRIPT_FILE}'"
      echo "cd '${PANE_CWD}' && exec ${CMD} -- \"\$_task\""
    } > "$SCRIPT_FILE"
  else
    {
      echo "#!/bin/bash"
      echo "rm -f '${SCRIPT_FILE}'"
      echo "cd '${PANE_CWD}' && exec ${CMD}"
    } > "$SCRIPT_FILE"
  fi

  chmod +x "$SCRIPT_FILE"
  SCRIPT_FILES+=("$SCRIPT_FILE")
done

# --- Build and execute AppleScript ---
PANES=""
for i in $(seq 1 "$COUNT"); do
  if [ "$i" -eq 1 ]; then
    SRC="current session"
  else
    SRC="s$((i-1))"
  fi
  PANES="${PANES}
        set s${i} to (split vertically with default profile of ${SRC})
        delay 1
        tell s${i} to write text \"bash ${SCRIPT_FILES[$((i-1))]}\""
done

osascript -e "
tell application \"iTerm2\"
    tell current tab of current window${PANES}
    end tell
end tell"

if [ -n "$FRESH_MODE" ]; then
  echo "Launched ${COUNT} fresh session(s)"
else
  echo "Forked session ${SESSION_ID} into ${COUNT} new pane(s)"
fi
