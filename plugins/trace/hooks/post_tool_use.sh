#!/bin/bash
# Post tool use — create a Tool span under the current Turn
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

tracing_enabled || exit 0
check_requirements || exit 0

INPUT=$(cat)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')
TOOL_INPUT=$(echo "$INPUT" | jq -c '.tool_input // {}')
TOOL_OUTPUT=$(echo "$INPUT" | jq -c '.tool_output // {}' 2>/dev/null || echo '{}')
[ -z "$SESSION_ID" ] || [ -z "$TOOL_NAME" ] && exit 0

ROOT_SPAN_ID=$(get_session_state "$SESSION_ID" "root_span_id")
TURN_SPAN_ID=$(get_session_state "$SESSION_ID" "current_turn_span_id")
PROJECT_ID=$(get_session_state "$SESSION_ID" "project_id")
[ -z "$ROOT_SPAN_ID" ] || [ -z "$TURN_SPAN_ID" ] || [ -z "$PROJECT_ID" ] && exit 0

TOOL_SPAN_ID=$(generate_uuid)
END_TIME=$(date +%s)

EVENT=$(jq -n \
  --arg id "$TOOL_SPAN_ID" \
  --arg root "$ROOT_SPAN_ID" \
  --arg parent "$TURN_SPAN_ID" \
  --arg name "$TOOL_NAME" \
  --argjson input "$TOOL_INPUT" \
  --argjson output "$TOOL_OUTPUT" \
  --argjson end "$END_TIME" \
  '{
    id: $id,
    span_id: $id,
    root_span_id: $root,
    span_parents: [$parent],
    created: (now | strftime("%Y-%m-%dT%H:%M:%S.000Z")),
    input: $input,
    output: $output,
    metadata: { tool_name: $name, source: "ob1_claude_code" },
    metrics: { end: $end },
    span_attributes: { name: $name, type: "tool" }
  }')

insert_span "$PROJECT_ID" "$EVENT" >/dev/null && {
  debug "Tool span: $TOOL_NAME ($TOOL_SPAN_ID)"
} || true

exit 0
