#!/bin/sh
# Self-contained tests for scripts/usage-guard.sh. Uses a throwaway HOME, plugin
# data dir and snapshot; touches nothing else. Usage: sh tests/run.sh
# Set TEST_SH=dash (or bash) to run the script under another /bin/sh.

HERE=$(cd "$(dirname "$0")/.." && pwd -P)
G="$HERE/scripts/usage-guard.sh"
SH=${TEST_SH:-sh}
WORK=$(mktemp -d "${TMPDIR:-/tmp}/usage-guard-test.XXXXXX")
WORK=$(cd "$WORK" && pwd -P)
trap 'rm -rf "$WORK"' EXIT INT TERM

NOW=1790281667
unset CLAUDE_CONFIG_DIR USAGE_GUARD_DISABLE
unset CLAUDE_PLUGIN_OPTION_FIVE_HOUR_PCT CLAUDE_PLUGIN_OPTION_MIN_LEFT_MIN
unset CLAUDE_PLUGIN_OPTION_SEVEN_DAY_PCT CLAUDE_PLUGIN_OPTION_WEEKLY_MIN_LEFT_HOURS
unset CLAUDE_PLUGIN_OPTION_SNAPSHOT_PATH CLAUDE_PLUGIN_OPTION_STALE_AFTER_SEC
export HOME="$WORK/home"
export CLAUDE_PLUGIN_DATA="$WORK/data"
export USAGE_GUARD_NOW=$NOW
export CLAUDE_PLUGIN_OPTION_SNAPSHOT_PATH="$WORK/snap.json"
SNAP="$WORK/snap.json"
STATE="$CLAUDE_PLUGIN_DATA/state"
mkdir -p "$HOME"
cd "$WORK" || exit 1

pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
no() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; [ -n "$2" ] && printf '%s\n' "$2" | sed 's/^/     /'; }

# check NAME OUTPUT PATTERN - OUTPUT must match the grep -E PATTERN.
check() { if printf '%s\n' "$2" | grep -Eq -- "$3"; then ok "$1"; else no "$1" "$2"; fi; }

# snap P5 L5 P7 L7 [UPDATED_AT] - snapshot JSON; an empty P omits that window, L is seconds left.
snap() {
	jq -nc --arg p5 "$1" --arg l5 "$2" --arg p7 "$3" --arg l7 "$4" --arg up "${5:-}" --argjson now "$NOW" '
		{ updated_at: (if $up == "" then $now else ($up | tonumber) end),
		  rate_limits: ({}
			+ (if $p5 != "" then {five_hour: {used_percentage: ($p5 | tonumber), resets_at: ($now + ($l5 | tonumber))}} else {} end)
			+ (if $p7 != "" then {seven_day: {used_percentage: ($p7 | tonumber), resets_at: ($now + ($l7 | tonumber))}} else {} end)) }'
}
setsnap() { snap "$@" >"$SNAP"; }

# hook SID [TOOL] [AGENT_ID] - PreToolUse input JSON.
hook() {
	jq -nc --arg s "$1" --arg t "${2:-Bash}" --arg a "${3:-}" \
		'{session_id: $s, hook_event_name: "PreToolUse", tool_name: $t, permission_mode: "auto"}
		 + (if $a != "" then {agent_id: $a} else {} end)'
}

# chk SID [TOOL] [AGENT_ID] - run check; sets OUT and RC.
chk() { OUT=$(hook "$@" | "$SH" "$G" check 2>&1); RC=$?; }
# chke SID VAR=VALUE... - run check with extra environment.
chke() {
	s=$1
	shift
	OUT=$(hook "$s" | env "$@" "$SH" "$G" check 2>&1)
	RC=$?
}
# raw_chk JSON - run check on literal stdin.
raw_chk() { OUT=$(printf '%s' "$1" | "$SH" "$G" check 2>&1); RC=$?; }
ack() { hook "$1" | "$SH" "$G" ack; }

empty() { if [ -z "$OUT" ] && [ "$RC" -eq 0 ]; then ok "$1"; else no "$1" "rc=$RC out=$OUT"; fi; }
stops() {
	if printf '%s' "$OUT" | jq -e '.continue == false and .hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1; then
		ok "$1"
	else
		no "$1" "rc=$RC out=$OUT"
	fi
}
reason() { printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null; }

echo "# thresholds"
setsnap 54 11400
chk c01
empty "below threshold is silent"
setsnap 82 11400
chk c02
stops "82% with 3h10m left stops Claude"
check "message has the usage" "$(reason)" "82%"
check "message has the time left" "$(reason)" "3h10m until reset"
check "message has the limit" "$(reason)" "limit 80%"
check "stopReason matches the reason" "$(printf '%s' "$OUT" | jq -r .stopReason)" "^usage-guard paused Claude: 5-hour"
setsnap 82 1800
chk c03
empty "too little time left is silent"
setsnap 82 -10
chk c04
empty "window already reset is silent"

echo "# pending and ack"
setsnap 82 11400
chk c02
stops "second check while pending stops again"
check "pending re-shows the full message" "$(reason)" "82% with 3h10m"
for t in AskUserQuestion ExitPlanMode SubagentHandback; do
	chk c02 "$t"
	empty "$t passes while pending"
done
OUT=$(ack c02 2>&1)
RC=$?
empty "ack is silent"
if [ ! -e "$STATE/c02/pending" ]; then ok "ack clears pending"; else no "ack clears pending"; fi
chk c02
empty "after ack the same window stays quiet"
setsnap 82 11490
chk c02
empty "reset time jitter (+90s) is the same window"
setsnap 82 $((11400 + 18000))
chk c02
stops "a new window fires again"
printf '[]' >"$SNAP"
chk c02
stops "pending survives a wrong-shape snapshot"
check "and still shows the stored message" "$(reason)" "82%"

echo "# weekly"
setsnap "" "" 91 259200
chk c10
stops "weekly 91% with 3 days left stops"
check "weekly message" "$(reason)" "7-day plan usage is 91% with 3d0h until reset \(limit 90%\)"
chke c11 CLAUDE_PLUGIN_OPTION_SEVEN_DAY_PCT=0
empty "seven_day_pct=0 disables the weekly rule"
setsnap "" "" 91 3600
chk c12
empty "weekly with less than 24h left is silent"
setsnap 82 11400 91 259200
chk c13
stops "both rules fire together"
check "one message mentions both" "$(reason)" "5-hour .* 7-day"
n=$(find "$STATE/c13" -name 'fired-*' | wc -l | tr -d ' ')
if [ "$n" = 2 ]; then ok "both windows marked fired"; else no "both windows marked fired (got $n)"; fi

echo "# subagents"
setsnap 82 11400
chk c20 Bash a1
if printf '%s' "$OUT" | jq -e '(has("continue") | not) and .hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1; then
	ok "subagent is denied, not stopped"
else
	no "subagent is denied, not stopped" "$OUT"
fi
check "subagent is told to report back" "$(reason)" "You are a subagent"
chk c20
stops "main thread then gets the hard stop"
check "with the full message" "$(reason)" "82%"

echo "# bad snapshots"
bad() {
	printf '%s' "$2" >"$SNAP"
	chk "$1"
	empty "$3"
}
mv "$SNAP" "$WORK/snap.bak"
chk c30
empty "missing snapshot is silent"
bad c31 '{}' "empty object is silent"
bad c32 '[]' "array is silent"
bad c33 '{"rate_limits":5}' "rate_limits of the wrong type is silent"
bad c34 'not json' "garbage is silent"
bad c35 "{\"updated_at\":$NOW}" "no rate_limits is silent"
bad c36 '{"rate_limits":{"five_hour":{"used_percentage":82,"resets_at":1790293067}}}' "missing updated_at counts as stale"
bad c37 '{"updated_at":"x","rate_limits":{"five_hour":{"used_percentage":82,"resets_at":1790293067}}}' "non-number updated_at counts as stale"
bad c38 "{\"updated_at\":$NOW,\"rate_limits\":{\"five_hour\":{\"used_percentage\":\"x\",\"resets_at\":1790293067}}}" "non-number used_percentage is silent"
setsnap "" "" 50 259200
chk c39
empty "only a weekly window below threshold is silent"
setsnap 82 11400 "" "" $((NOW - 1000))
chk c40
empty "snapshot older than stale_after_sec is silent"
chke c41 CLAUDE_PLUGIN_OPTION_STALE_AFTER_SEC=2000
stops "a larger stale_after_sec accepts it"

echo "# hook input"
setsnap 82 11400
before=$(find "$WORK" -name 'fired-*' | wc -l | tr -d ' ')
raw_chk '{"tool_name":"Bash"}'
empty "missing session_id is silent"
raw_chk '{"session_id":"../x","tool_name":"Bash"}'
empty "session_id with a path is silent"
raw_chk '{"session_id":"a b","tool_name":"Bash"}'
empty "session_id with a space is silent"
after=$(find "$WORK" -name 'fired-*' | wc -l | tr -d ' ')
if [ "$before" = "$after" ]; then ok "bad session ids create nothing"; else no "bad session ids create nothing ($before -> $after)"; fi
outside=$(find "$WORK" -name 'fired-*' ! -path "$STATE/*")
if [ -z "$outside" ]; then ok "nothing written outside the state dir"; else no "nothing written outside the state dir" "$outside"; fi
raw_chk '{"session_id":"c50"}'
stops "missing tool_name still fires (fields don't shift)"
raw_chk '{"session_id":'
empty "truncated stdin fails open"
raw_chk ''
empty "empty stdin fails open"

echo "# config"
setsnap 82 11400
chke c60 CLAUDE_PLUGIN_OPTION_FIVE_HOUR_PCT=abc
stops "non-numeric five_hour_pct falls back to 80"
chke c61 CLAUDE_PLUGIN_OPTION_FIVE_HOUR_PCT=85
empty "five_hour_pct=85 is silent at 82%"
chke c62 CLAUDE_PLUGIN_OPTION_FIVE_HOUR_PCT=81.5
stops "decimal five_hour_pct=81.5 fires at 82%"
check "decimal limit is shown" "$(reason)" "limit 81.5%"
chke c63 CLAUDE_PLUGIN_OPTION_FIVE_HOUR_PCT=150
empty "five_hour_pct=150 is clamped to 100"
setsnap 54 11400
chke c64 CLAUDE_PLUGIN_OPTION_FIVE_HOUR_PCT=0
stops "five_hour_pct=0 is clamped to 1"
setsnap 82 3000
chke c65 CLAUDE_PLUGIN_OPTION_MIN_LEFT_MIN=30
stops "min_left_min=30 fires with 50m left"
check "short durations are minutes" "$(reason)" "with 50m until reset"
chke c66 CLAUDE_PLUGIN_OPTION_MIN_LEFT_MIN=-5
empty "negative min_left_min falls back to 60"

echo "# snapshot path"
snap 82 11400 >"$HOME/snap.json"
# shellcheck disable=SC2088 # literal tilde on purpose
chke c70 CLAUDE_PLUGIN_OPTION_SNAPSHOT_PATH='~/snap.json'
stops "a leading tilde in snapshot_path means HOME"
mkdir -p "$HOME/.cache/claude-usage-guard"
snap 54 11400 >"$HOME/.cache/claude-usage-guard/usage.json"
snap 82 11400 >"$WORK/relative.json"
chke c71 CLAUDE_PLUGIN_OPTION_SNAPSHOT_PATH=relative.json
empty "relative snapshot_path ignores the cwd file"
snap 82 11400 >"$HOME/.cache/claude-usage-guard/usage.json"
chke c72 CLAUDE_PLUGIN_OPTION_SNAPSHOT_PATH=relative.json
stops "relative snapshot_path falls back to the default file"

echo "# disable and isolation"
setsnap 82 11400
chke c02 USAGE_GUARD_DISABLE=1
empty "USAGE_GUARD_DISABLE=1 is silent even while pending"
chk c80
stops "session c80 fires"
chk c81
stops "session c81 fires independently"

echo "# fail-open"
printf 'x' >"$WORK/notadir"
chke c90 CLAUDE_PLUGIN_DATA="$WORK/notadir"
empty "unwritable state dir fails open"

echo "# end"
chk c95
[ -d "$STATE/c95" ] || no "setup: c95 state exists"
mkdir -p "$STATE/old" "$STATE/fresh"
touch -t 202001010000 "$STATE/old"
OUT=$(hook c95 | "$SH" "$G" end 2>&1)
RC=$?
empty "end is silent"
if [ ! -e "$STATE/c95" ]; then ok "end removes the session"; else no "end removes the session"; fi
if [ ! -e "$STATE/old" ]; then ok "end prunes sessions older than 8 days"; else no "end prunes sessions older than 8 days"; fi
if [ -d "$STATE/fresh" ]; then ok "end keeps recent sessions"; else no "end keeps recent sessions"; fi

echo "# status"
setsnap 82 11400 61 259200
OUT=$("$SH" "$G" status 2>&1)
check "status shows the 5h window" "$OUT" "^5h: 82% used, resets in 3h10m"
check "status shows the 7d window" "$OUT" "^7d: 61% used"
check "status lists sessions" "$OUT" "c80: pending fired-5h-"
OUT=$(env CLAUDE_PLUGIN_OPTION_SNAPSHOT_PATH="$WORK/none.json" "$SH" "$G" status 2>&1)
check "status warns when blind" "$(printf '%s\n' "$OUT" | head -1)" "^WARNING: usage-guard is blind"
mkdir -p "$HOME/.claude"
jq -n --arg p "$SNAP" '{pluginConfigs: {"usage-guard@clumsyknight-usage-guard": {options: {five_hour_pct: 70, snapshot_path: $p}}}}' >"$HOME/.claude/settings.json"
OUT=$(env -u CLAUDE_PLUGIN_OPTION_SNAPSHOT_PATH "$SH" "$G" status 2>&1)
check "status reads config from settings.json" "$OUT" "five_hour_pct = 70 \(settings\)"
check "status reads snapshot_path from settings.json" "$OUT" "snapshot_path = $SNAP \(settings\)"
check "status is not blind with the settings path" "$(printf '%s\n' "$OUT" | head -1)" "^snapshot: "
OUT=$("$SH" "$G" bogus 2>&1)
RC=$?
check "unknown subcommand prints usage" "$OUT" "usage:"
if [ "$RC" -eq 0 ]; then ok "unknown subcommand exits 0"; else no "unknown subcommand exits 0 (got $RC)"; fi

echo "# performance"
setsnap 54 11400
IN=$(hook perf)
start=$(perl -MTime::HiRes=time -e 'printf "%d", time*1000')
i=0
while [ $i -lt 20 ]; do
	printf '%s' "$IN" | "$SH" "$G" check >/dev/null
	i=$((i + 1))
done
end=$(perl -MTime::HiRes=time -e 'printf "%d", time*1000')
avg=$(((end - start) / 20))
if [ "$avg" -lt 200 ]; then ok "silent check averages ${avg}ms (<200ms)"; else no "silent check averages ${avg}ms (<200ms)"; fi

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
