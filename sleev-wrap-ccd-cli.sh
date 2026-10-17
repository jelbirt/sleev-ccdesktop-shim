#!/bin/bash
# Keep the Claude Code desktop bridge's CLI binaries wrapped with the Sleev shim,
# so desktop-spawned sessions route through the local gateway.
#
# Handles the app-update case observed 2026-08-25: the updater downloads a new
# version AND deletes the .sleev-real originals, leaving dangling shims behind.
# Run by sleev-wrap-ccd.path (inotify) and sleev-wrap-ccd.timer (backstop).
# SLEEV_CCD_DIR overrides the directory, for testing against a scratch copy.

set -u
DIR="${SLEEV_CCD_DIR:-$HOME/.claude/remote/ccd-cli}"
GATEWAY_PORT=17321
cd "$DIR" 2>/dev/null || exit 0

shopt -s nullglob

# One run at a time. Two runs wrapping the same binary can hard-link the shim
# over .sleev-real and lose the original for good, and the timer, the .path
# unit and a manual run can all overlap. The lock lives outside the watched
# folder so taking it doesn't retrigger the .path unit.
LOCK="${SLEEV_STATE_DIR:-$HOME/.local/state/sleev}/wrap.lock"
mkdir -p "$(dirname "$LOCK")" && exec 9>>"$LOCK" && flock 9 || exit 1

# The shim text, built once and used both to wrap new binaries and to refresh
# shims written by an older version of this script. Quoted heredoc: nothing here
# expands at build time, only __PORT__ is substituted below.
SHIM_TEXT=$(cat <<'SHIM'
#!/bin/bash
# Sleev shim: route desktop-app sessions through the local Sleev gateway.
#
# This probe decides ONCE for the whole life of the session. On failure the
# process keeps the app's default ANTHROPIC_BASE_URL and never re-checks, so a
# lost probe means a silently uncaptured session. On 2026-09-04 three sessions
# spawned at 14:06:05 during a bridge restart and all three lost a 0.5s budget
# to cold-start latency; the gateway was healthy and never saw the connection.
# Hence a real timeout, retries, and a fallback that announces itself.
sleev_up() {
  for _ in 1 2 3; do
    curl -s -o /dev/null --max-time 3 http://127.0.0.1:__PORT__/ 2>/dev/null && return 0
    sleep 0.4
  done
  return 1
}

if sleev_up; then
  export ANTHROPIC_BASE_URL="http://127.0.0.1:__PORT__"
  export ANTHROPIC_CUSTOM_HEADERS=$'sleev-provider: anthropic\nsleev-harness: claude code'
else
  _slv_log="$HOME/.local/state/sleev/shim-fallback.log"
  mkdir -p "$(dirname "$_slv_log")" 2>/dev/null
  echo "$(date -Is) gateway unreachable after 3 tries; session running DIRECT (uncaptured) pid=$$" >> "$_slv_log" 2>/dev/null
  echo "[sleev-shim] gateway unreachable after 3 tries, running DIRECT (uncaptured)" >&2
fi

# The desktop bridge passes the model as an explicit --model flag, which takes
# precedence over ANTHROPIC_MODEL. It offers no way to request the extended 1M
# context window, so desktop sessions run against a 200K limit and auto-compact
# at ~168k tokens (~84% of 200K) even though the API accepts far more. Append the
# [1m] tag to whatever model the app chose, preserving its selection.
# To disable: delete this block and exec with "$@" unchanged.
tag_1m() {
  case "$1" in
    *'[1m]') printf '%s' "$1" ;;   # already tagged
    *haiku*) printf '%s' "$1" ;;   # 200K model, no extended window
    *)       printf '%s[1m]' "$1" ;;
  esac
}

args=()
want_model=0
for a in "$@"; do
  if [ "$want_model" -eq 1 ]; then
    args+=("$(tag_1m "$a")")
    want_model=0
    continue
  fi
  case "$a" in
    --model)   args+=("$a"); want_model=1 ;;
    --model=*) args+=("--model=$(tag_1m "${a#--model=}")") ;;
    *)         args+=("$a") ;;
  esac
done

exec "$0.sleev-real" ${args[@]+"${args[@]}"}
SHIM
)
SHIM_TEXT=${SHIM_TEXT//__PORT__/$GATEWAY_PORT}

# Files we manage are matched by what they are, not by name: on 2026-10-09 the
# app switched from "2.1.293" to "2.1.293-63201613aae3" and a name regex here
# silently stopped wrapping anything for 3 hours. Skip only our own files and
# names that look like an in-progress download or a shared library (an ELF
# .so/.node replaced by a bash script would break dlopen).
is_candidate() {
  case $1 in
    .*|*.sleev-real|*.tmp*|*.part*|*.download*|*.zst|*.lock|*~) return 1 ;;
    *.so|*.so.*|*.node) return 1 ;;
  esac
  [[ -f $1 ]]
}
# The naming schemes seen so far. Anything else still gets wrapped, after a
# short settle wait in case it is a temp file about to be renamed.
is_known_name() { [[ $1 =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9a-f]+)?$ ]]; }
is_our_shim() { [[ $(head -c2 -- "$1") == '#!' ]] && grep -q 'Sleev shim' -- "$1" 2>/dev/null; }

write_shim() { printf '%s\n' "$SHIM_TEXT" > "$1"; chmod +x "$1"; }

# 1. Remove dangling shims: a shim whose .sleev-real was deleted by an app update
#    would fail to exec, breaking sessions outright. Deleting it lets the app
#    re-download that version cleanly if it ever needs it.
#    Also remove originals whose name is gone: when the app prunes an old
#    version it deletes the name but not our hard link, leaving ~250MB behind.
#    Running sessions keep their open copy, so this is safe.
remove_stale() {
  local v r
  for v in *; do
    is_candidate "$v" || continue
    if is_our_shim "$v" && [[ ! -f $v.sleev-real ]]; then
      rm -f -- "$v"
      echo "$(date -Is) removed dangling shim $v (original deleted by app update)"
    fi
  done
  for r in *.sleev-real; do
    [[ -e ${r%.sleev-real} ]] && continue
    rm -f -- "$r"
    echo "$(date -Is) removed orphaned $r (version pruned by the app)"
  done
  # Temp shims left by an interrupted run; none are live while we hold the lock.
  rm -f -- .*.sleev-tmp
}

# 2. Wrap any unwrapped version binary.
#    Speed matters: on an update the app respawns its open sessions on the new
#    version ~2.5s after the binary lands, and a session that starts before the
#    shim is in place bypasses Sleev for its whole life. The old 2s-poll size
#    wait took ~4s and lost that race on 2026-10-05 and 2026-10-06.
wrap_one() {
  local v=$1 note="" prev cur tmp
  if ! is_known_name "$v"; then
    # Unfamiliar name: it must already be executable (temp files from an
    # installer are usually 0600 until just before the final rename) and
    # untouched for 2s (max ~20s). Wrapping a temp file the app then renames
    # would leave a shim with no .sleev-real, so sessions would fail to start.
    [[ -x $v ]] || return 0
    for _ in $(seq 1 100); do
      (( $(date +%s) - $(stat -c %Y -- "$v" 2>/dev/null || echo 0) >= 2 )) && break
      sleep 0.2
    done
    note=" (unfamiliar name: the app may have changed its naming again)"
  fi

  # The server installs by rename, so the file should arrive complete; a quick
  # size check still guards against an in-place write. Polls every 0.2s until
  # two consecutive sizes match (max ~60s).
  prev=-1
  for _ in $(seq 1 300); do
    cur=$(stat -c %s -- "$v" 2>/dev/null) || break
    [[ $cur == "$prev" ]] && break
    prev=$cur
    sleep 0.2
  done
  [[ -f $v ]] || return 0
  head -c4 -- "$v" | grep -q ELF || return 0   # replaced while we waited

  # Swap without a gap: hard-link the binary to .sleev-real, then rename the
  # shim over $v. $v always names something runnable, so a session spawned
  # mid-swap gets the binary or the shim, never "file not found".
  ln -f -- "$v" "$v.sleev-real" || return 0
  tmp=".$v.sleev-tmp"
  if ! { write_shim "$tmp" && mv -f -- "$tmp" "$v"; }; then
    rm -f -- "$tmp"
    return 0
  fi
  echo "$(date -Is) wrapped $v$note"
}

# Known names first, so a slow unfamiliar file can't hold up a real update.
wrap_new() {
  local v
  for v in *; do
    is_candidate "$v" && is_known_name "$v" || continue
    head -c4 -- "$v" | grep -q ELF && wrap_one "$v"
  done
  for v in *; do
    is_candidate "$v" && ! is_known_name "$v" || continue
    head -c4 -- "$v" | grep -q ELF && wrap_one "$v"
  done
}

# 3. Refresh shims written by an older version of this script, so changes to
#    SHIM_TEXT reach versions that are already wrapped.
refresh_shims() {
  local v tmp
  for v in *; do
    is_candidate "$v" || continue
    [[ -f $v.sleev-real ]] || continue
    is_our_shim "$v" || continue
    if [[ $(cat -- "$v") != "$SHIM_TEXT" ]]; then
      # Replace by rename, never rewrite in place: a session starting mid-write
      # would exec a half-written file, and a running shim (bash reads scripts
      # as it goes) would read the new bytes at its old offset.
      tmp=".$v.sleev-tmp"
      if ! { write_shim "$tmp" && mv -f -- "$tmp" "$v"; }; then
        rm -f -- "$tmp"
        continue
      fi
      echo "$(date -Is) refreshed shim $v"
    fi
  done
}

# Repeat while the folder keeps changing. systemd doesn't queue a second run
# for events that arrive while this one is busy (say, in a settle wait), so a
# binary that lands mid-run would otherwise wait for the 45s timer.
for _ in 1 2 3 4 5; do
  before=$(ls -A)
  remove_stale
  wrap_new
  refresh_shims
  [[ $(ls -A) == "$before" ]] && break
done
