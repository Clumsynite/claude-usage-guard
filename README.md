# usage-guard

[![CI](https://github.com/Clumsynite/claude-usage-guard/actions/workflows/ci.yml/badge.svg)](https://github.com/Clumsynite/claude-usage-guard/actions/workflows/ci.yml)
[![Release](https://github.com/Clumsynite/claude-usage-guard/actions/workflows/release.yml/badge.svg)](https://github.com/Clumsynite/claude-usage-guard/actions/workflows/release.yml)
[![Latest release](https://img.shields.io/github/v/release/Clumsynite/claude-usage-guard?display_name=release)](https://github.com/Clumsynite/claude-usage-guard/releases/latest)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

A Claude Code plugin that pauses Claude before its next tool call when your plan usage is running hot: by default, when the 5-hour window is **80% used with at least an hour still to go**, or the weekly window is **90% used with at least a day to go**. You see why it stopped, and Claude continues when you reply.

## Why

Claude can't see your plan usage. Only the status line gets it, so a long autonomous run can burn through a 5-hour window in the first hour and leave you locked out for the next four. usage-guard reads the numbers your status line already receives and stops Claude once per window, while you still have room to decide: carry on, switch to something cheaper, or stop for now.

It fires when you're burning **fast**, meaning high usage with plenty of window left. Near the end of a window it stays quiet, because hitting the cap then costs you little.

## Token cost

Zero on the normal path. usage-guard is hooks only: no skills, no MCP server, nothing added to Claude's context. When usage is below the thresholds, the hook exits silently. When it fires, the pause message (about 60 tokens) is shown once and stays in the conversation.

## Install

From GitHub:

```
/plugin marketplace add Clumsynite/claude-usage-guard
/plugin install usage-guard@clumsyknight-usage-guard
```

From a local clone:

```
claude plugin marketplace add /path/to/claude-usage-guard
claude plugin install usage-guard@clumsyknight-usage-guard --scope user
```

A local marketplace loads the plugin in place, so edits take effect after `/reload-plugins`.

Requires macOS or Linux (POSIX `sh`) and `jq` 1.6 or later (tested on 1.7.1 and 1.8.2). Windows isn't supported. Plan usage is only reported for claude.ai Pro and Max subscriptions.

## Setup (required): let the guard see your usage

Hooks never receive usage data, and a plugin can't install a status line. Your status line has to write a small snapshot file, which the guard reads. Pick one of these.

**A. You already have a sh/bash status line script.** Paste this right after the line that reads stdin into `$input` (e.g. `input=$(cat)`):

```sh
# usage-guard: snapshot plan usage for the usage-guard plugin
if printf '%s' "$input" | jq -e '.rate_limits' >/dev/null 2>&1; then
  d="$HOME/.cache/claude-usage-guard"; mkdir -p "$d" 2>/dev/null
  printf '%s' "$input" | jq -c '{updated_at: now, rate_limits}' > "$d/.usage.$$" 2>/dev/null \
    && mv -f "$d/.usage.$$" "$d/usage.json" 2>/dev/null
fi
```

**B. You have no status line, or one written in Python or Node.** Save this as `~/.claude/usage-guard-statusline.sh`:

```sh
#!/bin/sh
input=$(cat)
# usage-guard: snapshot plan usage for the usage-guard plugin
if printf '%s' "$input" | jq -e '.rate_limits' >/dev/null 2>&1; then
  d="$HOME/.cache/claude-usage-guard"; mkdir -p "$d" 2>/dev/null
  printf '%s' "$input" | jq -c '{updated_at: now, rate_limits}' > "$d/.usage.$$" 2>/dev/null \
    && mv -f "$d/.usage.$$" "$d/usage.json" 2>/dev/null
fi
printf '%s' "$input" | jq -r '[.model.display_name, (.rate_limits.five_hour.used_percentage // empty | "5h \(floor)%"), (.rate_limits.seven_day.used_percentage // empty | "7d \(floor)%")] | map(select(. != null)) | join(" | ")'
```

Then point your settings at it (`~/.claude/settings.json`):

```json
"statusLine": {
  "type": "command",
  "command": "sh ~/.claude/usage-guard-statusline.sh",
  "refreshInterval": 60
}
```

If your status line is in another language, you can pipe its input through script B, or write the same `{updated_at, rate_limits}` JSON yourself.

In both cases, `"refreshInterval": 60` is recommended. The status line normally re-runs only on events, and it goes quiet while the main session waits on background subagents, which is exactly when usage climbs fastest.

## Configure

Set these in `/config` (plugin options):

| Option | Default | Meaning |
|---|---|---|
| `five_hour_pct` | 80 | Pause when 5-hour usage is at or above this % (1–100) |
| `min_left_min` | 60 | …and at least this many minutes remain before it resets |
| `seven_day_pct` | 90 | Pause when weekly usage is at or above this % (0 turns the weekly check off) |
| `weekly_min_left_hours` | 24 | …and at least this many hours remain before it resets |
| `snapshot_path` | `~/.cache/claude-usage-guard/usage.json` | The file your status line writes |
| `stale_after_sec` | 900 | Ignore a snapshot older than this, so stale data never causes a pause |

Invalid values fall back to the default.

## Pause and resume

When a threshold is crossed, the next tool call is blocked and Claude stops, showing a warning like:

```
usage-guard paused Claude: 5-hour plan usage is 82% with 3h10m until reset (limit 80%). Reply to continue, or tell Claude to stop.
```

Reply with anything. "continue" carries on; "wrap up and stop" or "switch to a cheaper approach" does what it says. Each session pauses **once per window**. A new session started while usage is still high pauses once on its first tool call.

If a subagent crosses the threshold, it's told to stop and report back instead of being killed mid-task. The main thread then stops with the same message.

**Unattended runs.** The snapshot is shared by every session on the machine, so headless (`claude -p`), SDK, and unattended auto-mode runs are paused too, and they'll wait for a reply nobody sends. To exempt a run, set `USAGE_GUARD_DISABLE=1` in its environment:

```
USAGE_GUARD_DISABLE=1 claude -p "..."
```

## Check it

`status` shows what the guard sees: the snapshot's age, both windows, the triggers, where each setting comes from, and each session's pause state. Its first line warns if the guard is blind.

```sh
# installed from GitHub (picks the newest cached version)
sh "$(ls -d ~/.claude/plugins/cache/clumsyknight-usage-guard/usage-guard/*/ | sort -V | tail -1)scripts/usage-guard.sh" status
# installed from a local clone
sh /path/to/claude-usage-guard/scripts/usage-guard.sh status
```

```
snapshot: /home/you/.cache/claude-usage-guard/usage.json (updated 0m ago)
5h: 54% used, resets in 3h10m
7d: 61% used, resets in 4d23h
triggers: 5h at 80% with >= 1h0m left; 7d at 90% with >= 1d0h left
config:
  five_hour_pct = 80 (default)
  ...
```

## How it works

- `PreToolUse` (every tool) runs `usage-guard.sh check`: one `jq` call reads the hook input and the snapshot. If a rule fires for a window this session hasn't paused for, the hook returns `continue: false` and a `deny` to stop Claude, and marks the session as pending.
- `UserPromptSubmit` runs `ack`: you replied, so the pause is lifted.
- `SessionEnd` runs `end`: a pending pause is dropped, but the session keeps its record of which windows it already paused for, so a resumed session (same id) does not pause again. State untouched for 8 days is pruned.

State lives in the plugin's data directory (`~/.claude/plugins/data/usage-guard-clumsyknight-usage-guard/state/<session>/`). The guard **fails open**: a missing, stale or malformed snapshot, bad input, or any internal error means no pause, never a blocked tool.

## Limitations

- Pro and Max plans only (`rate_limits` isn't reported otherwise), and only after the session's first API response.
- Needs the status line setup above. Without a fresh snapshot the guard stays silent, so run `status` once to confirm it can see your usage.
- Usage is as fresh as the last status line refresh.
- When several tool calls start at the same instant, one sibling call may slip through before the pause takes hold.
- One snapshot per file: if you run several accounts (separate `CLAUDE_CONFIG_DIR`s), give each its own `snapshot_path`.
- macOS and Linux only.

## Development

```
sh tests/run.sh                    # script tests with a throwaway HOME and data dir
TEST_SH=dash sh tests/run.sh       # the same under dash
shellcheck -s sh scripts/usage-guard.sh tests/run.sh
claude plugin validate --strict . && claude plugin validate --strict .claude-plugin/plugin.json
```

## Releasing

CI (`.github/workflows/ci.yml`) runs shellcheck, the manifest checks, and the tests on Ubuntu and macOS (plus dash and the system jq on macOS) for every push to `main` and every pull request.

Releases are tag-driven:

1. Bump `version` in `.claude-plugin/plugin.json`, commit, push, and wait for green CI.
2. `claude plugin tag --push .` validates the manifests and pushes the tag `usage-guard--v<version>`.
3. `.github/workflows/release.yml` checks that the tag matches `plugin.json`, reruns the full CI, then creates the GitHub release with generated notes. Re-running it for an existing release does nothing.

Users pick up new versions with `/plugin update usage-guard@clumsyknight-usage-guard`.

## License

MIT
