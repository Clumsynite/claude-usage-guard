#!/bin/sh
# usage-guard.sh - hook logic for the usage-guard plugin.
#
# Usage: usage-guard.sh check | ack | end | status
#
#   check   PreToolUse: stop Claude once per session per plan window when usage runs hot
#   ack     UserPromptSubmit: the user replied, so lift the pause
#   end     SessionEnd: drop this session's state and prune old sessions
#   status  for humans: snapshot, windows, effective config, session state
#
# Hooks never see plan usage; only the status line does. The user's status line
# writes a snapshot ({updated_at, rate_limits}) that this script reads.
# Hook subcommands always exit 0 with no output unless they mean to stop Claude:
# a PreToolUse hook that exits 2 would block every tool call, so failures stay silent.

CFG=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
PLUGIN_ID=usage-guard@clumsyknight-usage-guard
DATA=${CLAUDE_PLUGIN_DATA:-$CFG/plugins/data/usage-guard-clumsyknight-usage-guard}
STATE=$DATA/state
US=$(printf '\037')

# Shared jq definitions. Config values arrive as strings (env or settings.json) and
# fall back to their default unless they are a non-negative number.
# shellcheck disable=SC2016 # jq program: $vars are jq's, not the shell's
DEFS='
def num($s; $d): (try ($s | tonumber) catch null) as $v
	| if ($v | type) == "number" and $v >= 0 then $v else $d end;
def clamp($lo; $hi): if . < $lo then $lo elif . > $hi then $hi else . end;
def isnum: type == "number";
def dur: floor as $s
	| if $s >= 86400 then "\($s / 86400 | floor)d\($s % 86400 / 3600 | floor)h"
	elif $s >= 3600 then "\($s / 3600 | floor)h\($s % 3600 / 60 | floor)m"
	else "\($s / 60 | floor)m" end;
def pct: if . == floor then tostring else . * 10 | round / 10 | tostring end;
def config($e):
	{ p5: (num($e.five_hour_pct; 80) | clamp(1; 100)),
	  l5: num($e.min_left_min; 60),
	  p7: (num($e.seven_day_pct; 90) | clamp(0; 100)),
	  l7: num($e.weekly_min_left_hours; 24),
	  stale: num($e.stale_after_sec; 900) };
def clock: num($nowarg; -1) as $n | if $n >= 0 then $n else (now | floor) end;
def envcfg: { five_hour_pct: $o5, min_left_min: $ol5, seven_day_pct: $o7,
	weekly_min_left_hours: $ol7, stale_after_sec: $ost, snapshot_path: $opath };
# fresh(SNAP; C; NOW) - the snapshot if it is an object with a recent numeric updated_at, else null.
def fresh($s; $c; $now):
	if ($s | type) == "object" and ($s.updated_at | isnum) and ($now - $s.updated_at <= $c.stale)
	then $s else null end;
# window(W; NOW) - the window if its numbers are sane and it has not reset yet, else empty.
def window($w; $now):
	$w | select(type == "object" and (.used_percentage | isnum) and (.resets_at | isnum) and .resets_at > $now);
# hits(SNAP; C; NOW) - the rules that fire: [{key, msg}].
def hits($s; $c; $now):
	[ (window($s.rate_limits.five_hour; $now)
		| (.resets_at - $now | floor) as $left
		| select(.used_percentage >= $c.p5 and $left >= $c.l5 * 60)
		| { key: "5h-\(.resets_at / 3600 | round)",
		    msg: "5-hour plan usage is \(.used_percentage | floor)% with \($left | dur) until reset (limit \($c.p5 | pct)%)." }),
	  (window($s.rate_limits.seven_day; $now)
		| (.resets_at - $now | floor) as $left
		| select($c.p7 > 0 and .used_percentage >= $c.p7 and $left >= $c.l7 * 3600)
		| { key: "7d-\(.resets_at / 3600 | round)",
		    msg: "7-day plan usage is \(.used_percentage | floor)% with \($left | dur) until reset (limit \($c.p7 | pct)%)." })
	];
'

# check prints one line: sid US tool US is_sub US keys US message.
# shellcheck disable=SC2016
CHECK_PROG='
clock as $now
| config(envcfg) as $c
| (try ($snap | fromjson) catch null) as $raw
| (try (fresh($raw; $c; $now) as $s | if $s == null then [] else hits($s; $c; $now) end) catch []) as $h
| [ (.session_id // "" | tostring | gsub("[\u001f\n\r]"; "")),
    (.tool_name // "" | tostring | gsub("[^A-Za-z0-9_.-]"; "")),
    (if (.agent_id // "") != "" then "1" else "0" end),
    ($h | map(.key) | join(",")),
    (if ($h | length) > 0
     then "usage-guard paused Claude: " + ($h | map(.msg) | join(" ")) + " Reply to continue, or tell Claude to stop."
     else "" end)
  ] | join("\u001f")
'

# expand_path RAW - the snapshot file for a configured path: "~/" means $HOME, and an
# empty or non-absolute path means the default.
expand_path() {
	p=$1
	# shellcheck disable=SC2088 # a literal ~/ prefix, expanded by hand
	case $p in
	'~/'*) p=$HOME/${p#'~/'} ;;
	/*) ;;
	*) p=$HOME/.cache/claude-usage-guard/usage.json ;;
	esac
	printf '%s' "$p"
}

# readable FILE - FILE if it can be read, else /dev/null (so --rawfile never fails).
readable() {
	if [ -f "$1" ] && [ -r "$1" ]; then printf '%s' "$1"; else printf '/dev/null'; fi
}

# jq_cfg ARGS... - jq with the userConfig values Claude Code exported to this hook
# bound as strings (see envcfg in DEFS), plus the clock override.
jq_cfg() {
	jq --arg o5 "${CLAUDE_PLUGIN_OPTION_FIVE_HOUR_PCT:-}" \
		--arg ol5 "${CLAUDE_PLUGIN_OPTION_MIN_LEFT_MIN:-}" \
		--arg o7 "${CLAUDE_PLUGIN_OPTION_SEVEN_DAY_PCT:-}" \
		--arg ol7 "${CLAUDE_PLUGIN_OPTION_WEEKLY_MIN_LEFT_HOURS:-}" \
		--arg ost "${CLAUDE_PLUGIN_OPTION_STALE_AFTER_SEC:-}" \
		--arg opath "${CLAUDE_PLUGIN_OPTION_SNAPSHOT_PATH:-}" \
		--arg nowarg "${USAGE_GUARD_NOW:-}" "$@"
}

valid_sid() {
	case $1 in '' | *[!A-Za-z0-9_-]*) return 1 ;; esac
}

# stdin_sid - the session_id from the hook JSON on stdin.
stdin_sid() { jq -r '.session_id // "" | tostring | gsub("[\u001f\n\r]"; "")'; }

# emit IS_SUB MESSAGE - stop the main thread outright; a subagent is only denied, so it
# can hand back its report instead of being killed mid-task.
emit() {
	if [ "$1" = 1 ]; then
		out=$(jq -nc --arg m "$2 You are a subagent: stop calling tools and return a short report now." \
			'{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $m}}')
	else
		out=$(jq -nc --arg m "$2" \
			'{continue: false, stopReason: $m, hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $m}}')
	fi && printf '%s\n' "$out"
}

check() {
	[ "${USAGE_GUARD_DISABLE:-}" = 1 ] && return
	snap=$(readable "$(expand_path "${CLAUDE_PLUGIN_OPTION_SNAPSHOT_PATH:-}")")
	line=$(jq_cfg -r --rawfile snap "$snap" "$DEFS $CHECK_PROG") || return
	IFS=$US read -r sid tool is_sub keys msg <<EOF
$line
EOF
	valid_sid "$sid" || return
	dir=$STATE/$sid

	if [ -e "$dir/pending" ]; then
		case $tool in AskUserQuestion | ExitPlanMode | SubagentHandback) return ;; esac
		m=$(cat "$dir/pending" 2>/dev/null)
		[ -n "$m" ] || m='usage-guard paused Claude. Reply to continue.'
		emit "$is_sub" "$m"
		return
	fi

	[ -n "$keys" ] || return
	mkdir -p "$dir" || return
	# mkdir is atomic: only the first call to create fired-<key> pauses for that window.
	fired=
	old_ifs=$IFS
	IFS=,
	for k in $keys; do
		mkdir "$dir/fired-$k" 2>/dev/null && fired=1
	done
	IFS=$old_ifs
	[ -n "$fired" ] || return
	printf '%s\n' "$msg" >"$dir/pending" || return
	emit "$is_sub" "$msg"
}

ack() {
	[ "${USAGE_GUARD_DISABLE:-}" = 1 ] && return
	sid=$(stdin_sid) || return
	valid_sid "$sid" || return
	rm -f "$STATE/$sid/pending"
}

end_session() {
	[ "${USAGE_GUARD_DISABLE:-}" = 1 ] && return
	sid=$(stdin_sid)
	valid_sid "$sid" && rm -rf "${STATE:?}/$sid"
	# Sessions that crashed never ran SessionEnd; drop their state after 8 days.
	[ -d "$STATE" ] && find "$STATE" -mindepth 1 -maxdepth 1 -type d -mtime +8 -exec rm -rf {} +
}

# shellcheck disable=SC2016
STATUS_PROG='
def wline($label; $w; $now):
	"\($label): " + ([try window($w; $now) catch empty
		| "\(.used_percentage | floor)% used, resets in \(.resets_at - $now | dur)"] | first // "no data");
clock as $now
| (try ($settings_raw | fromjson) catch null) as $st
| ((try $st.pluginConfigs[$id].options catch null) // {}) as $opts
| (try ($snap | fromjson) catch null) as $raw
| envcfg as $env
| ["five_hour_pct", "min_left_min", "seven_day_pct", "weekly_min_left_hours", "snapshot_path", "stale_after_sec"]
| map(. as $k
	| if ($env[$k] // "") != "" then {key: $k, value: $env[$k], src: "env"}
	  elif ($opts | type) == "object" and $opts[$k] != null then {key: $k, value: ($opts[$k] | tostring), src: "settings"}
	  else {key: $k, value: null, src: "default"} end)
| . as $rows
| config($rows | map({(.key): (.value // "")}) | add) as $c
| fresh($raw; $c; $now) as $s
| [ (if $s == null
     then "WARNING: usage-guard is blind: no fresh snapshot at \($path). Add the status line snippet (see README)."
     else empty end),
    "snapshot: \($path) "
      + (if ($raw | type) != "object" then "(missing or unreadable)"
         elif ($raw.updated_at | isnum | not) then "(no updated_at)"
         else "(updated \($now - $raw.updated_at | if . < 0 then 0 else . end | dur) ago"
           + (if $s == null then ", stale)" else ")" end) end),
    wline("5h"; ($raw | try .rate_limits.five_hour catch null); $now),
    wline("7d"; ($raw | try .rate_limits.seven_day catch null); $now),
    "triggers: 5h at \($c.p5 | pct)% with >= \($c.l5 * 60 | dur) left; 7d "
      + (if $c.p7 > 0 then "at \($c.p7 | pct)% with >= \($c.l7 * 3600 | dur) left" else "off" end),
    "config:",
    ({five_hour_pct: ($c.p5 | pct), min_left_min: $c.l5, seven_day_pct: ($c.p7 | pct),
      weekly_min_left_hours: $c.l7, snapshot_path: $path, stale_after_sec: $c.stale} as $eff
     | $rows[] | "  \(.key) = \($eff[.key]) (\(.src))")
  ] | join("\n")
'

status() {
	settings=$(readable "$CFG/settings.json")
	# Outside a hook the userConfig env vars are unset, so read snapshot_path from settings too.
	raw_path=${CLAUDE_PLUGIN_OPTION_SNAPSHOT_PATH:-}
	[ -n "$raw_path" ] || raw_path=$(jq -r --arg id "$PLUGIN_ID" \
		'.pluginConfigs[$id].options.snapshot_path // empty' "$settings" 2>/dev/null)
	path=$(expand_path "$raw_path")
	jq_cfg -nr --rawfile snap "$(readable "$path")" --rawfile settings_raw "$settings" \
		--arg id "$PLUGIN_ID" --arg path "$path" "$DEFS $STATUS_PROG" ||
		echo "usage-guard: could not compute status (is jq >= 1.6 installed?)"
	if [ "${USAGE_GUARD_DISABLE:-}" = 1 ]; then echo "disabled: yes (USAGE_GUARD_DISABLE=1)"; else echo "disabled: no"; fi
	echo "sessions ($STATE):"
	found=
	for d in "$STATE"/*/; do
		[ -d "$d" ] || continue
		found=1
		marks=
		[ -e "${d}pending" ] && marks=" pending"
		for f in "$d"fired-*; do
			[ -e "$f" ] && marks="$marks $(basename "$f")"
		done
		echo "  $(basename "$d"):$marks"
	done
	[ -n "$found" ] || echo "  (none)"
}

usage() { echo "usage: usage-guard.sh check | ack | end | status"; }

case ${1:-} in
check) (check) 2>/dev/null ;;
ack) (ack) 2>/dev/null ;;
end) (end_session) 2>/dev/null ;;
status) status ;;
*) usage >&2 ;;
esac
exit 0
