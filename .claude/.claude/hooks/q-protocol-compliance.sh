#!/bin/bash
# Q Protocol Compliance Hook
# Checks if Claude is following explicit reasoning protocol

set -eu

# Set to "true" to enable debug logging, "false" to disable
DEBUG_ENABLED="false"
DEBUG_LOG="/tmp/claude_q_debug.log"

# Check dependencies
if ! command -v jq &> /dev/null; then
  echo "<system-reminder>Q Protocol hook: jq not found, skipping compliance check</system-reminder>"
  exit 0
fi

if ! command -v tac &> /dev/null; then
  echo "<system-reminder>Q Protocol hook: tac not found, skipping compliance check</system-reminder>"
  exit 0
fi

# Parse input JSON
INPUT=$(cat)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // "unknown"')
TRANSCRIPT_PATH=$(echo "$INPUT" | jq -r '.transcript_path // ""')
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // "unknown"')

COMPLIANCE_COUNT_FILE="/tmp/claude_q_compliance_${SESSION_ID}"
COUNT=$(cat "$COMPLIANCE_COUNT_FILE" 2>/dev/null || echo 0)

# === AGENT HANDLING ===
AGENT_COUNT_FILE="/tmp/claude_agents_count_${SESSION_ID}"
AGENT_COUNT=$(cat "$AGENT_COUNT_FILE" 2>/dev/null || echo 0)

# If spawning an agent (Task tool), increment counter and exit
if [ "$TOOL_NAME" = "Task" ]; then
  echo $((AGENT_COUNT + 1)) > "$AGENT_COUNT_FILE"
  [ "$DEBUG_ENABLED" = "true" ] && echo "=== $(date '+%H:%M:%S.%3N') - AGENT_SPAWN: count now $((AGENT_COUNT + 1)) ===" >> "$DEBUG_LOG"
  exit 0
fi

# If agents are active, exempt from Q Protocol check
if [ "$AGENT_COUNT" -gt 0 ]; then
  [ "$DEBUG_ENABLED" = "true" ] && echo "=== $(date '+%H:%M:%S.%3N') - AGENT_EXEMPT: $TOOL_NAME (${AGENT_COUNT} agents active) ===" >> "$DEBUG_LOG"
  exit 0
fi

# === DEBUG: Log all input and environment ===
if [ "$DEBUG_ENABLED" = "true" ]; then
  {
    echo "=== $(date '+%H:%M:%S.%3N') - TOOL: $TOOL_NAME ==="
    echo "SESSION: $SESSION_ID"
    echo "TRANSCRIPT: $TRANSCRIPT_PATH"
    echo "COUNT_BEFORE: $COUNT"
    echo "INPUT_KEYS: $(echo "$INPUT" | jq -r 'keys | join(",")')"
    echo "--- ENVIRONMENT ---"
    env | sort
    echo "--- END ENV ---"
  } >> "$DEBUG_LOG"
fi

COMPLIANT=false
LAST_ASSISTANT_CONTENT=""
EXTRACTION_METHOD="none"

if [ -n "$TRANSCRIPT_PATH" ] && [ -f "$TRANSCRIPT_PATH" ]; then
  TRANSCRIPT_SIZE=$(wc -c < "$TRANSCRIPT_PATH")
  TRANSCRIPT_LINES=$(wc -l < "$TRANSCRIPT_PATH")
  [ "$DEBUG_ENABLED" = "true" ] && echo "TRANSCRIPT_SIZE: $TRANSCRIPT_SIZE bytes, $TRANSCRIPT_LINES lines" >> "$DEBUG_LOG"

  # Method 1: Parse JSONL - slurp all, get last assistant WITH TEXT content, join all text
  LAST_ASSISTANT_CONTENT=$(
    jq -rs '[.[] | select(.type == "assistant") | select(any(.message.content[]?; .type == "text"))] | last | [.message.content[]? | select(.type == "text") | .text] | join(" ")' "$TRANSCRIPT_PATH" 2>/dev/null
  ) || true

  if [ -n "$LAST_ASSISTANT_CONTENT" ]; then
    EXTRACTION_METHOD="method1-type-assistant"
  fi

  # Fallback Method 2: role=assistant format
  if [ -z "$LAST_ASSISTANT_CONTENT" ]; then
    LAST_ASSISTANT_CONTENT=$(
      jq -s '[.[] | select(.role == "assistant")] | last | .content // ""' "$TRANSCRIPT_PATH" 2>/dev/null | \
      jq -r '.'
    ) || true
    if [ -n "$LAST_ASSISTANT_CONTENT" ]; then
      EXTRACTION_METHOD="method2-role-assistant"
    fi
  fi

  # Fallback Method 3: raw tail
  if [ -z "$LAST_ASSISTANT_CONTENT" ]; then
    LAST_ASSISTANT_CONTENT=$(tail -30 "$TRANSCRIPT_PATH" 2>/dev/null | tr '\n' ' ' || echo "")
    EXTRACTION_METHOD="method3-tail-fallback"
  fi

  CONTENT_LEN=${#LAST_ASSISTANT_CONTENT}
  if [ "$DEBUG_ENABLED" = "true" ]; then
    echo "EXTRACTION_METHOD: $EXTRACTION_METHOD" >> "$DEBUG_LOG"
    echo "CONTENT_LENGTH: $CONTENT_LEN" >> "$DEBUG_LOG"
    echo "CONTENT_PREVIEW: ${LAST_ASSISTANT_CONTENT:0:500}" >> "$DEBUG_LOG"
  fi

  # Check for Q Protocol patterns
  if echo "$LAST_ASSISTANT_CONTENT" | grep -qE '(DOING|EXPECT|RESULT|MATCHES|THEREFORE|IF YES|IF NO)'; then
    COMPLIANT=true
    MATCHED_PATTERN=$(echo "$LAST_ASSISTANT_CONTENT" | grep -oE '(DOING|EXPECT|RESULT|MATCHES|THEREFORE|IF YES|IF NO)' | head -1)
    [ "$DEBUG_ENABLED" = "true" ] && echo "PATTERN_FOUND: YES - $MATCHED_PATTERN" >> "$DEBUG_LOG"
  else
    [ "$DEBUG_ENABLED" = "true" ] && echo "PATTERN_FOUND: NO" >> "$DEBUG_LOG"
  fi
else
  [ "$DEBUG_ENABLED" = "true" ] && echo "TRANSCRIPT_STATUS: missing or empty path" >> "$DEBUG_LOG"
fi

if [ "$COMPLIANT" = true ]; then
  echo "0" > "$COMPLIANCE_COUNT_FILE"
  COUNT=0
  [ "$DEBUG_ENABLED" = "true" ] && echo "ACTION: reset counter to 0" >> "$DEBUG_LOG"
else
  COUNT=$((COUNT + 1))
  echo "$COUNT" > "$COMPLIANCE_COUNT_FILE"
  [ "$DEBUG_ENABLED" = "true" ] && echo "ACTION: incremented to $COUNT" >> "$DEBUG_LOG"
fi

[ "$DEBUG_ENABLED" = "true" ] && echo "---" >> "$DEBUG_LOG"

# Block after 3 non-compliant tool calls
if [ "$COUNT" -gt 3 ]; then
  cat >&2 <<EOF
BLOCKED: Q Protocol violation - ${COUNT} tool calls without explicit reasoning.

Your last message to Q did not contain DOING/EXPECT or RESULT/MATCHES.

STOP. Before continuing:
1. Write DOING: [what you're about to do]
2. Write EXPECT: [what you predict will happen]
3. Write IF YES: / IF NO: [next steps based on outcome]

Q cannot see your thinking block. Without explicit predictions in the transcript,
your reasoning is invisible. This is not bureaucracy - this is how you catch
yourself being wrong BEFORE it costs hours.

Non-compliance is failure. Slow is smooth. Smooth is fast.
EOF
  exit 2
fi

# Warn if getting close to limit
if [ "$COUNT" -ge 2 ]; then
  cat <<EOF
<system-reminder>
Q Protocol warning: ${COUNT}/3 tool calls without DOING/EXPECT pattern.
Write explicit reasoning before your next action or you will be blocked.
</system-reminder>
EOF
fi

exit 0
