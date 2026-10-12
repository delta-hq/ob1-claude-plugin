# OB1 Claude Code plugin

`plugins/trace` sends Claude Code sessions, turns, tool calls and LLM calls to OB1 Console as traces.

## Install

Install the `trace` plugin from this marketplace. Its hooks load from `plugins/trace/hooks/hooks.json`.

`plugins/trace/setup.sh` is the fallback for Claude Code builds that do not load plugin hooks. It writes the same hooks into `~/.claude/settings.json`.

## Do not install the hooks twice

Use the plugin or `setup.sh`, not both. If the hooks are in `~/.claude/settings.json` and the plugin is enabled, every hook runs twice. Turn and tool spans are sent twice, and every hook process runs twice.

To check, run:

```bash
jq '.hooks | tostring | test("trace/hooks/")' ~/.claude/settings.json
```

If it prints `true` and the plugin is enabled, remove those hook entries from `settings.json`.

`setup.sh` replaces any existing `SessionStart`, `UserPromptSubmit`, `PostToolUse`, `Stop` and `SessionEnd` hooks in `settings.json`. Back up your hooks before you run it.

## Configuration

The hooks read these variables from the environment. If a variable is not set, they look in the `env` block of `~/.claude/settings.json` and `~/.claude/settings.local.json`.

| Variable | Use |
|---|---|
| `OB1_BASE_URL` | OB1 Console URL. Default `https://console.openblocklabs.com`. |
| `OB1_API_KEY` | OB1 Console key. Spans go to the console's `logs3` proxy. Falls back to `default.api_key` in `~/.ob1/credentials.json`. |
| `OB1_ORG_ID` | Sent as the `X-Org-Id` header to `plugin-ingest`. Falls back to `oauth.organization_id` in `~/.ob1/credentials.json`. |
| `BRAINTRUST_API_KEY` | Used when there is no OB1 key. Spans go to the console's `plugin-ingest`, and straight to Braintrust if the console does not answer. Also read from the `braintrust` MCP server's `--api-key` argument. |
| `BRAINTRUST_PROJECT_ID` | Skips the project lookup. In the settings `env` block, `OB1_BRAINTRUST_PROJECT_ID` also works. |
| `OB1_FORCE_PLUGIN_INGEST` | Set to `1` to ignore `OB1_API_KEY` and always send through `plugin-ingest` with `BRAINTRUST_API_KEY`. |

## Requirements

`jq`, `curl`, `perl` and `python3` on `PATH`. macOS ships `perl`.
