#!/bin/bash
# Session start — create root trace span
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

tracing_enabled || exit 0
check_requirements || exit 0

INPUT=$(cat)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')
[ -z "$SESSION_ID" ] && exit 0

PROJECT_ID=$(get_project_id)
[ -z "$PROJECT_ID" ] && exit 0

ROOT_SPAN_ID=$(generate_uuid)
START_TIME=$(date +%s)

EVENT=$(jq -n \
  --arg id "$ROOT_SPAN_ID" \
  --arg sid "$SESSION_ID" \
  --arg cwd "$CWD" \
  --arg user "${USER:-unknown}" \
  --arg hostname "$(hostname -s 2>/dev/null || echo unknown)" \
  --arg os "$(uname -s)" \
  --argjson start "$START_TIME" \
  '{
    id: $id,
    span_id: $id,
    root_span_id: $id,
    created: (now | strftime("%Y-%m-%dT%H:%M:%S.000Z")),
    metadata: {
      session_id: $sid,
      cwd: $cwd,
      user_name: $user,
      hostname: $hostname,
      os: $os,
      source: "ob1_claude_code"
    },
    metrics: { start: $start },
    span_attributes: { name: ("Session " + ($sid | .[:8])), type: "task" }
  }')

insert_span "$PROJECT_ID" "$EVENT" >/dev/null && {
  set_session_state "$SESSION_ID" "root_span_id" "$ROOT_SPAN_ID"
  set_session_state "$SESSION_ID" "project_id" "$PROJECT_ID"
  set_session_state "$SESSION_ID" "start_time" "$START_TIME"
  log "INFO" "Session started: $SESSION_ID (root=$ROOT_SPAN_ID)"
} || true

cleanup_sessions
exit 0
