#!/bin/bash
# Stop hook — finalize current turn, create LLM spans from transcript
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
TURN_SPAN_ID=$(get_session_state "$SESSION_ID" "current_turn_span_id")
[ -z "$TURN_SPAN_ID" ] || [ -z "$PROJECT_ID" ] && exit 0

# Find transcript
CONV_FILE=$(echo "$INPUT" | jq -r '.transcript_path // empty')
[ -z "$CONV_FILE" ] || [ ! -f "$CONV_FILE" ] && exit 0

# Get last processed line for this turn
TURN_LAST_LINE=$(get_session_state "$SESSION_ID" "turn_last_line")
TURN_LAST_LINE=${TURN_LAST_LINE:-0}
TOTAL_LINES=$(wc -l < "$CONV_FILE" | tr -d ' ')

# Scan for assistant messages (LLM calls) since last checkpoint
LLM_CALLS=0
CURRENT_MODEL=""
CURRENT_PROMPT_TOKENS=0
CURRENT_COMPLETION_TOKENS=0
CURRENT_TEXT=""
CURRENT_START_TS=""
LINE_NUM=0

create_llm_span() {
  local text="$1" model="$2" ptok="$3" ctok="$4" start_ts="$5"
  [ -z "$text" ] && return
  local span_id=$(generate_uuid)
  local total=$((ptok + ctok))
  local start_epoch=$(iso_to_epoch "$start_ts")
  local end_epoch=$(date +%s)

  local event=$(jq -n \
    --arg id "$span_id" \
    --arg root "$ROOT_SPAN_ID" \
    --arg parent "$TURN_SPAN_ID" \
    --arg model "${model:-claude}" \
    --arg text "$text" \
    --argjson ptok "$ptok" \
    --argjson ctok "$ctok" \
    --argjson total "$total" \
    --argjson start "$start_epoch" \
    --argjson endtime "$end_epoch" \
    '{
      id: $id,
      span_id: $id,
      root_span_id: $root,
      span_parents: [$parent],
      created: (now | strftime("%Y-%m-%dT%H:%M:%S.000Z")),
      output: {role: "assistant", content: $text},
      metadata: { model: $model, source: "ob1_claude_code" },
      metrics: {
        start: $start,
        "end": $endtime,
        prompt_tokens: $ptok,
        completion_tokens: $ctok,
        tokens: $total
      },
      span_attributes: { name: $model, type: "llm" }
    }')

  insert_span "$PROJECT_ID" "$event" >/dev/null && LLM_CALLS=$((LLM_CALLS + 1)) || true
}

while IFS= read -r line; do
  LINE_NUM=$((LINE_NUM + 1))
  [ "$LINE_NUM" -le "$TURN_LAST_LINE" ] && continue
  [ -z "$line" ] && continue

  MSG_TYPE=$(echo "$line" | jq -r '.type // empty' 2>/dev/null)
  MSG_TS=$(echo "$line" | jq -r '.timestamp // empty' 2>/dev/null)

  if [ "$MSG_TYPE" = "assistant" ]; then
    [ -z "$CURRENT_START_TS" ] && CURRENT_START_TS="$MSG_TS"

    TEXT=$(echo "$line" | jq -r '
      .message.content
      | if type == "array" then [.[] | select(.type == "text") | .text] | join("\n")
        elif type == "string" then . else empty end' 2>/dev/null)
    [ -n "$TEXT" ] && CURRENT_TEXT="${CURRENT_TEXT}${TEXT}"

    MODEL=$(echo "$line" | jq -r '.message.model // empty' 2>/dev/null)
    [ -n "$MODEL" ] && CURRENT_MODEL="$MODEL"

    USAGE=$(echo "$line" | jq -c '.message.usage // {}' 2>/dev/null)
    if [ "$USAGE" != "{}" ]; then
      IT=$(echo "$USAGE" | jq -r '.input_tokens // 0' 2>/dev/null)
      OT=$(echo "$USAGE" | jq -r '.output_tokens // 0' 2>/dev/null)
      [ "$IT" -gt 0 ] 2>/dev/null && CURRENT_PROMPT_TOKENS=$((CURRENT_PROMPT_TOKENS + IT))
      [ "$OT" -gt 0 ] 2>/dev/null && CURRENT_COMPLETION_TOKENS=$((CURRENT_COMPLETION_TOKENS + OT))
    fi

  elif [ "$MSG_TYPE" = "user" ]; then
    # Flush current LLM span
    if [ -n "$CURRENT_TEXT" ]; then
      create_llm_span "$CURRENT_TEXT" "$CURRENT_MODEL" "$CURRENT_PROMPT_TOKENS" "$CURRENT_COMPLETION_TOKENS" "$CURRENT_START_TS"
    fi
    CURRENT_TEXT="" CURRENT_MODEL="" CURRENT_PROMPT_TOKENS=0 CURRENT_COMPLETION_TOKENS=0 CURRENT_START_TS=""
  fi
done < "$CONV_FILE"

# Flush final LLM span
[ -n "$CURRENT_TEXT" ] && create_llm_span "$CURRENT_TEXT" "$CURRENT_MODEL" "$CURRENT_PROMPT_TOKENS" "$CURRENT_COMPLETION_TOKENS" "$CURRENT_START_TS"

# Update turn end time
END_TIME=$(date +%s)
TURN_UPDATE=$(jq -n --arg id "$TURN_SPAN_ID" --argjson endtime "$END_TIME" '{id: $id, _is_merge: true, metrics: {"end": $endtime}}')
insert_span "$PROJECT_ID" "$TURN_UPDATE" >/dev/null || true

set_session_state "$SESSION_ID" "turn_last_line" "$TOTAL_LINES"
set_session_state "$SESSION_ID" "current_turn_span_id" ""

[ "$LLM_CALLS" -gt 0 ] && log "INFO" "Created $LLM_CALLS LLM spans for turn"
exit 0
