#!/bin/bash
# Q Protocol Periodic Reminder Hook
# Injects reminders every 5 tool calls to combat context decay

# Check dependencies
if ! command -v jq &> /dev/null; then
  exit 0
fi

# Parse session_id from JSON input
INPUT=$(cat)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // "unknown"')

CALL_COUNT_FILE="/tmp/claude_q_calls_${SESSION_ID}"
COUNT=$(cat "$CALL_COUNT_FILE" 2>/dev/null || echo 0)
COUNT=$((COUNT + 1))
echo "$COUNT" > "$CALL_COUNT_FILE"

if [ $((COUNT % 5)) -eq 0 ]; then
  cat <<EOF
<system-reminder>
Q Protocol checkpoint (call #${COUNT}):
- DOING/EXPECT/IF YES/IF NO before actions
- RESULT/MATCHES/THEREFORE after actions
- Batch size 3, then VERIFY with observable reality
- Reality contradicts model -> STOP, fix model first
- Failure -> words to Q, not another tool call
- "I don't know" is valid; confabulation is not
</system-reminder>
EOF
fi
