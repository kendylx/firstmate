#!/usr/bin/env bash
# Shared Windows-native process-table fallback.
#
# ONE owner of "what does the real process table say" for every shell walk
# that cannot get an answer from Cygwin's ps: session-lock harness ancestry
# (bin/fm-session-lock-lib.sh), harness detection (bin/fm-harness.sh), the
# sessionstart nudge's lock-owner silence check (bin/fm-sessionstart-nudge.sh),
# and the drain caller's legitimacy walk (bin/fm-branch-outcome.sh).
#
# Why one owner: Git Bash/MSYS ships a legacy Cygwin ps (verified:
# `ps (cygwin) 3.6.10`) whose -p filter accepts none of the -o custom-format
# fields those walks depend on, and neither that ps nor /proc can resolve a
# process's real parent once the walk reaches a non-Cygwin ancestor (the
# harness itself, a native Windows executable): Cygwin has no record of a
# parent it did not itself fork, so it reports ppid=1 and the walk can never
# leave the POSIX subsystem. Verified live: `ps -o comm= -p $$` errors
# immediately ("unknown option -- o"), and even with that fixed, /proc/$$/ppid
# and every native ancestor above it (the harness's own real parent) are both
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
# cost, because callers only reach this fallback after their own ps evidence
# has already failed; a non-Windows host without PowerShell fails the
# capability probe and pays nothing either.
#
# This file is sourced by scripts and has no side effects on source.

_FM_WIN32_TABLE=
_FM_WIN32_TABLE_LOADED=0
_FM_WIN32_UNAVAILABLE=0

# True when a PowerShell binary capable of answering Win32_Process is on PATH.
# Sticky: a failed probe or load is remembered so a missing or broken
# PowerShell is asked at most once per process.
fm_win32_proc_available() {
  [ "$_FM_WIN32_UNAVAILABLE" -eq 0 ] || return 1
  command -v powershell.exe >/dev/null 2>&1 && return 0
  command -v powershell >/dev/null 2>&1 && return 0
  _FM_WIN32_UNAVAILABLE=1
  return 1
}

# Load and cache the whole Win32 process table (pid, ppid, name, execpath,
# cmdline; tab-separated, CRLF stripped) in one PowerShell call.
fm_win32_proc_load() {
  [ "$_FM_WIN32_TABLE_LOADED" -eq 1 ] && return 0
  fm_win32_proc_available || return 1
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
fm_win32_proc_fields() {  # <pid>
  local pid=$1 found_pid found_ppid found_name found_path found_cmd comm
  fm_win32_proc_load || return 1
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

# Print "<pid>\t<effective-ppid>" for every row of the cached table, the shape
# a top-down descent walk (matching children against an eligible leaf set)
# consumes instead of climbing hop by hop. A Cygwin-tracked row's raw
# ParentProcessId names a fork stub that has already exited - the same gap
# fm_win32_ancestor_winpids bridges upward - so each such row's parent is
# resolved through Cygwin's own ps -l table (its cygwin ppid translated to
# that row's WINPID). Rows Cygwin does not track keep their recorded Win32
# parent: a native child spawned by a native parent is created directly, so
# that edge is real.
fm_win32_proc_pairs() {
  local cygwin_rows
  fm_win32_proc_load || return 1
  # cygpid cygppid winpid per Cygwin-tracked process; a broken ps leaves this
  # empty and every row keeps its recorded parent, identical to the old shape.
  cygwin_rows=$(ps -l 2>/dev/null | awk 'NR>1 && $4 ~ /^[0-9]+$/ {print $1, $2, $4}')
  awk -v cyg="$cygwin_rows" '
    BEGIN {
      n = split(cyg, rows, "\n")
      for (i = 1; i <= n; i++) {
        split(rows[i], f, " ")
        cygppid[f[1]] = f[2]; winof[f[1]] = f[3]; cygof[f[3]] = f[1]
      }
      FS = "\t"
    }
    {
      ppid = $2
      if (($1 in cygof) && (cygof[$1] in cygppid) && (cygppid[cygof[$1]] in winof))
        ppid = winof[cygppid[cygof[$1]]]
      printf "%s\t%s\n", $1, ppid
    }
  ' <<EOF
$_FM_WIN32_TABLE
EOF
}

# True when Win32 pid $1 is present in the real process table - the
# Windows-side answer for pids kill -0 cannot address at all.
fm_win32_pid_alive() {  # <pid>
  local pid=$1
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  fm_win32_proc_fields "$pid" >/dev/null
}

# Print this process's own Win32 pid (WINPID), the id every Win32_Process row
# is keyed by - distinct from $$, which is Cygwin's own internal pid. `ps -l`
# is the one Cygwin ps flag combination (verified) that still reports it
# without the unsupported -o fields.
fm_win32_proc_own_pid() {
  ps -l -p "$$" 2>/dev/null | awk 'NR==2 {print $4}'
}

# Print the ancestor Win32 pids of <pid> (or this process), nearest first, one
# per line - the seed every upward ancestry walk on this platform consumes.
#
# The list bridges the two pid spaces a walk crosses on Git Bash/MSYS. The
# Cygwin section follows `ps -l`'s Cygwin-space ppid column and translates
# each hop to its WINPID; it must come first because a Cygwin child's real
# Win32 ParentProcessId names a fork STUB that has already exited, so a
# pure-Win32 climb dead-ends one hop up (verified: fields lookups on the stub
# miss the whole table). Once the Cygwin chain stops resolving - a native
# Windows parent, or Cygwin's ppid=1 dead end - the walk continues from the
# last known WINPID through Win32_Process ParentProcessId links, which are
# creation-time records that hold for natively spawned children.
# A <pid> `ps -l` cannot read is taken as a Win32 pid already - the shape
# descent walks hand over when their own pairs listing came from the table.
fm_win32_ancestor_winpids() {  # [<pid>]
  local cygpid=${1:-$$} winpid= ppid= line pid hops=0
  while [ "$hops" -lt 16 ]; do
    line=$(ps -l -p "$cygpid" 2>/dev/null | awk 'NR==2 {print $2, $4}') || break
    set -- $line
    ppid=${1:-} winpid=${2:-}
    case "$winpid" in ''|*[!0-9]*) break ;; esac
    printf '%s\n' "$winpid"
    case "$ppid" in ''|*[!0-9]*) break ;; esac
    [ "$ppid" -gt 1 ] || break
    [ "$ppid" != "$cygpid" ] || break
    cygpid=$ppid
    hops=$((hops + 1))
  done
  case "$winpid" in ''|*[!0-9]*)
    winpid=$cygpid
    printf '%s\n' "$winpid"
    ;;
  esac
  pid=$winpid
  while [ "$hops" -lt 16 ]; do
    line=$(fm_win32_proc_fields "$pid") || break
    ppid=${line%%$'\t'*}
    case "$ppid" in ''|*[!0-9]*) break ;; esac
    [ "$ppid" != "$pid" ] || break
    printf '%s\n' "$ppid"
    pid=$ppid
    hops=$((hops + 1))
  done
}
