#!/bin/bash
# claude-tree.sh — Display hierarchical tree of fork/new windows from fork-tree.jsonl.
# Shows per-session trees with cross-session references (⊳/⊲).
# Dependencies: jq, tmux (optional, for run/done status)
# Usage: claude-tree.sh [--all | --trace <number> | <session-name>]

TREE_FILE="$HOME/.claude/fork-tree.jsonl"

if [ ! -f "$TREE_FILE" ]; then
  echo "No tree data found at $TREE_FILE" >&2
  exit 1
fi

# --- Collect active tmux panes for status detection ---
# Format: "pane_id|session_name|window_name" per line
ACTIVE_PANES=""
if command -v tmux &>/dev/null && tmux list-sessions &>/dev/null 2>&1; then
  ACTIVE_PANES=$(tmux list-panes -a -F '#{pane_id}|#{session_name}|#{window_name}' 2>/dev/null)
fi

# Check if a pane is still running by cross-validating pane_id + session + window name.
# Window-mode entries match the full triple (pane_id|session|number:slug).
# Pane-mode entries (no independent window name) fall back to pane_id|session match.
status_of() {
  local pane_id="$1" session="$2" number="$3" slug="$4"
  local win_name="${number}:${slug}"
  if [ -z "$ACTIVE_PANES" ]; then
    echo "done"
  elif echo "$ACTIVE_PANES" | grep -qF "${pane_id}|${session}|${win_name}"; then
    echo "run"
  elif echo "$ACTIVE_PANES" | grep -q "^${pane_id}|${session}|"; then
    echo "run"
  else
    echo "done"
  fi
}

# --- Parse arguments ---
MODE="current"
TARGET=""
case "${1:-}" in
  --all) MODE="all" ;;
  --trace)
    MODE="trace"
    TARGET="${2:?Usage: claude-tree.sh --trace <number>}"
    ;;
  --help|-h)
    echo "Usage: claude-tree.sh [--all | --trace <number> | <session-name>]"
    exit 0
    ;;
  "")
    MODE="current"
    ;;
  *)
    MODE="named"
    TARGET="$1"
    ;;
esac

# Determine current tmux session
CURRENT_SESSION=""
if [ "$MODE" = "current" ]; then
  if [ -n "$TMUX_PANE" ]; then
    CURRENT_SESSION=$(tmux display-message -p '#S')
  else
    echo "Not in a tmux session. Use: claude-tree.sh <session-name> or --all" >&2
    exit 1
  fi
  TARGET="$CURRENT_SESSION"
fi

# --- Render tree for a single session ---
render_session() {
  local session="$1"
  local tree_file="$2"

  # Get all nodes belonging to this session
  local nodes
  nodes=$(grep "\"tmux_session\":\"${session}\"" "$tree_file" | jq -s '.')

  local node_count
  node_count=$(echo "$nodes" | jq 'length')
  [ "$node_count" -eq 0 ] && return

  # Check if this session was spawned from another session
  local origin_info=""
  local first_root_parent_session
  first_root_parent_session=$(echo "$nodes" | jq -r '
    [.[] | select(.parent_tmux_session != "" and .parent_tmux_session != "'"$session"'")] |
    if length > 0 then .[0] | "\(.parent_tmux_session):\(.parent_number)" else "" end
  ')
  if [ -n "$first_root_parent_session" ]; then
    origin_info="   ⊲ from ${first_root_parent_session}"
  fi

  # Find outbound session spawns (other sessions whose parent_tmux_session is this session)
  local outbound_refs
  outbound_refs=$(grep "\"parent_tmux_session\":\"${session}\"" "$tree_file" \
    | jq -r --arg s "$session" 'select(.tmux_session != $s) | "\(.parent_number)|\(.tmux_session)"' \
    | sort -u)

  # Print session header
  local header="══ ${session} "
  local pad_len=$((40 - ${#header}))
  [ "$pad_len" -lt 1 ] && pad_len=1
  printf '%s' "$header"
  printf '═%.0s' $(seq 1 "$pad_len")
  echo ""
  [ -n "$origin_info" ] && echo "$origin_info"
  echo ""

  # Build and render the tree using jq
  # Output format: each line is "flags+is_last|number|slug|pane_id" or "flags+is_last|⊳|session_name|"
  # Then bash handles the tree drawing characters
  local tree_lines
  tree_lines=$(echo "$nodes" | jq -r --argjson refs "$(
    if [ -n "$outbound_refs" ]; then
      echo "$outbound_refs" | jq -Rs '[split("\n") | .[] | select(length > 0) | split("|") | {parent_number: .[0], target_session: .[1]}]'
    else
      echo '[]'
    fi
  )" '
    # Sort by number (natural sort via split-and-compare)
    def numparts: split(".") | map(tonumber);

    sort_by(.number | numparts) |

    . as $all |

    # Get children of a parent node
    def children(parent_num):
      if parent_num == "" then
        [.[] | select(
          (.parent_number == "" or .parent_number == null) or
          (.parent_tmux_session != "" and .parent_tmux_session != .tmux_session)
        )]
      else
        [.[] | select(.parent_number == parent_num and (.parent_tmux_session == .tmux_session or .parent_tmux_session == ""))]
      end |
      sort_by(.number | numparts);

    # Get outbound refs from a parent node
    def outbound(parent_num):
      [$refs[] | select(.parent_number == parent_num)];

    def render(parent_num; prefix; depth):
      ($all | children(parent_num)) as $kids |
      ($all | outbound(parent_num)) as $outs |
      (($kids | length) + ($outs | length)) as $total |
      if $total == 0 then empty
      else
        # Render real children
        (range($kids | length) as $idx |
        $kids[$idx] as $node |
        (if $idx == ($total - 1) then "1" else "0" end) as $is_last |
        "\(prefix)\($is_last)|\($node.number)|\($node.slug)|\($node.tmux_pane_id)",
        render($node.number; (prefix + (if $is_last == "1" then "S" else "P" end)); depth + 1)),
        # Render outbound refs (after all children)
        (range($outs | length) as $oidx |
        $outs[$oidx] as $out |
        (if ($kids | length) + $oidx == ($total - 1) then "1" else "0" end) as $is_last_out |
        "\(prefix)\($is_last_out)|⊳|\($out.target_session)|")
      end;

    render(""; ""; 0)
  ')

  # Render tree lines with box-drawing characters
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    # Parse: prefix_flags + is_last | number_or_marker | slug_or_session | pane_id
    local flags_and_last="${line%%|*}"
    local rest="${line#*|}"
    local number="${rest%%|*}"
    rest="${rest#*|}"
    local slug="${rest%%|*}"
    local pane_id="${rest#*|}"

    # Extract is_last (last char of flags_and_last) and prefix flags (everything before)
    local is_last="${flags_and_last: -1}"
    local prefix_flags="${flags_and_last%?}"

    # Build prefix string from flags
    local prefix=""
    local j=0
    while [ $j -lt ${#prefix_flags} ]; do
      local flag="${prefix_flags:$j:1}"
      if [ "$flag" = "S" ]; then
        prefix="${prefix}    "
      else
        prefix="${prefix}│   "
      fi
      j=$((j + 1))
    done

    # Connector
    local connector
    if [ "$is_last" = "1" ]; then
      connector="└── "
    else
      connector="├── "
    fi

    # Handle outbound session reference (⊳ marker)
    if [ "$number" = "⊳" ]; then
      if [ -z "$prefix_flags" ]; then
        echo "⊳ ${slug}"
      else
        echo "${prefix}${connector}⊳ ${slug}"
      fi
      continue
    fi

    # Status
    local status
    status=$(status_of "$pane_id" "$session" "$number" "$slug")

    # Format: align status with dots
    local label="${number}:${slug}"
    local total_width=32
    local label_len=${#label}
    local dot_count=$((total_width - label_len))
    [ "$dot_count" -lt 2 ] && dot_count=2
    local dots=""
    for ((d=0; d<dot_count; d++)); do dots="${dots}·"; done

    if [ -z "$prefix_flags" ]; then
      # Root level: no connector
      echo "${label} ${dots} ${status}"
    else
      echo "${prefix}${connector}${label} ${dots} ${status}"
    fi
  done <<< "$tree_lines"

  echo ""
}

# --- Main ---
case "$MODE" in
  current|named)
    render_session "$TARGET" "$TREE_FILE"
    ;;
  all)
    # Get all unique session names
    sessions=$(jq -r '.tmux_session' "$TREE_FILE" | sort -u)
    while IFS= read -r session; do
      [ -z "$session" ] && continue
      render_session "$session" "$TREE_FILE"
    done <<< "$sessions"
    ;;
  trace)
    # Find the node with the given number in any session, then trace its ancestry
    echo "Trace from node ${TARGET}:"
    echo ""
    # Find the node (slurp JSONL, filter)
    node=$(jq -s --arg n "$TARGET" '[.[] | select(.number == $n)] | last' "$TREE_FILE")
    if [ -z "$node" ] || [ "$node" = "null" ]; then
      echo "Node $TARGET not found" >&2
      exit 1
    fi
    current_session=$(echo "$node" | jq -r '.tmux_session')
    current_number="$TARGET"
    chain=()
    while [ -n "$current_number" ]; do
      chain+=("${current_session}:${current_number}")
      parent_info=$(jq -r -s --arg n "$current_number" --arg s "$current_session" \
        '[.[] | select(.number == $n and .tmux_session == $s)] | last | "\(.parent_tmux_session)|\(.parent_number)"' \
        "$TREE_FILE")
      parent_session="${parent_info%%|*}"
      parent_number="${parent_info#*|}"
      if [ "$parent_session" = "$current_session" ] || [ -z "$parent_session" ]; then
        current_number="$parent_number"
      else
        current_session="$parent_session"
        current_number="$parent_number"
      fi
    done
    # Print chain in reverse (root first)
    for ((idx=${#chain[@]}-1; idx>=0; idx--)); do
      indent=""
      for ((pad=0; pad<${#chain[@]}-1-idx; pad++)); do indent="${indent}  "; done
      if [ $idx -eq 0 ]; then
        echo "${indent}→ ${chain[$idx]} (current)"
      else
        echo "${indent}${chain[$idx]}"
      fi
    done
    ;;
esac
