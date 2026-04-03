#!/bin/bash
# Q Protocol Agent Complete Hook - SubagentStop
# Decrements agent counter when an agent (Task tool) completes
# This allows the Q Protocol compliance hook to resume checking
# after all agents have finished

set -eu

# Set to "true" to enable debug logging, "false" to disable
DEBUG_ENABLED="false"
DEBUG_LOG="/tmp/claude_q_debug.log"

if ! command -v jq &> /dev/null; then
  exit 0
fi

INPUT=$(cat)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // "unknown"')

AGENT_COUNT_FILE="/tmp/claude_agents_count_${SESSION_ID}"
AGENT_COUNT=$(cat "$AGENT_COUNT_FILE" 2>/dev/null || echo 0)

if [ "$AGENT_COUNT" -gt 0 ]; then
  NEW_COUNT=$((AGENT_COUNT - 1))
  echo "$NEW_COUNT" > "$AGENT_COUNT_FILE"
  [ "$DEBUG_ENABLED" = "true" ] && echo "=== $(date '+%H:%M:%S.%3N') - AGENT_COMPLETE: count now ${NEW_COUNT} ===" >> "$DEBUG_LOG"
else
  [ "$DEBUG_ENABLED" = "true" ] && echo "=== $(date '+%H:%M:%S.%3N') - AGENT_COMPLETE: count already 0, no decrement ===" >> "$DEBUG_LOG"
fi

exit 0
