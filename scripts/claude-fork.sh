#!/bin/bash
# claude-fork.sh — Fork/launch coding agent sessions in N new iTerm2 panes
# with optional task assignment, plan mode, and worktree isolation.
# Supports Claude Code (default), CodeX, and Gemini via engine prefixes (codex: / gemini:).
# Dependencies: jq, osascript (macOS)
# Usage: claude-fork.sh [--fresh] [--plan] [--no-worktree] [--dry-run] [--count N] CWD [TASK...]

# Convert filesystem path to Claude Code project directory name (ZP = sanitized path)
zp() { echo "$1" | sed 's/[^a-zA-Z0-9]/-/g'; }

# --- Parse options ---
PLAN_MODE=""
EXPLICIT_COUNT=""
FRESH_MODE=""
NO_WORKTREE=""
DRY_RUN=""
while [[ "$1" == --* ]]; do
  case "$1" in
    --plan) PLAN_MODE=1; shift ;;
    --count) EXPLICIT_COUNT="$2"; shift 2 ;;
    --fresh) FRESH_MODE=1; shift ;;
    --no-worktree) NO_WORKTREE=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
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

# --- Prune fork-time symlinks and recover orphaned worktree sessions ---
# Phase 1: Remove fork-time symlinks (only needed at Claude startup).
# Phase 2: Read manifest to find cleaned-up worktrees and symlink their
#           session files into the main repo's project dir for --resume.
# Runs on each invocation, like git-worktree-prune.
prune_and_recover() {
  local projects_dir="$HOME/.claude/projects"
  local manifest="$HOME/.claude/fork-manifest.jsonl"
  [ -d "$projects_dir" ] || return 0

  # Phase 1: Prune fork-time symlinks in worktree project directories.
  # These live in dirs whose ZP name contains "-worktrees-" (from .claude/worktrees/).
  # Recovery symlinks (Phase 2) live in main repo dirs and are left untouched.
  local prune_count=0
  while IFS= read -r link; do
    local dir_name target
    dir_name=$(basename "$(dirname "$link")")
    target=$(readlink "$link" 2>/dev/null)
    if [[ "$dir_name" == *-worktrees-* ]] && [[ "$target" == "$projects_dir"/* ]]; then
      rm -f "$link"
      ((prune_count++))
    fi
  done < <(find "$projects_dir" -type l -name "*.jsonl" 2>/dev/null)
  find "$projects_dir" -mindepth 1 -maxdepth 1 -type d -empty -delete 2>/dev/null
  if [ "$prune_count" -gt 0 ]; then
    echo "Pruned $prune_count fork-time symlink(s)" >&2
  fi

  # Phase 2: Recover sessions from cleaned-up worktrees using manifest.
  [ -f "$manifest" ] || return 0
  local remaining="" recover_count=0
  while IFS= read -r entry; do
    [ -z "$entry" ] && continue
    local wt_path main_zp wt_zp
    wt_path=$(echo "$entry" | jq -r '.worktree_path')
    main_zp=$(echo "$entry" | jq -r '.main_zp')
    wt_zp=$(echo "$entry" | jq -r '.wt_zp')

    if [ -d "$wt_path" ]; then
      remaining="${remaining}${entry}"$'\n'
      continue
    fi

    # Worktree gone: symlink its session files into main repo's project dir
    local wt_project_dir="$projects_dir/$wt_zp"
    local main_project_dir="$projects_dir/$main_zp"
    if [ -d "$wt_project_dir" ]; then
      mkdir -p "$main_project_dir"
      for f in "$wt_project_dir"/*.jsonl; do
        [ -f "$f" ] || continue
        local fname
        fname=$(basename "$f")
        if [ ! -e "$main_project_dir/$fname" ]; then
          ln -sf "$f" "$main_project_dir/$fname"
          ((recover_count++))
        fi
      done
    fi
  done < "$manifest"

  # Rewrite manifest atomically (only active worktree entries remain)
  local tmp_manifest="${manifest}.tmp.$$"
  printf '%s' "$remaining" > "$tmp_manifest"
  mv "$tmp_manifest" "$manifest"

  if [ "$recover_count" -gt 0 ]; then
    echo "Recovered $recover_count session(s) from cleaned-up worktrees" >&2
  fi
}

# --- Worktree isolation ---
REPO_ROOT=""
if [ -n "$NO_WORKTREE" ]; then
  USE_WORKTREE=""
elif git -C "$CWD" rev-parse --git-dir &>/dev/null; then
  USE_WORKTREE=1
  # Resolve main repo root early (needed for session lookup fallback and worktree paths).
  # --git-common-dir always returns the main repo's .git, even from inside a worktree.
  GIT_COMMON_DIR=$(git -C "$CWD" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
  if [ -z "$GIT_COMMON_DIR" ]; then
    GIT_COMMON_DIR=$(cd "$CWD" && realpath "$(git rev-parse --git-common-dir)")
  fi
  REPO_ROOT=$(dirname "$GIT_COMMON_DIR")
  prune_and_recover
else
  USE_WORKTREE=""
  echo "WARNING: $CWD is not a git repository, skipping worktree isolation" >&2
fi

# --- Get session ID ---
if [ -z "$FRESH_MODE" ]; then
  SESSION_ID=$(tail -r ~/.claude/history.jsonl | jq -r --arg cwd "$CWD" \
    'select(.project == $cwd) | .sessionId // empty' | head -1)

  # Fallback: history.jsonl records project as main repo path, not worktree path.
  # Look for session files directly in the CWD's project directory instead.
  if [ -z "$SESSION_ID" ]; then
    SESSION_FILE=$(ls -t "$HOME/.claude/projects/$(zp "$CWD")"/*.jsonl 2>/dev/null | head -1)
    if [ -n "$SESSION_FILE" ]; then
      SESSION_ID=$(basename "$SESSION_FILE" .jsonl)
    fi
  fi

  if [ -z "$SESSION_ID" ]; then
    echo "ERROR: no session found for $CWD" >&2
    exit 1
  fi
fi

# --- Pre-compute fixed ZP values for worktree symlinks ---
CWD_ZP=$(zp "$CWD")
if [ -n "$REPO_ROOT" ]; then
  MAIN_ZP=$(zp "$REPO_ROOT")
fi

# --- Generate temp launch scripts (avoids AppleScript string escaping) ---
SCRIPT_FILES=()
for i in $(seq 1 "$COUNT"); do
  SCRIPT_FILE="/tmp/claude-fork-${$}-${i}.sh"
  TASK="${TASKS[$((i-1))]}"

  # Extract engine prefix (codex: or gemini:, default claude)
  ENGINE="claude"
  if [[ "$TASK" == codex:* ]]; then
    ENGINE="codex"; TASK="${TASK#codex:}"
  elif [[ "$TASK" == gemini:* ]]; then
    ENGINE="gemini"; TASK="${TASK#gemini:}"
  fi

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

  # Expand @file reference: read task content from file, then clean up
  if [[ "$TASK" == @* ]]; then
    TASK_FILE_REF="${TASK#@}"
    if [ ! -f "$TASK_FILE_REF" ]; then
      echo "ERROR: task file not found: $TASK_FILE_REF" >&2
      exit 1
    fi
    TASK=$(cat "$TASK_FILE_REF")
    rm -f "$TASK_FILE_REF"
  fi

  RESOLVED_TASKS[$((i-1))]="$TASK"
  RESOLVED_ENGINES[$((i-1))]="$ENGINE"

  # Dry-run: only resolve tasks, skip all file I/O and side effects
  [ -n "$DRY_RUN" ] && continue

  # Build launch command based on engine
  case "$ENGINE" in
    claude)
      if [ -n "$FRESH_MODE" ]; then
        CMD="claude"
      else
        CMD="claude --resume ${SESSION_ID} --fork-session"
      fi
      if [ -n "$PANE_PLAN" ]; then
        CMD="$CMD --permission-mode plan --allow-dangerously-skip-permissions --allowed-tools Read,Grep,Glob,WebFetch,WebSearch,Task,ToolSearch,Bash,Agent"
      else
        CMD="$CMD --dangerously-skip-permissions"
      fi
      ;;
    codex)
      CMD="codex"
      [ -n "$PANE_PLAN" ] && CMD="$CMD --sandbox read-only"
      ;;
    gemini)
      CMD="gemini"
      if [ -n "$PANE_PLAN" ]; then
        CMD="$CMD --approval-mode plan"
      else
        CMD="$CMD --approval-mode yolo"
      fi
      ;;
  esac

  # Add worktree isolation via Claude's native --worktree flag.
  # Bug workaround: --worktree does process.chdir() before --resume looks up the
  # session file at ~/.claude/projects/<ZP(CWD)>/<sessionId>.jsonl. The CWD change
  # makes --resume fail with "No conversation found". Fix: pre-symlink the session
  # file into the worktree path's project dir so --resume finds it after chdir.
  # See: https://github.com/anthropics/claude-code/issues/5768
  PANE_CWD="$CWD"
  if [ -n "$SLUG" ] && [ "$ENGINE" != "claude" ]; then
    echo "WARNING: wt:$SLUG: ignored (worktree only supported for Claude)" >&2
  fi
  if [ -n "$USE_WORKTREE" ] && [ "$ENGINE" = "claude" ]; then
    if [ -z "$SLUG" ]; then
      SLUG="fork-${$}-${i}"
    fi
    CMD="$CMD --worktree ${SLUG}"

    # REPO_ROOT already computed above (worktree isolation section)
    WT_PATH="${REPO_ROOT}/.claude/worktrees/${SLUG}"
    PANE_CWD="$REPO_ROOT"

    WT_ZP=$(zp "$WT_PATH")

    if [ -z "$FRESH_MODE" ]; then
      # Pre-symlink session file for --resume compatibility
      ORIG_SESSION_FILE="$HOME/.claude/projects/${CWD_ZP}/${SESSION_ID}.jsonl"
      if [ -f "$ORIG_SESSION_FILE" ]; then
        mkdir -p "$HOME/.claude/projects/${WT_ZP}"
        ln -sf "$ORIG_SESSION_FILE" "$HOME/.claude/projects/${WT_ZP}/${SESSION_ID}.jsonl"
      else
        echo "WARNING: session file not found at ${ORIG_SESSION_FILE}, skipping symlink" >&2
      fi
    fi

    # Record worktree mapping for session recovery after cleanup
    jq -cn --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
           --arg sid "${SESSION_ID:-}" --arg slug "$SLUG" \
           --arg repo "$REPO_ROOT" --arg wt "$WT_PATH" \
           --arg mzp "$MAIN_ZP" --arg wzp "$WT_ZP" \
      '{ts:$ts,parent_session_id:$sid,slug:$slug,main_repo:$repo,worktree_path:$wt,main_zp:$mzp,wt_zp:$wzp}' \
      >> "$HOME/.claude/fork-manifest.jsonl"
  fi

  if [ -n "$TASK" ]; then
    TASK_FILE="/tmp/claude-fork-task-${$}-${i}.txt"
    printf '%s' "$TASK" > "$TASK_FILE"
    {
      echo "#!/bin/bash"
      echo "_task=\$(cat '${TASK_FILE}')"
      echo "rm -f '${TASK_FILE}' '${SCRIPT_FILE}'"
      if [ "$ENGINE" = "claude" ]; then
        echo "cd '${PANE_CWD}' && exec ${CMD} -- \"\$_task\""
      else
        echo "cd '${PANE_CWD}' && exec ${CMD} \"\$_task\""
      fi
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

# --- Dry-run: print resolved tasks and exit ---
if [ -n "$DRY_RUN" ]; then
  echo "TASK_COUNT=$COUNT"
  for i in $(seq 0 $((COUNT-1))); do
    echo "TASK_$((i+1))_ENGINE=${RESOLVED_ENGINES[$i]}"
    echo "TASK_$((i+1))_LENGTH=${#RESOLVED_TASKS[$i]}"
    echo "TASK_$((i+1))_FIRST_LINE=$(echo "${RESOLVED_TASKS[$i]}" | head -1)"
  done
  exit 0
fi

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
