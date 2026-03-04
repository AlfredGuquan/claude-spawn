#!/bin/bash
# claude-fork.sh — Fork/launch coding agent sessions as tmux panes or windows
# with optional task assignment, plan mode, and worktree isolation.
# fork (default) creates panes in current window; --fresh creates new windows.
# Supports Claude Code (default), CodeX, and Gemini via engine prefixes (codex: / gemini:).
# Dependencies: jq, tmux
# Usage: claude-fork.sh [--fresh] [--plan] [--watch] [--pane] [--window] [--no-worktree] [--dry-run] [--count N] CWD [TASK...]

# Convert filesystem path to Claude Code project directory name (ZP = sanitized path)
zp() { echo "$1" | sed 's/[^a-zA-Z0-9]/-/g'; }

# --- Parse options ---
PLAN_MODE=""
EXPLICIT_COUNT=""
FRESH_MODE=""
NO_WORKTREE=""
DRY_RUN=""
WATCH=""
NEW_SESSION_NAME=""
LAYOUT_PANE=""
LAYOUT_WINDOW=""
while [[ "$1" == --* ]]; do
  case "$1" in
    --plan) PLAN_MODE=1; shift ;;
    --count) EXPLICIT_COUNT="$2"; shift 2 ;;
    --fresh) FRESH_MODE=1; shift ;;
    --no-worktree) NO_WORKTREE=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --watch) WATCH=1; shift ;;
    --session-name) NEW_SESSION_NAME="$2"; shift 2 ;;
    --pane) LAYOUT_PANE=1; shift ;;
    --window) LAYOUT_WINDOW=1; shift ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

CWD="$1"; shift

if [ -z "$CWD" ]; then
  echo "Usage: claude-fork.sh [--fresh] [--plan] [--pane] [--window] [--no-worktree] [--count N] CWD [TASK...]" >&2
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

# --- Determine layout mode: pane (split current window) or window (new tmux window) ---
# Default: fork → pane, new (--fresh) → window. Explicit --pane/--window flags override.
if [ -n "$LAYOUT_WINDOW" ]; then
  USE_PANE=""
elif [ -n "$LAYOUT_PANE" ]; then
  USE_PANE=1
elif [ -n "$FRESH_MODE" ]; then
  USE_PANE=""   # new → window
else
  USE_PANE=1    # fork → pane
fi
# Not inside tmux: cannot split, degrade to window
if [ -n "$USE_PANE" ] && [ -z "$TMUX_PANE" ]; then
  echo "WARNING: Not inside tmux, falling back to window mode." >&2
  USE_PANE=""
fi
# --session-name targets a different session: cannot split current window, degrade
if [ -n "$USE_PANE" ] && [ -n "$NEW_SESSION_NAME" ]; then
  echo "WARNING: --session-name incompatible with pane mode, falling back to window mode." >&2
  USE_PANE=""
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

# --- Get parent session ID (for manifest/registry) and resume session ID ---
PARENT_SESSION_ID=$(tail -r ~/.claude/history.jsonl | jq -r --arg cwd "$CWD" \
  'select(.project == $cwd) | .sessionId // empty' | head -1)

# Fallback: history.jsonl records project as main repo path, not worktree path.
# Look for session files directly in the CWD's project directory instead.
if [ -z "$PARENT_SESSION_ID" ]; then
  SESSION_FILE=$(ls -t "$HOME/.claude/projects/$(zp "$CWD")"/*.jsonl 2>/dev/null | head -1)
  if [ -n "$SESSION_FILE" ]; then
    PARENT_SESSION_ID=$(basename "$SESSION_FILE" .jsonl)
  fi
fi

if [ -z "$FRESH_MODE" ]; then
  SESSION_ID="$PARENT_SESSION_ID"
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
CHILD_IDS=()
FORK_STATUS_DIR="/tmp/claude-fork-status"
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
           --arg sid "${PARENT_SESSION_ID:-}" --arg slug "$SLUG" \
           --arg repo "$REPO_ROOT" --arg wt "$WT_PATH" \
           --arg mzp "$MAIN_ZP" --arg wzp "$WT_ZP" \
      '{ts:$ts,parent_session_id:$sid,slug:$slug,main_repo:$repo,worktree_path:$wt,main_zp:$mzp,wt_zp:$wzp}' \
      >> "$HOME/.claude/fork-manifest.jsonl"
  fi

  # Determine child ID for this pane (reuse SLUG if available, else generate)
  CHILD_ID="${SLUG:-fork-${$}-${i}}"
  CHILD_IDS+=("$CHILD_ID")

  # Build watch env exports for launch script
  WATCH_EXPORTS=""
  if [ -n "$WATCH" ] && [ "$ENGINE" = "claude" ]; then
    WATCH_EXPORTS="export CLAUDE_FORK_CHILD_ID='${CHILD_ID}'
export CLAUDE_FORK_STATUS_DIR='${FORK_STATUS_DIR}'
"
  fi

  if [ -n "$TASK" ]; then
    TASK_FILE="/tmp/claude-fork-task-${$}-${i}.txt"
    printf '%s' "$TASK" > "$TASK_FILE"
    {
      echo "#!/bin/bash"
      echo "unset CLAUDECODE CLAUDE_CODE_ENTRYPOINT"
      [ -n "$WATCH_EXPORTS" ] && printf '%s' "$WATCH_EXPORTS"
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
      echo "unset CLAUDECODE CLAUDE_CODE_ENTRYPOINT"
      [ -n "$WATCH_EXPORTS" ] && printf '%s' "$WATCH_EXPORTS"
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

# --- Hierarchical numbering helpers ---
# Compute the next available child number from fork-tree.jsonl history.
# All modes (pane and window) use this single source to ensure globally unique numbers.
next_child_number_from_jsonl() {
  local parent="$1"
  local session="$2"
  local tree="$HOME/.claude/fork-tree.jsonl"
  if [ -z "$parent" ]; then
    local max_n=$(jq -r --arg s "$session" \
      'select(.tmux_session == $s) | .number' "$tree" 2>/dev/null \
      | grep -oE '^[0-9]+$' | sort -n | tail -1)
    echo $((${max_n:-0} + 1))
  else
    local escaped="${parent//./\\.}"
    local max_n=$(jq -r --arg s "$session" \
      'select(.tmux_session == $s) | .number' "$tree" 2>/dev/null \
      | grep -oE "^${escaped}\.([0-9]+)$" | grep -oE '[0-9]+$' | sort -n | tail -1)
    echo "${parent}.$((${max_n:-0} + 1))"
  fi
}

# --- Create tmux panes/windows ---
# Default: fork creates panes (split current window), new creates windows.
# Falls back to a detached 'claude-fork' session if not inside tmux.

# Determine parent number for hierarchical naming.
# Prefer manifest lookup (reliable even if window was renamed), fallback to window name parsing.
PARENT_NUMBER=""
PARENT_TMUX_SESSION=""
if [ -n "$TMUX_PANE" ]; then
  CURRENT_PANE_ID=$(tmux display-message -p '#{pane_id}')
  PARENT_TMUX_SESSION=$(tmux display-message -p '#S')
  if [ -f "$HOME/.claude/fork-tree.jsonl" ]; then
    PARENT_NUMBER=$(jq -r --arg pid "$CURRENT_PANE_ID" \
      'select(.tmux_pane_id == $pid) | .number' \
      "$HOME/.claude/fork-tree.jsonl" | tail -1)
  fi
  if [ -z "$PARENT_NUMBER" ]; then
    CURRENT_WIN_NAME=$(tmux display-message -p '#W')
    PARENT_NUMBER=$(echo "$CURRENT_WIN_NAME" | grep -oE '^[0-9]+(\.[0-9]+)*:' | sed 's/:$//' || true)
  fi
fi

# Determine target tmux session: --session-name creates/reuses a named session.
if [ -n "$NEW_SESSION_NAME" ] && [ -n "$FRESH_MODE" ]; then
  TMUX_SESSION="$NEW_SESSION_NAME"
  if ! tmux has-session -t "=$TMUX_SESSION" 2>/dev/null; then
    tmux new-session -d -s "$TMUX_SESSION"
    echo "Created tmux session '${TMUX_SESSION}'. Attach with: tmux attach -t ${TMUX_SESSION}" >&2
  fi
elif [ -n "$TMUX_PANE" ]; then
  TMUX_SESSION=$(tmux display-message -p '#S')
else
  TMUX_SESSION="claude-fork"
  if ! tmux has-session -t "=$TMUX_SESSION" 2>/dev/null; then
    tmux new-session -d -s "$TMUX_SESSION"
    echo "Created tmux session '${TMUX_SESSION}'. Attach with: tmux attach -t ${TMUX_SESSION}" >&2
  fi
fi

# If --session-name points to a different session, clear parent number
# (new session = new tree, children start from root level).
if [ -n "$NEW_SESSION_NAME" ] && [ "$TMUX_SESSION" != "${PARENT_TMUX_SESSION:-}" ]; then
  PARENT_TMUX_SESSION="${PARENT_TMUX_SESSION:-$TMUX_SESSION}"
  # Keep PARENT_NUMBER for cross-session reference in manifest, but don't use it for child numbering
  CROSS_SESSION_PARENT_NUMBER="$PARENT_NUMBER"
  PARENT_NUMBER=""
fi

# --- Pane limit check (pane mode only) ---
PANE_TASK_COUNT=$COUNT
WINDOW_TASK_COUNT=0
if [ -n "$USE_PANE" ]; then
  CURRENT_PANE_COUNT=$(tmux list-panes 2>/dev/null | wc -l | tr -d ' ')
  AVAILABLE_SLOTS=$((5 - CURRENT_PANE_COUNT))  # 5 = parent(1) + max children(4)
  if [ "$AVAILABLE_SLOTS" -le 0 ]; then
    echo "WARNING: Window pane limit reached. Falling back to window mode." >&2
    USE_PANE=""
  elif [ "$COUNT" -gt "$AVAILABLE_SLOTS" ]; then
    PANE_TASK_COUNT=$AVAILABLE_SLOTS
    WINDOW_TASK_COUNT=$((COUNT - AVAILABLE_SLOTS))
    echo "WARNING: Only $AVAILABLE_SLOTS pane slot(s) available. First $PANE_TASK_COUNT as pane(s), remaining $WINDOW_TASK_COUNT as window(s)." >&2
  fi
fi

PANE_INFO_LINES=()
WIN_NUMBERS=()
LAST_CHILD_PANE=""
for i in $(seq 1 "$COUNT"); do
  SCRIPT_FILE="${SCRIPT_FILES[$((i-1))]}"
  WIN_SLUG="${CHILD_IDS[$((i-1))]:-fork}"

  if [ -n "$USE_PANE" ] && [ "$i" -le "$PANE_TASK_COUNT" ]; then
    # --- Pane path: split current window ---
    # Use JSONL for numbering (pane children have no window name for list-windows to see)
    WIN_NUMBER=$(next_child_number_from_jsonl "$PARENT_NUMBER" "$TMUX_SESSION")
    if [ "$i" -eq 1 ]; then
      # First child: split horizontally (right side)
      TMUX_PANE_ID=$(tmux split-window -h -d -t "$CURRENT_PANE_ID" -P -F '#{pane_id}' "bash ${SCRIPT_FILE}")
    else
      # Subsequent: split last child vertically (stack on right)
      TMUX_PANE_ID=$(tmux split-window -v -d -t "$LAST_CHILD_PANE" -P -F '#{pane_id}' "bash ${SCRIPT_FILE}")
    fi
    LAST_CHILD_PANE="$TMUX_PANE_ID"
    # Set pane title for border display, then lock it so the child app can't overwrite
    tmux select-pane -t "$TMUX_PANE_ID" -T "${WIN_NUMBER}:${WIN_SLUG}"
    tmux set-option -p -t "$TMUX_PANE_ID" allow-set-title off
  else
    # --- Window path: create new tmux window ---
    WIN_NUMBER=$(next_child_number_from_jsonl "$PARENT_NUMBER" "$TMUX_SESSION")
    WIN_NAME="${WIN_NUMBER}:${WIN_SLUG}"
    TMUX_PANE_ID=$(tmux new-window -d -n "$WIN_NAME" -t "=$TMUX_SESSION" -P -F '#{pane_id}' "bash ${SCRIPT_FILE}")
  fi

  WIN_NUMBERS+=("$WIN_NUMBER")
  TMUX_TTY=$(tmux display-message -p -t "$TMUX_PANE_ID" '#{pane_tty}')
  PANE_INFO_LINES+=("${TMUX_PANE_ID}|${TMUX_TTY}")

  # Write tree manifest entry
  local_parent_number="${PARENT_NUMBER:-${CROSS_SESSION_PARENT_NUMBER:-}}"
  local_parent_session="${PARENT_TMUX_SESSION:-$TMUX_SESSION}"
  jq -cn \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg number "$WIN_NUMBER" \
    --arg slug "${WIN_SLUG}" \
    --arg tmux_session "$TMUX_SESSION" \
    --arg tmux_pane_id "$TMUX_PANE_ID" \
    --arg parent_number "$local_parent_number" \
    --arg parent_tmux_session "$local_parent_session" \
    --arg child_id "${CHILD_IDS[$((i-1))]:-fork-${$}-${i}}" \
    --arg task_summary "${RESOLVED_TASKS[$((i-1))]:0:80}" \
    '{ts:$ts,number:$number,slug:$slug,tmux_session:$tmux_session,tmux_pane_id:$tmux_pane_id,parent_number:$parent_number,parent_tmux_session:$parent_tmux_session,child_id:$child_id,task_summary:$task_summary}' \
    >> "$HOME/.claude/fork-tree.jsonl"
done

# --- Pane layout and border setup (pane mode only) ---
if [ -n "$USE_PANE" ] && [ "$PANE_TASK_COUNT" -gt 0 ]; then
  # Apply main-vertical layout: parent left, children stacked evenly on right
  tmux select-layout main-vertical
  # Set parent pane title, lock it
  tmux select-pane -t "$CURRENT_PANE_ID" -T "parent"
  tmux set-option -p -t "$CURRENT_PANE_ID" allow-set-title off
  # Enable pane border display for this window only
  CURRENT_WIN=$(tmux display-message -p '#{window_id}')
  tmux set-option -w -t "$CURRENT_WIN" pane-border-status top
  tmux set-option -w -t "$CURRENT_WIN" pane-border-format " #T "
fi

PANE_INFO=$(printf '%s\n' "${PANE_INFO_LINES[@]}")

# --- Write pane registry ---
if [ -n "$WATCH" ]; then
  LINE_NUM=0
  while IFS='|' read -r TMUX_ID TMUX_TTY; do
    [ -z "$TMUX_ID" ] && continue
    CID="${CHILD_IDS[$LINE_NUM]}"
    TASK_SUMMARY="${RESOLVED_TASKS[$LINE_NUM]}"
    TASK_SUMMARY="${TASK_SUMMARY:0:100}"
    PANE_DIR="${FORK_STATUS_DIR}/${CID}"
    mkdir -p "$PANE_DIR"
    jq -cn \
      --arg child_id "$CID" \
      --arg tmux_pane_id "$TMUX_ID" \
      --arg tty "$TMUX_TTY" \
      --arg task_summary "$TASK_SUMMARY" \
      --argjson watch true \
      --arg parent_session_id "${PARENT_SESSION_ID:-}" \
      '{child_id:$child_id, tmux_pane_id:$tmux_pane_id, tty:$tty, task_summary:$task_summary, watch:$watch, parent_session_id:$parent_session_id}' \
      > "${PANE_DIR}/pane.json"
    LINE_NUM=$((LINE_NUM + 1))
  done <<< "$PANE_INFO"
fi

# --- Output ---
WATCH_LABEL=""
[ -n "$WATCH" ] && WATCH_LABEL=" [watch mode]"

if [ -n "$FRESH_MODE" ]; then
  echo "Launched ${COUNT} fresh session(s) in ${TMUX_SESSION}${WATCH_LABEL}"
elif [ -n "$USE_PANE" ] && [ "$WINDOW_TASK_COUNT" -gt 0 ]; then
  echo "Forked session ${SESSION_ID} into ${PANE_TASK_COUNT} pane(s) + ${WINDOW_TASK_COUNT} window(s) in ${TMUX_SESSION}${WATCH_LABEL}"
elif [ -n "$USE_PANE" ]; then
  echo "Forked session ${SESSION_ID} into ${COUNT} new pane(s) in ${TMUX_SESSION}${WATCH_LABEL}"
else
  echo "Forked session ${SESSION_ID} into ${COUNT} new window(s) in ${TMUX_SESSION}${WATCH_LABEL}"
fi

# Always show window assignments (number:slug)
LINE_NUM=0
while IFS='|' read -r TMUX_ID TMUX_TTY; do
  [ -z "$TMUX_ID" ] && continue
  CID="${CHILD_IDS[$LINE_NUM]}"
  WIN_NUM="${WIN_NUMBERS[$LINE_NUM]}"
  TASK_PREVIEW="${RESOLVED_TASKS[$LINE_NUM]}"
  TASK_PREVIEW="${TASK_PREVIEW:0:60}"
  [ ${#RESOLVED_TASKS[$LINE_NUM]} -gt 60 ] && TASK_PREVIEW="${TASK_PREVIEW}..."
  if [ -n "$WATCH" ]; then
    echo "  ${WIN_NUM}:${CID}: ${TASK_PREVIEW:-<blank>} (tty: ${TMUX_TTY})"
  else
    echo "  ${WIN_NUM}:${CID}"
  fi
  LINE_NUM=$((LINE_NUM + 1))
done <<< "$PANE_INFO"

# Hint: when not inside tmux, print attach command for quick access
if [ -z "$TMUX_PANE" ]; then
  echo "Attach: tmux a -t ${TMUX_SESSION}"
fi
