#!/bin/bash
# Reconnect Claude Code desktop sessions that are running outside Sleev.
#
# The ccd-cli shims only catch sessions started after a new CLI version is
# wrapped. On an update the app respawns its open sessions on the new binary
# within ~2.5s, and any that start before the wrap talk to Anthropic directly
# for their whole life. A session can also run direct if the gateway was down
# when it started. Sleev never sees either kind, so nothing else will notice.
#
# Killing such a session is safe once it is idle: the app shows "Session was
# interrupted" and respawns it through the shim on the next message, resuming
# the same transcript (tested 2026-10-08). So for each bypassed session:
#   idle, gateway up, every version wrapped -> SIGTERM it and notify
#   otherwise                               -> notify once, retry next run
# Run by sleev-check-sessions.timer.
#
# Kill guards: the session has no child processes (Bash tool shells and
# background commands live there), no subagent transcript newer than its own
# (a background agent is running), and was not already killed in the last
# KILL_COOLDOWN seconds (a session that comes back bypassed gets a notice
# instead of a kill loop). The pid's start time, exe and env are re-checked
# right before the kill.
#
# Test knobs: SLEEV_CHECK_DRY_RUN=1 (report only, no kill, no toast),
# SLEEV_CHECK_QUIET=1 (print toasts instead of showing them), and the
# SLEEV_CCD_DIR / SLEEV_PROJECTS_DIR / SLEEV_STATE_DIR / SLEEV_URL overrides.

set -u
SLEEV_URL="${SLEEV_URL:-http://127.0.0.1:17321}"
CCD="${SLEEV_CCD_DIR:-$HOME/.claude/remote/ccd-cli}"
PROJECTS="${SLEEV_PROJECTS_DIR:-$HOME/.claude/projects}"
STATE="${SLEEV_STATE_DIR:-$HOME/.local/state/sleev}/bypass-notified"
DRY_RUN="${SLEEV_CHECK_DRY_RUN:-0}"
QUIET="${SLEEV_CHECK_QUIET:-0}"
POWERSHELL=/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe
IDLE_SECS=10        # transcript must be this quiet before we kill
KILL_COOLDOWN=600   # never kill the same session twice within this window
KILLED="$(dirname "$STATE")/bypass-killed"   # "<resume-id> <epoch>" lines

# A session is any process whose exe lives directly in ccd-cli/: the bare
# binary (spawned before the wrap) or <name>.sleev-real (the shim's exec),
# with " (deleted)" once pruned. Matched by location, never by version name,
# so a naming change in the app can't blind this check the way it blinded
# the old regex on 2026-10-09.
is_session_exe() {
  local v=${1% (deleted)}
  [[ $v == "$CCD"/* ]] || return 1
  v=${v#"$CCD"/}
  [[ $v != */* && $v != .* ]]
}

# Idle means the transcript's last turn ended (or was interrupted) and nothing
# has been written for IDLE_SECS. Anything else, including a session with no
# --resume or no transcript, counts as busy; we never guess.
resume_id() {
  local id
  id=$(tr '\0' '\n' < "/proc/$1/cmdline" 2>/dev/null | sed -n 's/^--resume=//p' | head -n1)
  [[ $id =~ ^[0-9a-f-]+$ ]] && echo "$id"
}

is_idle() {
  local pid=$1 id f s
  pgrep -P "$pid" >/dev/null && return 1
  id=$(resume_id "$pid") || return 1
  f=$(compgen -G "$PROJECTS/*/$id.jsonl" | head -n1)
  [[ -n $f ]] || return 1
  for s in "$PROJECTS"/*/"$id"/subagents/*.jsonl; do
    [[ -e $s && $s -nt $f ]] && return 1
  done
  (( $(date +%s) - $(stat -c %Y "$f") >= IDLE_SECS )) || return 1
  tail -n 50 "$f" | python3 -c '
import json, sys
last = None
for line in sys.stdin:
    try:
        d = json.loads(line)
    except ValueError:
        continue
    if d.get("type") in ("user", "assistant"):
        last = d
if last is None:
    sys.exit(1)
m = last.get("message") or {}
if last["type"] == "assistant":
    sys.exit(0 if m.get("stop_reason") in ("end_turn", "stop_sequence") else 1)
c = m.get("content")
text = c if isinstance(c, str) else " ".join(
    x.get("text", "") for x in c or [] if isinstance(x, dict))
sys.exit(0 if text.startswith("[Request interrupted by user") else 1)
'
}

# Field 22 of /proc/PID/stat; comm (field 2) may contain spaces, so cut after ")".
start_time() { local st; st=$(cat "/proc/$1/stat" 2>/dev/null) || return 1; st=${st##*) }; set -- $st; echo "${20}"; }

routed() { [[ $(tr '\0' '\n' < "/proc/$1/environ" 2>/dev/null | sed -n 's/^ANTHROPIC_BASE_URL=//p') == "$SLEEV_URL" ]]; }

# Still the same bypassed session we listed (guards against pid reuse).
same_session() {
  local pid=$1 start=$2
  [[ $(start_time "$pid") == "$start" ]] || return 1
  is_session_exe "$(readlink "/proc/$pid/exe" 2>/dev/null)" || return 1
  ! routed "$pid"
}

recently_killed() {
  local id=$1 now
  now=$(date +%s)
  awk -v id="$id" -v now="$now" -v cd="$KILL_COOLDOWN" '$1 == id && now - $2 < cd {f=1} END {exit !f}' "$KILLED" 2>/dev/null
}

gateway_up() { curl -s -o /dev/null --max-time 3 "$SLEEV_URL/" 2>/dev/null; }

# A killed session respawns on whatever version the app picks; make sure that
# is a shim, not a binary that landed seconds ago and is still unwrapped.
# Once wrapped, a name holds a bash shim, so any ELF still sitting at a name
# the wrapper would manage means unwrapped. Skip list matches the wrapper's
# is_candidate in sleev-wrap-ccd-cli.sh; keep the two in sync.
all_wrapped() {
  local v n
  for v in "$CCD"/*; do
    n=${v##*/}
    case $n in
      .*|*.sleev-real|*.tmp*|*.part*|*.download*|*.zst|*.lock|*~) continue ;;
      *.so|*.so.*|*.node) continue ;;
    esac
    [[ -f $v ]] || continue
    head -c4 -- "$v" | grep -q ELF && return 1
  done
  return 0
}

notify() {
  local title=$1 body=$2
  if [[ $DRY_RUN == 1 || $QUIET == 1 ]]; then
    echo "toast: $title | $body"
    return
  fi
  # Windows toast via the stock PowerShell app id (no module install needed).
  "$POWERSHELL" -NoProfile -NonInteractive -Command "
    [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] > \$null
    \$x = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent([Windows.UI.Notifications.ToastTemplateType]::ToastText02)
    \$t = \$x.GetElementsByTagName('text')
    \$t.Item(0).AppendChild(\$x.CreateTextNode('$title')) > \$null
    \$t.Item(1).AppendChild(\$x.CreateTextNode('$body')) > \$null
    \$app = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
    [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier(\$app).Show([Windows.UI.Notifications.ToastNotification]::new(\$x))
  " || { rc=$?; echo "$(date -Is) toast failed (exit $rc)"; }
}

bypassed=()
declare -A started
for d in /proc/[0-9]*; do
  exe=$(readlink "$d/exe" 2>/dev/null) || continue
  is_session_exe "$exe" || continue
  # Skip a session's own helper processes; they inherit its environment.
  ppid=$(awk '/^PPid:/ {print $2}' "$d/status" 2>/dev/null)
  is_session_exe "$(readlink "/proc/$ppid/exe" 2>/dev/null)" && continue
  routed "${d#/proc/}" && continue
  bypassed+=("${d#/proc/}")
  started[${d#/proc/}]=$(start_time "${d#/proc/}")
done

mkdir -p "$(dirname "$STATE")"
# Drop kill records older than the cooldown.
if [[ -s $KILLED ]]; then
  awk -v now="$(date +%s)" -v cd="$KILL_COOLDOWN" 'now - $2 < cd' "$KILLED" > "$KILLED.tmp" && mv -f "$KILLED.tmp" "$KILLED"
fi
[[ ${#bypassed[@]} -eq 0 ]] && { : > "$STATE"; exit 0; }

can_kill=0
gateway_up && all_wrapped && can_kill=1
killed=() waiting=()
for pid in "${bypassed[@]}"; do
  # Race losers still run the bare binary; gateway-down fallbacks run .sleev-real.
  exe=$(readlink "/proc/$pid/exe" 2>/dev/null)
  [[ $exe == *.sleev-real* ]] && why=fallback || why=missed-update
  id=$(resume_id "$pid")
  if [[ $can_kill != 1 ]]; then
    reason="gateway down or unwrapped version"
  elif [[ -n $id ]] && recently_killed "$id"; then
    reason="already restarted once recently"
  elif ! same_session "$pid" "${started[$pid]}"; then
    continue   # exited or got replaced since we listed it
  elif ! is_idle "$pid"; then
    reason=busy
  elif [[ $DRY_RUN == 1 ]]; then
    echo "$(date -Is) pid $pid bypassed ($why), idle: would kill"
    killed+=("$pid"); continue
  elif kill -TERM "$pid" 2>/dev/null; then
    echo "$(date -Is) pid $pid bypassed ($why), idle: killed"
    echo "$id $(date +%s)" >> "$KILLED"
    killed+=("$pid"); continue
  else
    continue   # gone between the check and the kill
  fi
  echo "$(date -Is) pid $pid bypassed ($why), $reason: waiting"
  waiting+=("$pid")
done

if [[ ${#killed[@]} -gt 0 ]]; then
  n=${#killed[@]}
  [[ $n -eq 1 ]] && what="1 Claude session" || what="$n Claude sessions"
  notify "Sleev: reconnected $what" \
    "They missed a Claude update. Ignore the Session was interrupted note and keep typing; your next message goes through Sleev."
fi

# Waiting sessions are retried every run; notify only when a new one appears.
seen=$(cat "$STATE" 2>/dev/null)
printf '%s\n' ${waiting[@]+"${waiting[@]}"} > "$STATE"
new=0
for pid in ${waiting[@]+"${waiting[@]}"}; do
  grep -qx "$pid" <<<"$seen" || new=1
done
if [[ $new -eq 1 ]]; then
  n=${#waiting[@]}
  [[ $n -eq 1 ]] && what="1 Claude session is" || what="$n Claude sessions are"
  notify "Sleev: $what not being tracked" \
    "Sleev will reconnect them automatically once they are idle. If this keeps showing, fully quit Claude (system tray icon, Quit) and reopen it."
fi
exit 0
