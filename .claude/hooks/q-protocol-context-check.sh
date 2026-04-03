#!/bin/bash
# Q Protocol Context Degradation Check
# Warns when conversation gets long to prevent drift

# Check dependencies
if ! command -v jq &> /dev/null; then
  exit 0
fi

# Parse session_id from JSON input
INPUT=$(cat)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // "unknown"')

MSG_COUNT_FILE="/tmp/claude_q_msgs_${SESSION_ID}"
COUNT=$(cat "$MSG_COUNT_FILE" 2>/dev/null || echo 0)
COUNT=$((COUNT + 1))
echo "$COUNT" > "$MSG_COUNT_FILE"

# Warn at 25, 50, 75, 100 calls (more frequent than before)
if [ "$COUNT" -eq 25 ] || [ "$COUNT" -eq 50 ] || [ "$COUNT" -eq 75 ] || [ "$COUNT" -eq 100 ]; then
  cat <<EOF
<system-reminder>
CONTEXT DEGRADATION WARNING (${COUNT} tool calls)

Q Protocol requires:
- Scroll back to original goal/constraints
- Can you reconstruct original intent?
- If reasoning feels fuzzy, STOP and checkpoint with Q

Signs of degradation:
- Outputs getting sloppier
- Uncertain what the goal was
- Repeating work
- "This should work" (map != territory)

Say: "I'm losing the thread. Checkpointing."
</system-reminder>
EOF
fi
