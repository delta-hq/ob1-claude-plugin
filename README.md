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

## Requirements

`jq`, `curl`, `perl` and `python3` on `PATH`. macOS ships `perl`.
