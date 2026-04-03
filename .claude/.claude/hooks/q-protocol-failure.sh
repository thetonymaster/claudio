#!/bin/bash
# Q Protocol Failure Detection Hook
# Triggers when Bash commands fail (non-zero exit)
# Reads tool result from stdin

# Check dependencies
if ! command -v jq &> /dev/null; then
  exit 0
fi

# Parse input JSON
INPUT=$(cat)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // "unknown"')
TOOL_RESPONSE=$(echo "$INPUT" | jq -r '.tool_response // ""')

# Check if the result contains error indicators
if echo "$TOOL_RESPONSE" | grep -qiE '(error|failed|fatal|panic|exception|cannot|unable|not found|permission denied|No such file)'; then
  cat <<'EOF'
<system-reminder>
FAILURE DETECTED - Q Protocol requires:
1. State what failed (the raw error, not interpretation)
2. State your theory about why
3. State what you want to do about it
4. State what you expect to happen
5. ASK Q before proceeding

Format: "X failed with [error]. Theory: [why]. Want to try [action], expecting [outcome]. Yes?"

DO NOT immediately retry. Understand first.
Slow is smooth. Smooth is fast.
</system-reminder>
EOF
fi
