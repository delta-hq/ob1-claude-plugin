#!/bin/bash
# Session end — finalize root trace span with end time
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

tracing_enabled || exit 0
check_requirements || exit 0

INPUT=$(cat)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
[ -z "$SESSION_ID" ] && exit 0

ROOT_SPAN_ID=$(get_session_state "$SESSION_ID" "root_span_id")
PROJECT_ID=$(get_session_state "$SESSION_ID" "project_id")
[ -z "$ROOT_SPAN_ID" ] || [ -z "$PROJECT_ID" ] && exit 0

END_TIME=$(date +%s)

# Merge end time into root span
EVENT=$(jq -n \
  --arg id "$ROOT_SPAN_ID" \
  --argjson end "$END_TIME" \
  '{id: $id, _is_merge: true, metrics: {end: $end}}')

insert_span "$PROJECT_ID" "$EVENT" >/dev/null && {
  log "INFO" "Session ended: $SESSION_ID"
} || true

# Clean up session state file
rm -f "${SESSION_DIR}/${SESSION_ID}.json" 2>/dev/null
exit 0
