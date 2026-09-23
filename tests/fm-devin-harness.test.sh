#!/usr/bin/env bash
# Behavior tests for the verified Devin CLI harness adapter.
#
# The facts pinned here are the ones a devin release could silently change and
# the ones a wrong guess would make dangerous:
#   1. devin.exe is the Devin CLI; Devin.exe (capital D) is the Electron
#      desktop app, so the comm match is anchored and case-sensitive, and
#      substrings like devinfoo or a devin path component are never claimed.
#   2. devin publishes no trustworthy identity marker - AI_AGENT reaches a
#      devin session as inherited launcher state, so detection is ancestry
#      alone, the same shape agy and muse already use.
#   3. A structural devin ancestor outranks an inherited foreign marker
#      (CLAUDECODE and friends) exactly like every other comm-strength match.
#   4. On Git Bash/MSYS the Cygwin ps cannot see -o fields or native parents,
#      so detection replays the same walk against the Win32_Process table the
#      shared bin/fm-win32-proc-lib.sh owns, and a missing table fails closed.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Inherited markers must not leak into the detection cases below; devin is
# proven by ancestry, never by environment.
unset CLAUDECODE PI_CODING_AGENT FM_PI_HARNESS GROK_AGENT CURSOR_AGENT CURSOR_INVOKED_AS \
  ATLASSIAN_AGENT_TYPE ROVODEV_CLI GEMINI_CLI AGENT FM_OMP_HARNESS AI_AGENT

HARNESS="$ROOT/bin/fm-harness.sh"
TMP_ROOT=$(fm_test_tmproot fm-devin-harness)

# A ps that serves only the comm/args fields a POSIX ancestry hop asks for and
# dies on ppid, so the walk examines exactly the one process the case states.
write_single_proc_ps() {  # <fakebin>
  cat > "$1/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf '%s\n' "${FAKE_PS_COMM:?}"; exit 0 ;;
  *"args="*) printf '%s\n' "${FAKE_PS_ARGS:?}"; exit 0 ;;
esac
exit 1
SH
  chmod +x "$1/ps"
}

# The Git Bash/MSYS failure verified live: ps errors on every -o flag, so the
# POSIX walk finds nothing at all. -l -p still answers WINPID for any pid
# (FM_TEST_OWN_WINPID), which is also the cygwin->win32 translation channel an
# explicit ancestry pid takes.
write_win32_only_ps() {  # <fakebin>
  cat > "$1/ps" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  -l\ -p\ *)
    printf '      PID    PPID    PGID     WINPID   TTY         UID    STIME COMMAND\n'
    printf '   1234       1    1234    %s  ?         1000 00:00:00 bash\n' "${FM_TEST_OWN_WINPID:?}"
    ;;
  *) echo "ps: unknown option" >&2; exit 1 ;;
esac
SH
  chmod +x "$1/ps"
}

write_win32_powershell() {  # <fakebin>
  cat > "$1/powershell.exe" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$FM_TEST_WIN32_TABLE"
SH
  chmod +x "$1/powershell.exe"
}

# bash (own WINPID) -> devin.exe (CLI frontend) -> devin.exe (CLI root) ->
# explorer.exe (non-harness top). The verified real shape of a Devin session.
devin_table() {
  printf '%s\t%s\t%s\t%s\t%s\n' \
    500 600 bash.exe 'C:\Program Files\Git\bin\bash.exe' 'bash.exe -c foo' \
    600 610 devin.exe 'C:\Users\Admin\AppData\Local\devin\cli\bin\devin.exe' 'devin.exe -- serve' \
    610 710 devin.exe 'C:\Users\Admin\AppData\Local\devin\cli\bin\devin.exe' 'devin.exe' \
    710 0 explorer.exe 'C:\Windows\explorer.exe' explorer.exe
}

test_devin_detected_by_native_comm() {
  local fakebin out
  fakebin=$(fm_fakebin "$TMP_ROOT/anc-native")
  write_single_proc_ps "$fakebin"
  out=$(FAKE_PS_COMM=devin FAKE_PS_ARGS='devin -- serve' \
    PATH="$fakebin:$PATH" "$HARNESS")
  [ "$out" = devin ] \
    || fail "a natively-named devin command must be detected by ancestry, got '$out'"
  pass "fm-harness.sh: ancestry detects a natively-named devin command"
}

test_devin_rejects_electron_and_substrings() {
  local fakebin out
  fakebin=$(fm_fakebin "$TMP_ROOT/anc-negatives")
  write_single_proc_ps "$fakebin"

  out=$(FAKE_PS_COMM=Devin FAKE_PS_ARGS='Devin' \
    PATH="$fakebin:$PATH" "$HARNESS")
  [ "$out" != devin ] \
    || fail "the Electron app's Devin.exe must not detect devin, got '$out'"

  for shape in devinfoo mydevin devin-helper; do
    out=$(FAKE_PS_COMM=$shape FAKE_PS_ARGS="$shape --serve" \
      PATH="$fakebin:$PATH" "$HARNESS")
    [ "$out" != devin ] \
      || fail "an unrelated $shape command must not detect devin, got '$out'"
  done

  out=$(FAKE_PS_COMM=bash FAKE_PS_ARGS='bash -c "echo devin --help"' \
    PATH="$fakebin:$PATH" "$HARNESS")
  [ "$out" != devin ] \
    || fail "a shell argument naming devin must not detect devin, got '$out'"
  pass "fm-harness.sh: ancestry rejects the Electron app, substrings, and arg mentions"
}

test_devin_comm_beats_inherited_claude_marker() {
  local fakebin out
  fakebin=$(fm_fakebin "$TMP_ROOT/anc-precedence")
  write_single_proc_ps "$fakebin"
  out=$(FAKE_PS_COMM=devin FAKE_PS_ARGS='devin' \
    CLAUDECODE=1 AI_AGENT=claude-code_agent \
    PATH="$fakebin:$PATH" "$HARNESS")
  [ "$out" = devin ] \
    || fail "a structural devin ancestor must outrank an inherited CLAUDECODE, got '$out'"
  pass "fm-harness.sh: a structural devin ancestor outranks an inherited foreign marker"
}

test_devin_win32_ancestry_detects() {
  local fakebin out
  fakebin=$(fm_fakebin "$TMP_ROOT/anc-win32")
  write_win32_only_ps "$fakebin"
  write_win32_powershell "$fakebin"

  out=$(FM_TEST_OWN_WINPID=500 FM_TEST_WIN32_TABLE="$(devin_table)" \
    PATH="$fakebin:$PATH" "$HARNESS")
  [ "$out" = devin ] \
    || fail "the Win32 fallback did not detect devin as own harness, got '$out'"

  out=$(FM_TEST_OWN_WINPID=500 FM_TEST_WIN32_TABLE="$(devin_table)" \
    PATH="$fakebin:$PATH" "$HARNESS" ancestry)
  [ "$out" = "comm devin" ] \
    || fail "the Win32 ancestry walk printed '$out', expected 'comm devin'"

  # An explicit Cygwin pid is translated through ps -l before the table walk:
  # the stub reports every -l -p as WINPID=500, so asking for pid 9999 only
  # resolves when the translation ran.
  out=$(FM_TEST_OWN_WINPID=500 FM_TEST_WIN32_TABLE="$(devin_table)" \
    PATH="$fakebin:$PATH" "$HARNESS" ancestry 9999)
  [ "$out" = "comm devin" ] \
    || fail "an explicit pid was not translated into the Win32 table walk, got '$out'"
  pass "fm-harness.sh: the Win32 fallback detects devin in own ancestry"
}

test_devin_win32_ancestry_descent() {
  local fakebin out
  fakebin=$(fm_fakebin "$TMP_ROOT/anc-descent")
  write_win32_only_ps "$fakebin"
  write_win32_powershell "$fakebin"

  out=$(FM_TEST_OWN_WINPID=500 FM_TEST_WIN32_TABLE="$(devin_table)" \
    PATH="$fakebin:$PATH" "$HARNESS" ancestry-descent)
  [ "$out" = "comm devin" ] \
    || fail "the Win32 descent walk printed '$out', expected 'comm devin'"
  pass "fm-harness.sh: the Win32 fallback answers ancestry-descent"
}

test_devin_win32_no_table_fails_closed() {
  local fakebin out
  fakebin=$(fm_fakebin "$TMP_ROOT/anc-win32-off")
  write_win32_only_ps "$fakebin"
  cat > "$fakebin/powershell.exe" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$fakebin/powershell.exe"

  out=$(FM_TEST_OWN_WINPID=500 FM_TEST_WIN32_TABLE='' \
    PATH="$fakebin:$PATH" "$HARNESS")
  [ "$out" = unknown ] \
    || fail "a missing Win32 table must fail closed to unknown, got '$out'"
  pass "fm-harness.sh: no Win32 table fails closed to unknown"
}

test_devin_detected_by_native_comm
test_devin_rejects_electron_and_substrings
test_devin_comm_beats_inherited_claude_marker
test_devin_win32_ancestry_detects
test_devin_win32_ancestry_descent
test_devin_win32_no_table_fails_closed
