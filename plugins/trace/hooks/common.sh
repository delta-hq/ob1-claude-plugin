#!/bin/bash
# OB1 Trace — shared utilities for Claude Code hooks
# Routes all trace data through the OB1 Console proxy, which enriches
# spans with WorkOS user/org identity before forwarding to Braintrust.

set -e

# ── Config ──────────────────────────────────────────────────────────────────

# OB1 Console base URL (the proxy that enriches + forwards to Braintrust)
export OB1_BASE_URL="${OB1_BASE_URL:-https://console.openblocklabs.com}"
export OB1_API_URL="${OB1_BASE_URL}/api/v1/braintrust"

# Auth: OB1 API key (from console.openblocklabs.com/api-keys)
export OB1_API_KEY="${OB1_API_KEY:-}"

# Logging
LOG_DIR="${CLAUDE_PLUGIN_DATA:-${HOME}/.cache/ob1-trace}"
mkdir -p "$LOG_DIR"
export LOG_FILE="${LOG_DIR}/trace.log"
export DEBUG="${OB1_TRACE_DEBUG:-false}"

# Session state
export SESSION_DIR="${LOG_DIR}/sessions"
mkdir -p "$SESSION_DIR"

# ── Logging ─────────────────────────────────────────────────────────────────

log() {
  local level="$1"; shift
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) [$level] $*" >> "$LOG_FILE"
}

debug() {
  [ "$DEBUG" = "true" ] && log "DEBUG" "$@"
}

# ── Checks ──────────────────────────────────────────────────────────────────

tracing_enabled() {
  [ -n "$OB1_API_KEY" ]
}

check_requirements() {
  command -v jq >/dev/null 2>&1 || { log "ERROR" "jq not found"; return 1; }
  command -v curl >/dev/null 2>&1 || { log "ERROR" "curl not found"; return 1; }
  return 0
}

# ── UUID ────────────────────────────────────────────────────────────────────

generate_uuid() {
  if command -v uuidgen >/dev/null 2>&1; then
    uuidgen | tr '[:upper:]' '[:lower:]'
  else
    python3 -c "import uuid; print(uuid.uuid4())"
  fi
}

# ── Timestamps ──────────────────────────────────────────────────────────────

get_timestamp() {
  date -u +%Y-%m-%dT%H:%M:%S.000Z
}

iso_to_epoch() {
  local ts="$1"
  [ -z "$ts" ] && { date +%s; return; }
  local clean_ts="${ts%.*}"
  clean_ts="${clean_ts}+0000"
  date -j -f "%Y-%m-%dT%H:%M:%S%z" "$clean_ts" "+%s" 2>/dev/null || \
  date -d "$ts" "+%s" 2>/dev/null || \
  date +%s
}

# ── Session state (file-based, per session) ─────────────────────────────────

get_session_state() {
  local sid="$1" key="$2"
  local file="${SESSION_DIR}/${sid}.json"
  [ -f "$file" ] && jq -r ".${key} // empty" "$file" 2>/dev/null || echo ""
}

set_session_state() {
  local sid="$1" key="$2" val="$3"
  local file="${SESSION_DIR}/${sid}.json"
  if [ -f "$file" ]; then
    local tmp=$(jq --arg k "$key" --arg v "$val" '.[$k] = $v' "$file" 2>/dev/null)
    [ -n "$tmp" ] && echo "$tmp" > "$file"
  else
    jq -n --arg k "$key" --arg v "$val" '{($k): $v}' > "$file"
  fi
}

# ── Project ID (cached) ────────────────────────────────────────────────────

CACHE_FILE="${LOG_DIR}/project_id"

get_project_id() {
  # Check cache (1 hour TTL)
  if [ -f "$CACHE_FILE" ] && [ "$(find "$CACHE_FILE" -mmin -60 2>/dev/null)" ]; then
    cat "$CACHE_FILE"
    return
  fi

  # Fetch from OB1 proxy (it returns the org's Braintrust project)
  local pid
  pid=$(curl -sf "${OB1_API_URL}/api/project" \
    -H "Authorization: Bearer ${OB1_API_KEY}" \
    -H "X-User-Id: ${OB1_USER_ID:-}" | jq -r '.id // empty' 2>/dev/null)

  if [ -n "$pid" ]; then
    echo "$pid" > "$CACHE_FILE"
    echo "$pid"
  fi
}

# ── Span insertion (posts to OB1 proxy → Braintrust) ───────────────────────

insert_span() {
  local project_id="$1"
  local event_json="$2"

  # Add project_id and log_id to the event
  local row
  row=$(echo "$event_json" | jq --arg pid "$project_id" '. + {project_id: $pid, log_id: "g"}')

  local payload
  payload=$(jq -n --argjson row "$row" '{rows: [$row], api_version: 2}')

  curl -sf -X POST "${OB1_API_URL}/logs3" \
    -H "Authorization: Bearer ${OB1_API_KEY}" \
    -H "X-User-Id: ${OB1_USER_ID:-}" \
    -H "Content-Type: application/json" \
    -d "$payload" 2>/dev/null
}

# ── Cleanup old sessions ───────────────────────────────────────────────────

cleanup_sessions() {
  find "$SESSION_DIR" -name "*.json" -mtime +7 -delete 2>/dev/null || true
}
