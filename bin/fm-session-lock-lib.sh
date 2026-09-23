#!/usr/bin/env bash
# Shared session-lock harness identity.
#
# ONE owner of the "which verified-harness process holds this home's session
# lock, and does the current process run inside that same session?" decision.
# bin/fm-lock.sh uses it to acquire and inspect state/.lock and its
# state/.lock-session sidecar; bin/fm-claude-stop-autoarm.sh uses it to prove a
# Stop hook fires inside the lock-owning primary session before it may arm or
# rewake. Two signals decide ownership, either one sufficient: the recorded pid
# is a member of this process's contiguous harness ancestry, or the trusted
# Claude session id below matches the id recorded beside a live lock. Neither
# signal ever fails open: no id, no sidecar, an untrusted id, or a different
# recorded id leaves the ancestry verdict exactly as it was.
# This file is sourced by scripts and has no side effects on source.

# Cursor process identity is NOT expressible as a command-name pattern and is
# deliberately not added to the tables below: Cursor's installed names are
# cursor-agent and the far-too-generic legacy alias `agent`, and it runs as a
# bundled node script. bin/fm-cursor-lib.sh is the fleet's single owner of that
# decision, so this file delegates to it rather than widening the name match.
# shellcheck source=bin/fm-cursor-lib.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/fm-cursor-lib.sh"

# Known harness command names; extend when a new adapter is verified. omp is
# anchored exactly like pi: its process name is the bare word `omp` (verified,
# omp 18.1.11), and a substring match would claim ompd or comp.
FM_HARNESS_RE='claude|codex|opencode|grok|kimi|^pi$|^pi-signed$|^omp$'

# The same harnesses as exact executable names. Keep in sync with
# FM_HARNESS_RE. Used only for the stricter path evidence below, where the
# loose regex would also match ordinary firstmate paths such as
# bin/fm-claude-stop-autoarm.sh.
FM_HARNESS_NAMES=(claude codex opencode grok kimi pi-signed pi omp)

# Print the exact harness name carried by executable path $1 - its own basename
# or any directory component - or return 1.
#
# This exists because Claude Code's native installer names the per-session
# executable by its version (~/.local/share/claude/versions/2.1.220), so the
# basename identifies nothing while the install path still says claude. Matching
# whole path components only is what keeps that widening safe: an ordinary path
# such as bin/fm-claude-stop-autoarm.sh or ~/.claude/hooks/notify.sh has no
# "claude" component and is correctly not a harness process.
fm_harness_path_name() {  # <path>
  local path=$1 name
  [ -n "$path" ] || return 1
  for name in "${FM_HARNESS_NAMES[@]}"; do
    case "/$path/" in
      */"$name"/*) printf '%s' "$name"; return 0 ;;
    esac
  done
  return 1
}

# True when the process described by command name $1 and full argument string $2
# is a verified harness. Sets FM_HARNESS_IS_CLAUDE for the ancestry walk.
#
# Evidence, in order:
#   1. the basename of the reported command name, against FM_HARNESS_RE.
#   2. an exact harness component in that command path or in argv[0]. Both are
#      needed because the two platforms report different things: macOS reports
#      argv[0] in `ps -o comm=`, while procps on Linux reports the kernel exec
#      name and ignores argv[0] entirely, so a version-named Claude Code binary
#      is identified by its install path on macOS and by argv[0] on Linux.
#   3. a bare interpreter (node, python) running a harness script path.
#   4. Cursor's own structural identity, owned by bin/fm-cursor-lib.sh.
FM_HARNESS_IS_CLAUDE=0
fm_harness_process_matches() {  # <comm> <args>
  local comm=$1 args=$2 base argv0 name
  FM_HARNESS_IS_CLAUDE=0
  base=$(basename -- "$comm")
  if printf '%s' "$base" | grep -qE "$FM_HARNESS_RE"; then
    case "$base" in *claude*) FM_HARNESS_IS_CLAUDE=1 ;; esac
    return 0
  fi
  argv0=${args%% *}
  if name=$(fm_harness_path_name "$comm") || name=$(fm_harness_path_name "$argv0"); then
    case "$name" in claude) FM_HARNESS_IS_CLAUDE=1 ;; esac
    return 0
  fi
  # Bare interpreter (e.g. node): match the harness name in its script path.
  case "$comm" in
    *node*|*python*)
      if printf '%s' "$args" | grep -qE "$FM_HARNESS_RE"; then
        case "$args" in *claude*) FM_HARNESS_IS_CLAUDE=1 ;; esac
        return 0
      fi
      ;;
  esac
  # Cursor: its own owner decides, from Cursor's name or versioned install tree
  # in the command path or argv[0]. Without this a Cursor primary can never
  # locate its own harness in the ancestry, so every session start refuses the
  # fleet lock as read-only and the park can never arm.
  fm_cursor_process_matches "$comm" "$args" "$argv0" && return 0
  return 1
}

# --- Windows-native ancestry fallback -----------------------------------------
# Git Bash/MSYS ships a legacy Cygwin ps (verified: `ps (cygwin) 3.6.10`) whose
# -p filter accepts none of the -o custom-format fields fm_harness_ancestry_pids
# and fm_harness_pid_alive depend on, and neither that ps nor /proc can resolve
# a process's real parent once the walk reaches a non-Cygwin ancestor (the
# harness itself, a native Windows executable): Cygwin has no record of a
# parent it did not itself fork, so it reports ppid=1 and the walk can never
# leave the POSIX subsystem. Verified live: `ps -o comm= -p $$` errors
# immediately ("unknown option -- o"), and even with that fixed, /proc/$$/ppid
# and every native ancestor above it (claude.exe's own real parent) are both
# unreachable through Cygwin's pid table - `ps -p` and `kill -0` refuse a bare
# Win32 pid outright ("No such process") because Cygwin's -p filter only
# matches pids it assigned itself.
#
# When that happens the only source left for the real parent chain is Windows
# itself, queried once per process through Win32_Process via PowerShell - the
# whole process table in one call (~200-400ms, verified), never per hop, so a
# 16-hop climb costs one call rather than sixteen. Capability is detected by
# trying, never by matching uname, matching the same rule fm_pid_identity in
# fm-wake-lib.sh already applies to this exact platform gap: a Windows host
# whose ps genuinely supports -o (a newer MSYS2 procps-ng) never pays this
# cost, because the ordinary walk below already succeeds and this fallback is
# only reached when it does not; a non-Windows host without PowerShell fails
# the capability probe and pays nothing either.
_FM_WIN32_TABLE=
_FM_WIN32_TABLE_LOADED=0
_FM_WIN32_UNAVAILABLE=0

# True when a PowerShell binary capable of answering Win32_Process is on PATH.
# Sticky: a failed probe or load is remembered so a missing or broken
# PowerShell is asked at most once per process.
_fm_win32_available() {
  [ "$_FM_WIN32_UNAVAILABLE" -eq 0 ] || return 1
  command -v powershell.exe >/dev/null 2>&1 && return 0
  command -v powershell >/dev/null 2>&1 && return 0
  _FM_WIN32_UNAVAILABLE=1
  return 1
}

# Load and cache the whole Win32 process table (pid, ppid, name, execpath,
# cmdline; tab-separated, CRLF stripped) in one PowerShell call.
_fm_win32_load_table() {
  [ "$_FM_WIN32_TABLE_LOADED" -eq 1 ] && return 0
  _fm_win32_available || return 1
  local bin=powershell.exe
  command -v powershell.exe >/dev/null 2>&1 || bin=powershell
  _FM_WIN32_TABLE=$("$bin" -NoProfile -NonInteractive -Command \
    'Get-CimInstance Win32_Process | ForEach-Object { "{0}`t{1}`t{2}`t{3}`t{4}" -f $_.ProcessId,$_.ParentProcessId,$_.Name,$_.ExecutablePath,$_.CommandLine }' \
    2>/dev/null | tr -d '\r')
  if [ -z "$_FM_WIN32_TABLE" ]; then
    _FM_WIN32_UNAVAILABLE=1
    return 1
  fi
  _FM_WIN32_TABLE_LOADED=1
  return 0
}

# Print "<ppid>\t<comm>\t<args>" for Win32 pid $1 from the cached table, or
# return 1 when the pid is not present (process gone) or the table could not
# be loaded. comm is ExecutablePath (Name when that is empty) with backslashes
# turned to forward slashes and a trailing .exe dropped, so it lands in
# exactly the shape fm_harness_process_matches already knows how to match -
# including the anchored ^pi$/^omp$ alternatives, which a bare "pi.exe" would
# otherwise miss.
_fm_win32_lookup() {  # <pid>
  local pid=$1 found_pid found_ppid found_name found_path found_cmd comm
  _fm_win32_load_table || return 1
  while IFS=$'\t' read -r found_pid found_ppid found_name found_path found_cmd; do
    [ "$found_pid" = "$pid" ] || continue
    comm=$found_path
    [ -n "$comm" ] || comm=$found_name
    comm=${comm//\\//}
    case "$comm" in *.[Ee][Xx][Ee]) comm=${comm%.*} ;; esac
    printf '%s\t%s\t%s\n' "$found_ppid" "$comm" "${found_cmd//\\//}"
    return 0
  done <<EOF
$_FM_WIN32_TABLE
EOF
  return 1
}

# Print this process's own Win32 pid (WINPID), the id every Win32_Process row
# is keyed by - distinct from $$, which is Cygwin's own internal pid. `ps -l`
# is the one Cygwin ps flag combination (verified) that still reports it
# without the unsupported -o fields.
_fm_win32_own_pid() {
  ps -l -p "$$" 2>/dev/null | awk 'NR==2 {print $4}'
}

# fm_harness_ancestry_pids's algorithm, replayed against the real Win32 parent
# chain instead of Cygwin's ppid=1 dead end. Kept as a literal parallel of that
# function, rather than a shared loop, so each stays readable against the
# process-table shape it actually reads.
_fm_harness_ancestry_pids_win32() {
  local pid ppid comm args extending=0 printed=0 line
  pid=$(_fm_win32_own_pid) || return 1
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do
    line=$(_fm_win32_lookup "$pid") || break
    IFS=$'\t' read -r ppid comm args <<EOF
$line
EOF
    if fm_harness_process_matches "$comm" "$args"; then
      printf '%s\n' "$pid"
      printed=1
      [ "$FM_HARNESS_IS_CLAUDE" -eq 1 ] || break
      extending=1
    elif [ "$extending" -eq 1 ]; then
      break
    fi
    case "$ppid" in ''|*[!0-9]*) break ;; esac
    [ "$ppid" != "$pid" ] || break
    pid=$ppid
  done
  [ "$printed" -eq 1 ]
}

# True when Win32 pid $1 is alive and harness-shaped, read from the cached
# Win32 process table. The Windows-side counterpart of fm_harness_pid_alive,
# used only once its own kill -0/ps -o evidence has already failed.
_fm_win32_pid_alive() {  # <pid>
  local pid=$1 ppid comm args line
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  line=$(_fm_win32_lookup "$pid") || return 1
  IFS=$'\t' read -r ppid comm args <<EOF
$line
EOF
  fm_harness_process_matches "$comm" "$args"
}

# Walk the current process ancestry (up to 16 hops) and print this session's
# contiguous verified-harness ancestry, innermost pid first.
#
# The walk climbs freely until the first harness match, because the caller is
# normally an ordinary shell several levels below its session. After that first
# match it stops at the first non-harness ancestor, so it can never cross a gap
# into an unrelated harness further up the real process tree - for example the
# live session that launched a test as its own subprocess.
#
# For every harness except Claude the innermost match is the session, which is
# where e.g. Pi's shared signed-wrapper ancestry actually holds the lock: a
# "pi-signed" launcher can be the direct parent of the inner "pi" engine pid that
# owns the lock, and the wrapper pid above it is not that owner. Claude Code
# instead runs hooks several levels below the session inside its own nested
# worker chain (hook shell -> claude bg-spare -> claude bg-pty-host -> claude ->
# claude), with no non-harness process between them. Which pid in that run is the
# session cannot be read off the ancestry at all, so the whole contiguous run is
# reported and the callers below decide what they need from it.
fm_harness_ancestry_pids() {
  local pid=$$ comm args extending=0 printed=0
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || break
    args=$(ps -o args= -p "$pid" 2>/dev/null)
    if fm_harness_process_matches "$comm" "$args"; then
      printf '%s\n' "$pid"
      printed=1
      [ "$FM_HARNESS_IS_CLAUDE" -eq 1 ] || break
      extending=1
    elif [ "$extending" -eq 1 ]; then
      break
    fi
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    # Examine the top of the chain before stopping. Inside a PID namespace the
    # harness itself is pid 1, so stopping as soon as the next pid is 1 hides the
    # very process this walk exists to find. A host's real pid 1 (init, systemd,
    # launchd) is not harness-shaped, so fm_harness_process_matches rejects it.
    case "$pid" in '' | *[!0-9]*) break ;; esac
    [ "$pid" -ge 1 ] || break
  done
  [ "$printed" -eq 1 ] && return 0
  _fm_harness_ancestry_pids_win32
}

# Print the outermost pid of this session's contiguous harness run for callers
# that need that ancestry identity. This is not necessarily the pid written to
# the session lock: fm_session_lock_anchor_pid owns that choice and uses a
# trusted Claude session's model-loop pid instead. Every non-Claude harness
# reports a single pid, so this remains its innermost match unchanged.
fm_harness_ancestry_pid() {
  local pids
  pids=$(fm_harness_ancestry_pids) || return 1
  _fm_harness_outermost_pid "$pids"
}

# Print the last (outermost) pid of ancestry list $1, or return 1 when empty.
_fm_harness_outermost_pid() {  # <ancestry-pids>
  local pid outermost=''
  while IFS= read -r pid; do
    [ -n "$pid" ] && outermost=$pid
  done <<EOF
$1
EOF
  [ -n "$outermost" ] || return 1
  printf '%s\n' "$outermost"
}

# True if $1 is a live process that looks like a verified harness. Falls back
# to the Win32 table (see above) only once kill -0 itself has failed: that is
# the exact, and only, evidence Cygwin gives for "this pid is outside what my
# -p filter can address," which is indistinguishable there from "dead" without
# a second source.
fm_harness_pid_alive() {
  local pid=$1 comm args
  if kill -0 "$pid" 2>/dev/null; then
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
    args=$(ps -o args= -p "$pid" 2>/dev/null)
    fm_harness_process_matches "$comm" "$args"
    return $?
  fi
  _fm_win32_pid_alive "$pid"
}

# --- trusted same-session identity -------------------------------------------
# Claude Code hands every hook and tool shell CLAUDE_CODE_SESSION_ID (the
# session's conversation id) and CLAUDE_PID (the pid of the process running the
# model loop). A background session runs that model loop in a transient helper
# bridged to its front-end by a shared daemon, and when that bridge is recycled
# the contiguous claude-named ancestry from a hook to the recorded lock owner
# breaks while the owner pid stays alive, so ancestry alone reads the session's
# own lock as another live session's. The id is the one identity that survives
# the recycling, so it is accepted as a second ownership signal - but only from
# an environment proven to belong to the current Claude run.
#
# Trust gate: CLAUDE_PID must be a Claude-shaped member of this process's
# contiguous harness ancestry. An id merely retained in a helper environment
# fails that membership and is ignored: a hand-started Pi or codex primary under
# a Claude pane still carries the pane's CLAUDE_CODE_SESSION_ID and CLAUDE_PID,
# and must never own a lock with them. Ids are read from the environment only,
# never from ps argv, where prompts and briefs are visible.
#
# A --fork-session successor mints a new id, so it stays a foreign live owner
# until the pre-fork process exits; that is the safe direction and a documented
# non-goal. Two genuinely different live sessions sharing one id is not a
# supported state (Claude refuses to resume a running session under its id).

# Print the Claude session id this process may own with, or return 1. $1 is the
# ancestry list an earlier walk already produced, so a caller that walked once
# need not walk again.
fm_session_lock_trusted_session_id() {  # [<ancestry-pids>]
  local id=${CLAUDE_CODE_SESSION_ID:-} claude_pid=${CLAUDE_PID:-} pids=${1:-} pid comm args
  [ -n "$id" ] || return 1
  case "$id" in *$'\n'*|*$'\r'*) return 1 ;; esac
  case "$claude_pid" in ''|*[!0-9]*) return 1 ;; esac
  if [ -z "$pids" ]; then
    pids=$(fm_harness_ancestry_pids) || return 1
  fi
  while IFS= read -r pid; do
    [ "$pid" = "$claude_pid" ] || continue
    comm=$(ps -o comm= -p "$pid" 2>/dev/null)
    if [ -n "$comm" ]; then
      args=$(ps -o args= -p "$pid" 2>/dev/null)
    else
      # The ancestry walk itself may have resolved this pid through the Win32
      # fallback (a bare Win32 pid Cygwin's -o cannot address at all); re-read
      # it the same way rather than trusting an empty re-verification as proof
      # of nothing.
      local win32_line
      win32_line=$(_fm_win32_lookup "$pid") || return 1
      IFS=$'\t' read -r _ comm args <<EOF
$win32_line
EOF
    fi
    fm_harness_process_matches "$comm" "$args" || return 1
    [ "$FM_HARNESS_IS_CLAUDE" -eq 1 ] || return 1
    printf '%s\n' "$id"
    return 0
  done <<EOF
$pids
EOF
  return 1
}

# Print the session id recorded beside the lock in state dir $1, or return 1.
# bin/fm-lock.sh is the only writer of state/.lock-session; a missing,
# symlinked, unreadable, or empty sidecar, or one whose first line contains a
# newline or carriage return, is simply no recorded id.
fm_session_lock_recorded_session_id() {  # <state>
  local state=$1 recorded
  [ -f "$state/.lock-session" ] && [ ! -L "$state/.lock-session" ] || return 1
  recorded=$(head -n 1 "$state/.lock-session" 2>/dev/null) || return 1
  [ -n "$recorded" ] || return 1
  case "$recorded" in *$'\n'*|*$'\r'*) return 1 ;; esac
  printf '%s\n' "$recorded"
}

# True when the lock in state dir $1 was recorded by this same Claude session:
# the trusted id equals the id recorded beside the lock. No trusted id, no
# sidecar, or a different recorded id is false.
fm_session_lock_same_session() {  # <state> [<ancestry-pids>]
  local state=$1 trusted recorded
  trusted=$(fm_session_lock_trusted_session_id "${2:-}") || return 1
  recorded=$(fm_session_lock_recorded_session_id "$state") || return 1
  [ "$recorded" = "$trusted" ]
}

# Print the pid bin/fm-lock.sh records on lock line 1 for this session. For a
# Claude session with a trusted id that is CLAUDE_PID, the model-loop process:
# never the shared transient daemon and never a front-end that outlives the
# session, so "recorded pid dead" keeps meaning "session gone" instead of
# wedging a home behind a live daemon whose session died. A replaced background
# helper leaves a dead pid that its own session's next hook reclaims, because
# the sidecar still names that session. Every other session records the
# outermost pid of its contiguous run, exactly as before.
fm_session_lock_anchor_pid() {
  local pids
  pids=$(fm_harness_ancestry_pids) || return 1
  if fm_session_lock_trusted_session_id "$pids" >/dev/null; then
    printf '%s\n' "$CLAUDE_PID"
    return 0
  fi
  _fm_harness_outermost_pid "$pids"
}

# True when state dir $1 holds a session lock that this process's session owns:
# the recorded pid is ANY harness ancestor of the current process, or the lock
# was recorded by this same trusted Claude session and its recorded pid is still
# a live harness. Membership is the honest ancestry test, because the lock owner
# sits at an unknown depth in a contiguous Claude run - it is the outermost pid
# when the hook fires inside the session's own nested worker chain, and an inner
# pid when a harness-named daemon parents the session. The same-session path
# requires the recorded pid alive so that a dead one is reclaimed through
# bin/fm-lock.sh's ordinary stale-owner path, which refreshes line 1, rather than
# silently owned with a dead anchor. A missing lock, a malformed lock, a lock
# held by a harness outside this ancestry under another (or no) session id, or
# an ancestry that cannot be resolved all fail closed.
fm_session_lock_owned_by_self() {
  local state=$1 lock_pid pids pid
  lock_pid=$(cat "$state/.lock" 2>/dev/null || true)
  case "$lock_pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  pids=$(fm_harness_ancestry_pids) || return 1
  while IFS= read -r pid; do
    [ "$pid" = "$lock_pid" ] && return 0
  done <<EOF
$pids
EOF
  fm_session_lock_same_session "$state" "$pids" || return 1
  fm_harness_pid_alive "$lock_pid"
}

# True when state dir $1 records a live verified harness outside this process's
# contiguous harness ancestry that was not recorded by this same trusted Claude
# session. Sets FM_SESSION_LOCK_FOREIGN_OWNER_PID for a diagnostic caller.
# Malformed, missing, dead, and ancestry-uncertain locks are not foreign-owner
# evidence.
# shellcheck disable=SC2034 # Output global, read by the sourcing guard caller.
FM_SESSION_LOCK_FOREIGN_OWNER_PID=
fm_session_lock_foreign_owner_live() {
  local state=$1 lock_pid pids pid
  FM_SESSION_LOCK_FOREIGN_OWNER_PID=
  [ -f "$state/.lock" ] && [ ! -L "$state/.lock" ] || return 1
  lock_pid=$(cat "$state/.lock" 2>/dev/null || true)
  case "$lock_pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  fm_harness_pid_alive "$lock_pid" || return 1
  pids=$(fm_harness_ancestry_pids) || return 1
  while IFS= read -r pid; do
    [ "$pid" = "$lock_pid" ] && return 1
  done <<EOF
$pids
EOF
  fm_session_lock_same_session "$state" "$pids" && return 1
  # shellcheck disable=SC2034 # Output global, read by the sourcing guard caller.
  FM_SESSION_LOCK_FOREIGN_OWNER_PID=$lock_pid
  return 0
}
