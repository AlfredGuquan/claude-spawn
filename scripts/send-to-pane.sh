#!/bin/bash
# send-to-pane.sh — Send text to a fork child's tmux pane via tmux send-keys.
# Dependencies: jq, tmux
# Usage: send-to-pane.sh <child-id> <message>

CHILD_ID="$1"
MESSAGE="$2"
FORK_STATUS_DIR="/tmp/claude-fork-status"

if [ -z "$CHILD_ID" ] || [ -z "$MESSAGE" ]; then
  echo "Usage: send-to-pane.sh <child-id> <message>" >&2
  exit 1
fi

PANE_FILE="${FORK_STATUS_DIR}/${CHILD_ID}/pane.json"
if [ ! -f "$PANE_FILE" ]; then
  echo "ERROR: pane registry not found: ${PANE_FILE}" >&2
  exit 1
fi

TARGET_PANE=$(jq -r '.tmux_pane_id' "$PANE_FILE")
if [ -z "$TARGET_PANE" ] || [ "$TARGET_PANE" = "null" ]; then
  echo "ERROR: no tmux_pane_id in ${PANE_FILE}" >&2
  exit 1
fi

# Send message text + Enter, then after a short delay send a second Enter
# to ensure Claude Code TUI submits the input.
tmux send-keys -t "$TARGET_PANE" "$MESSAGE" Enter
sleep 0.5
tmux send-keys -t "$TARGET_PANE" "" Enter

echo "Sent to ${CHILD_ID}"
