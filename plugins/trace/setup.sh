#!/bin/bash
# OB1 Trace Plugin — interactive setup
set -e

echo "==> OB1 Trace Setup"
echo ""

# Check requirements
for cmd in jq curl; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Error: $cmd is required. Install with: brew install $cmd"
    exit 1
  fi
done

# Get OB1 API key
if [ -z "${OB1_API_KEY:-}" ]; then
  echo "Enter your OB1 API key (from console.openblocklabs.com/api-keys):"
  read -r -p "  > " OB1_API_KEY
fi

if [ -z "$OB1_API_KEY" ]; then
  echo "Error: OB1 API key is required."
  exit 1
fi

# Console URL
OB1_BASE_URL="${OB1_BASE_URL:-https://console.openblocklabs.com}"
echo ""
echo "Console URL: $OB1_BASE_URL"

# Test connection
echo "Testing connection..."
STATUS=$(curl -sf -o /dev/null -w "%{http_code}" \
  "${OB1_BASE_URL}/api/v1/braintrust/api/project" \
  -H "Authorization: Bearer ${OB1_API_KEY}" \
  -H "X-User-Id: setup" 2>/dev/null || echo "000")

if [ "$STATUS" = "200" ]; then
  echo "Connected successfully."
elif [ "$STATUS" = "401" ]; then
  echo "Error: Invalid API key. Get one at ${OB1_BASE_URL}/api-keys"
  exit 1
else
  echo "Warning: Could not verify connection (status=$STATUS). Continuing anyway."
fi

# Write settings
SETTINGS_FILE="${HOME}/.claude/settings.local.json"
if [ ! -f "$SETTINGS_FILE" ]; then
  echo '{}' > "$SETTINGS_FILE"
fi

# Merge our env vars into settings.local.json
jq --arg key "$OB1_API_KEY" --arg url "$OB1_BASE_URL" \
  '.env = (.env // {}) + {OB1_API_KEY: $key, OB1_BASE_URL: $url}' \
  "$SETTINGS_FILE" > "${SETTINGS_FILE}.tmp" && mv "${SETTINGS_FILE}.tmp" "$SETTINGS_FILE"

echo ""
echo "==> Done! Configuration saved to $SETTINGS_FILE"
echo ""
echo "Your Claude Code sessions will now send traces to OB1 Console."
echo "View them at: ${OB1_BASE_URL}/traces"
