#!/bin/bash
# OB1 Trace — shared utilities for Claude Code hooks
# Routes all trace data through the OB1 Console proxy, which enriches
# spans with WorkOS user/org identity before forwarding to Braintrust.

set -e

# ── Config ──────────────────────────────────────────────────────────────────

# Mode 1: OB1 Console proxy (enriches with WorkOS identity)
export OB1_BASE_URL="${OB1_BASE_URL:-}"
export OB1_API_KEY="${OB1_API_KEY:-}"
export OB1_ORG_ID="${OB1_ORG_ID:-}"
export OB1_FORCE_PLUGIN_INGEST="${OB1_FORCE_PLUGIN_INGEST:-}"

# Mode 2: Direct Braintrust (fallback when console isn't available)
export BRAINTRUST_API_KEY="${BRAINTRUST_API_KEY:-}"
export BRAINTRUST_PROJECT_ID="${BRAINTRUST_PROJECT_ID:-}"

should_force_plugin_ingest() {
  case "${OB1_FORCE_PLUGIN_INGEST:-}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

# Auto-discover OB1 credentials from Claude settings or ~/.ob1/credentials.json.
# Claude hooks do not inherit the desktop extension's credential loading, so do
# the same resolution here before falling back to a raw Braintrust key.
if [ -z "$OB1_API_KEY" ] || [ -z "$OB1_ORG_ID" ] || [ -z "$OB1_BASE_URL" ] || [ -z "$BRAINTRUST_PROJECT_ID" ] || [ -z "$OB1_FORCE_PLUGIN_INGEST" ]; then
  for _settings_file in "$HOME/.claude/settings.json" "$HOME/.claude/settings.local.json"; do
    [ -f "$_settings_file" ] || continue
    if [ -z "$OB1_BASE_URL" ]; then
      _ob1_base_url=$(jq -r '.env.OB1_BASE_URL // empty' "$_settings_file" 2>/dev/null)
      if [ -n "$_ob1_base_url" ]; then
        OB1_BASE_URL="$_ob1_base_url"
        export OB1_BASE_URL
      fi
    fi
    if [ -z "$OB1_FORCE_PLUGIN_INGEST" ]; then
      _ob1_force_plugin_ingest=$(jq -r '.env.OB1_FORCE_PLUGIN_INGEST // empty' "$_settings_file" 2>/dev/null)
      if [ -n "$_ob1_force_plugin_ingest" ]; then
        OB1_FORCE_PLUGIN_INGEST="$_ob1_force_plugin_ingest"
        export OB1_FORCE_PLUGIN_INGEST
      fi
    fi
    if [ -z "$BRAINTRUST_PROJECT_ID" ]; then
      _braintrust_project_id=$(jq -r '.env.OB1_BRAINTRUST_PROJECT_ID // .env.BRAINTRUST_PROJECT_ID // empty' "$_settings_file" 2>/dev/null)
      if [ -n "$_braintrust_project_id" ]; then
        BRAINTRUST_PROJECT_ID="$_braintrust_project_id"
        export BRAINTRUST_PROJECT_ID
      fi
    fi
    if [ -z "$OB1_API_KEY" ] && ! should_force_plugin_ingest; then
      _ob1_key=$(jq -r '.env.OB1_API_KEY // empty' "$_settings_file" 2>/dev/null)
      if [ -n "$_ob1_key" ]; then
        OB1_API_KEY="$_ob1_key"
        export OB1_API_KEY
      fi
    fi
    if [ -z "$OB1_ORG_ID" ]; then
      _ob1_org=$(jq -r '.env.OB1_ORG_ID // empty' "$_settings_file" 2>/dev/null)
      if [ -n "$_ob1_org" ]; then
        OB1_ORG_ID="$_ob1_org"
        export OB1_ORG_ID
      fi
    fi
  done
fi

if { [ -z "$OB1_API_KEY" ] && ! should_force_plugin_ingest; } || [ -z "$OB1_ORG_ID" ]; then
  _ob1_creds="$HOME/.ob1/credentials.json"
  if [ -f "$_ob1_creds" ]; then
    if [ -z "$OB1_API_KEY" ] && ! should_force_plugin_ingest; then
      _ob1_key=$(jq -r '.default.api_key // empty' "$_ob1_creds" 2>/dev/null)
      if [ -n "$_ob1_key" ]; then
        OB1_API_KEY="$_ob1_key"
        export OB1_API_KEY
      fi
    fi
    if [ -z "$OB1_ORG_ID" ]; then
      _ob1_org=$(jq -r '.oauth.organization_id // empty' "$_ob1_creds" 2>/dev/null)
      if [ -n "$_ob1_org" ]; then
        OB1_ORG_ID="$_ob1_org"
        export OB1_ORG_ID
      fi
    fi
  fi
fi

# Auto-discover Braintrust API key from Claude settings if not explicitly set
if [ -z "$BRAINTRUST_API_KEY" ]; then
  for _settings_file in "$HOME/.claude/settings.json" "$HOME/.claude/settings.local.json"; do
    [ -f "$_settings_file" ] || continue
    _found_key=$(jq -r '
      .mcpServers.braintrust.args // [] | to_entries[] |
      select(.value == "--api-key") | .key + 1 | tostring
    ' "$_settings_file" 2>/dev/null)
    if [ -n "$_found_key" ]; then
      BRAINTRUST_API_KEY=$(jq -r ".mcpServers.braintrust.args[$_found_key] // empty" "$_settings_file" 2>/dev/null)
      [ -n "$BRAINTRUST_API_KEY" ] && export BRAINTRUST_API_KEY && break
    fi
    # Also check env block
    _env_key=$(jq -r '.env.BRAINTRUST_API_KEY // empty' "$_settings_file" 2>/dev/null)
    if [ -n "$_env_key" ]; then
      BRAINTRUST_API_KEY="$_env_key"
      export BRAINTRUST_API_KEY
      break
    fi
  done
fi

if [ -z "$OB1_BASE_URL" ]; then
  OB1_BASE_URL="https://console.openblocklabs.com"
  export OB1_BASE_URL
fi
export OB1_API_URL="${OB1_BASE_URL}/api/v1/braintrust"

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
  if should_force_plugin_ingest; then
    [ -n "$BRAINTRUST_API_KEY" ]
  else
    [ -n "$OB1_API_KEY" ] || [ -n "$BRAINTRUST_API_KEY" ]
  fi
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
  local tmp="${SESSION_DIR}/.${sid}.$$.tmp.json"
  # Hooks run in parallel. A per-session flock around the read-modify-write
  # stops one hook from undoing another's write, and renaming a temp file into
  # place means a reader never sees a half-written file. Either one made Stop
  # lose the turn ID or go back to an old line and re-send spans.
  {
    perl -MFcntl=:flock -e 'open(my $fh, ">&=", 8) or exit 1; alarm 10; flock($fh, LOCK_EX)' 2>/dev/null || true
    if [ -f "$file" ]; then
      jq --arg k "$key" --arg v "$val" '.[$k] = $v' "$file" > "$tmp" 2>/dev/null || true
    else
      jq -n --arg k "$key" --arg v "$val" '{($k): $v}' > "$tmp" 2>/dev/null || true
    fi
    [ -s "$tmp" ] && mv -f "$tmp" "$file" || rm -f "$tmp"
  } 8>>"${SESSION_DIR}/.${sid}.lock"
}

# ── Project ID (cached) ────────────────────────────────────────────────────

CACHE_FILE="${LOG_DIR}/project_id"

get_project_id() {
  # Check env override first
  if [ -n "${BRAINTRUST_PROJECT_ID:-}" ]; then
    echo "$BRAINTRUST_PROJECT_ID"
    return
  fi

  # Check cache (1 hour TTL)
  if [ -f "$CACHE_FILE" ] && [ "$(find "$CACHE_FILE" -mmin -60 2>/dev/null)" ]; then
    cat "$CACHE_FILE"
    return
  fi

  local pid
  if [ -n "$OB1_API_KEY" ] && ! should_force_plugin_ingest; then
    # Fetch from OB1 proxy
    pid=$(curl -sf --max-time 30 "${OB1_API_URL}/api/project" \
      -H "Authorization: Bearer ${OB1_API_KEY}" \
      -H "X-User-Id: ${OB1_USER_ID:-}" | jq -r '.id // empty' 2>/dev/null)
  elif [ -n "$BRAINTRUST_API_KEY" ]; then
    # Fetch directly from Braintrust
    pid=$(curl -sf --max-time 30 "https://api.braintrust.dev/v1/project?limit=1" \
      -H "Authorization: Bearer ${BRAINTRUST_API_KEY}" | jq -r '.objects[0].id // empty' 2>/dev/null)
  fi

  if [ -n "$pid" ]; then
    echo "$pid" > "$CACHE_FILE"
    echo "$pid"
  fi
}

# ── Span insertion (posts to OB1 proxy → Braintrust) ───────────────────────

insert_span() {
  local project_id="$1"
  local event_json="$2"

  local row
  row=$(echo "$event_json" | jq --arg pid "$project_id" '. + {project_id: $pid, log_id: "g"}')

  local payload
  payload=$(jq -n --argjson row "$row" '{rows: [$row], api_version: 2}')

  if [ -n "$OB1_API_KEY" ] && ! should_force_plugin_ingest; then
    # Mode 1: OB1 Console proxy with WorkOS API key
    curl -sf --max-time 30 -X POST "${OB1_API_URL}/logs3" \
      -H "Authorization: Bearer ${OB1_API_KEY}" \
      -H "X-User-Id: ${OB1_USER_ID:-}" \
      -H "Content-Type: application/json" \
      -d "$payload" 2>/dev/null
  elif [ -n "$BRAINTRUST_API_KEY" ]; then
    # Mode 2: OB1 Console plugin-ingest endpoint (enriches metadata, uses caller's BT key)
    local proxy_result
    proxy_result=$(curl -sf --max-time 30 -X POST "${OB1_API_URL}/plugin-ingest" \
      -H "Authorization: Bearer ${BRAINTRUST_API_KEY}" \
      -H "X-User-Name: ${USER:-unknown}" \
      ${OB1_ORG_ID:+-H "X-Org-Id: ${OB1_ORG_ID}"} \
      -H "Content-Type: application/json" \
      -d "$payload" 2>/dev/null)

    if [ -n "$proxy_result" ]; then
      echo "$proxy_result"
    else
      # Mode 3: Direct Braintrust fallback (proxy unreachable)
      curl -sf --max-time 30 -X POST "https://api.braintrust.dev/logs3" \
        -H "Authorization: Bearer ${BRAINTRUST_API_KEY}" \
        -H "Content-Type: application/json" \
        -d "$payload" 2>/dev/null
    fi
  fi
}

# ── Cleanup old sessions ───────────────────────────────────────────────────

cleanup_sessions() {
  find "$SESSION_DIR" \( -name "*.json" -o -name "*.lock" \) -mtime +7 -delete 2>/dev/null || true
}
