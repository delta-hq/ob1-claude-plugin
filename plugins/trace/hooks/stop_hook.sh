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

# One run per session at a time. Hooks are async and never time out, so
# overlapping Stop events used to pile up hundreds of copies. A Stop that finds
# a run in progress waits for it (up to 10 minutes), then reads from where that
# run stopped. flock is held on fd 9, so the kernel releases it when this
# process and its children exit, even on SIGKILL.
command -v perl >/dev/null 2>&1 || { log "ERROR" "perl not found"; exit 0; }
{ exec 9>>"${TMPDIR:-/tmp}/ob1-trace-stop-${SESSION_ID}.flock"; } 2>/dev/null || exit 0
perl -MFcntl=:flock -e 'open(my $fh, ">&=", 9) or exit 1; $SIG{ALRM} = sub { exit 1 }; alarm 600; flock($fh, LOCK_EX) or exit 1' || exit 0

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
case "$TOTAL_LINES" in ''|*[!0-9]*) exit 0 ;; esac

# Scan for assistant messages (LLM calls) since last checkpoint
LLM_CALLS=0

# $1: one span from the transcript pass below, {text, model, pt, ct, ts}
create_llm_span() {
  local span="$1"
  local span_id=$(generate_uuid)
  local start_epoch=$(iso_to_epoch "$(jq -r '.ts' <<<"$span")")
  local end_epoch=$(date +%s)

  local event=$(jq -n \
    --arg id "$span_id" \
    --arg root "$ROOT_SPAN_ID" \
    --arg parent "$TURN_SPAN_ID" \
    --argjson s "$span" \
    --argjson start "$start_epoch" \
    --argjson endtime "$end_epoch" \
    '($s.model | if . == "" then "claude" else . end) as $model | {
      id: $id,
      span_id: $id,
      root_span_id: $root,
      span_parents: [$parent],
      created: (now | strftime("%Y-%m-%dT%H:%M:%S.000Z")),
      output: {role: "assistant", content: $s.text},
      metadata: { model: $model, source: "ob1_claude_code" },
      metrics: {
        start: $start,
        "end": $endtime,
        prompt_tokens: $s.pt,
        completion_tokens: $s.ct,
        tokens: ($s.pt + $s.ct)
      },
      span_attributes: { name: $model, type: "llm" }
    }')

  insert_span "$PROJECT_ID" "$event" >/dev/null && LLM_CALLS=$((LLM_CALLS + 1)) || true
}

# One jq pass over the new lines (was ~7 jq processes per transcript line,
# which took minutes on transcripts with large base64 image lines).
# Same rules as before: assistant lines accumulate text/model/tokens, a user
# line flushes the span if it has text, and a final flush at the end. Each
# text chunk drops trailing newlines, as the old $(jq -r ...) calls did.
while IFS= read -r span; do
  [ -n "$span" ] && create_llm_span "$span"
done < <(tail -n +"$((TURN_LAST_LINE + 1))" "$CONV_FILE" | jq -R -n -c '
  def rtrim_nl: explode | . as $a | (first(range(length - 1; -1; -1) | select($a[.] != 10)) // -1) as $i
                | $a[:$i + 1] | implode;  # linear; sub("\n+$"; "") is quadratic on long newline runs
  def txt: (if type == "array" then [.[] | objects | select(.type == "text") | .text | strings] | join("\n")
            elif type == "string" then . else "" end) | rtrim_nl;
  def tok: (tonumber? // 0) | if . > 0 then . else 0 end;
  def flush: if .cur != null and .cur.text != "" then .out += [.cur] else . end | .cur = null;
  reduce (inputs | fromjson? | objects) as $l ({cur: null, out: []};
    . as $state | try (
      if $l.type == "assistant" then
        ($l.message | objects) // {} | . as $m
        | $state | .cur = ((.cur // {text: "", model: "", pt: 0, ct: 0, ts: ""})
          | .ts = (if .ts == "" then ($l.timestamp | strings) // "" else .ts end)
          | .text += ($m.content | txt)
          | .model = (($m.model | strings | select(. != "")) // .model)
          | .pt += (($m.usage | objects | .input_tokens) // 0 | tok)
          | .ct += (($m.usage | objects | .output_tokens) // 0 | tok))
      elif $l.type == "user" then flush
      else . end
    ) catch $state)
  | flush | .out[]' 2>/dev/null)

# Update turn end time
END_TIME=$(date +%s)
TURN_UPDATE=$(jq -n --arg id "$TURN_SPAN_ID" --argjson endtime "$END_TIME" '{id: $id, _is_merge: true, metrics: {"end": $endtime}}')
insert_span "$PROJECT_ID" "$TURN_UPDATE" >/dev/null || true

set_session_state "$SESSION_ID" "turn_last_line" "$TOTAL_LINES"
set_session_state "$SESSION_ID" "current_turn_span_id" ""

[ "$LLM_CALLS" -gt 0 ] && log "INFO" "Created $LLM_CALLS LLM spans for turn"
exit 0
