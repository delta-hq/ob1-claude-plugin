#!/bin/bash
# OB1 Trace Plugin — setup
# Wires trace hooks directly into ~/.claude/settings.json
set -e

echo "==> OB1 Trace Setup"

# Check requirements
for cmd in jq curl python3; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Error: $cmd is required. Install with: brew install $cmd"
    exit 1
  fi
done

# Find the hooks directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS_DIR="$SCRIPT_DIR/hooks"

if [ ! -f "$HOOKS_DIR/session_start.sh" ]; then
  echo "Error: hooks not found at $HOOKS_DIR"
  exit 1
fi

# Wire hooks into settings.json
SETTINGS="$HOME/.claude/settings.json"
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"

python3 -c "
import json, sys
hooks_dir = '$HOOKS_DIR'
with open('$SETTINGS') as f:
    s = json.load(f)
s['hooks'] = s.get('hooks', {})
s['hooks']['SessionStart'] = [{'hooks': [{'type': 'command', 'command': f'bash {hooks_dir}/session_start.sh', 'async': True}]}]
s['hooks']['UserPromptSubmit'] = [{'hooks': [{'type': 'command', 'command': f'bash {hooks_dir}/user_prompt_submit.sh', 'async': True}]}]
s['hooks']['PostToolUse'] = [{'matcher': '*', 'hooks': [{'type': 'command', 'command': f'bash {hooks_dir}/post_tool_use.sh', 'async': True}]}]
s['hooks']['Stop'] = [{'hooks': [{'type': 'command', 'command': f'bash {hooks_dir}/stop_hook.sh', 'async': True}]}]
s['hooks']['SessionEnd'] = [{'hooks': [{'type': 'command', 'command': f'bash {hooks_dir}/session_end.sh', 'async': True}]}]
with open('$SETTINGS', 'w') as f:
    json.dump(s, f, indent=2)
print('  Hooks wired into settings.json')
"

# Test Braintrust connection (auto-discovers key from MCP config)
source "$HOOKS_DIR/common.sh" 2>/dev/null
if tracing_enabled; then
  PID=$(get_project_id 2>/dev/null)
  if [ -n "$PID" ]; then
    echo "  Braintrust connected (project: $PID)"
  else
    echo "  Warning: could not reach Braintrust. Check your API key."
  fi
else
  echo "  Warning: no Braintrust API key found. Add the Braintrust MCP server or set BRAINTRUST_API_KEY."
fi

echo ""
echo "==> Done! Start a new Claude session to begin tracing."
