#!/bin/bash
# User prompt submit — create a Turn span under the session root
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

tracing_enabled || exit 0
check_requirements || exit 0

INPUT=$(cat)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
PROMPT=$(echo "$INPUT" | jq -r '.prompt // empty')
[ -z "$SESSION_ID" ] && exit 0

ROOT_SPAN_ID=$(get_session_state "$SESSION_ID" "root_span_id")
PROJECT_ID=$(get_session_state "$SESSION_ID" "project_id")
[ -z "$ROOT_SPAN_ID" ] || [ -z "$PROJECT_ID" ] && exit 0

TURN_SPAN_ID=$(generate_uuid)
START_TIME=$(date +%s)
TURN_NAME=$(echo "$PROMPT" | head -c 100)
[ -z "$TURN_NAME" ] && TURN_NAME="Turn"

EVENT=$(jq -n \
  --arg id "$TURN_SPAN_ID" \
  --arg root "$ROOT_SPAN_ID" \
  --arg name "$TURN_NAME" \
  --arg prompt "$PROMPT" \
  --argjson start "$START_TIME" \
  '{
    id: $id,
    span_id: $id,
    root_span_id: $root,
    span_parents: [$root],
    created: (now | strftime("%Y-%m-%dT%H:%M:%S.000Z")),
    input: $prompt,
    metadata: { source: "ob1_claude_code" },
    metrics: { start: $start },
    span_attributes: { name: $name, type: "task" }
  }')

insert_span "$PROJECT_ID" "$EVENT" >/dev/null && {
  set_session_state "$SESSION_ID" "current_turn_span_id" "$TURN_SPAN_ID"
  set_session_state "$SESSION_ID" "current_turn_start" "$START_TIME"
  set_session_state "$SESSION_ID" "turn_last_line" "0"
  debug "Turn started: $TURN_SPAN_ID"
} || true

exit 0
