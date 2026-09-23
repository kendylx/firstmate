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
  -l)
    # The lib reads the whole Cygwin table in one `ps -l` inside a command
    # substitution, so $PPID here is that substitution's subshell, not the
    # script pid awk walks from. Print a row per ancestor of the subshell so
    # the caller's own cygpid is covered wherever it sits.
    printf '      PID    PPID    PGID     WINPID   TTY         UID    STIME COMMAND\n'
    cyg=$PPID
    for _ in 1 2 3 4; do
      case "$cyg" in ''|*[!0-9]*) break ;; esac
      printf '   %s       1    %s    %s  ?         1000 00:00:00 bash\n' "$cyg" "$cyg" "${FM_TEST_OWN_WINPID:?}"
      cyg=$(awk '{print $4}' "/proc/$cyg/stat" 2>/dev/null) \
        || cyg=$(/bin/ps -o ppid= -p "$cyg" 2>/dev/null | tr -d ' ')
    done
    # Caller-declared extra Cygwin rows, "<cygpid> <cygppid> <winpid>" one per
    # line, modelling table entries the caller chain does not contain - e.g. an
    # explicit pid argument the walk must translate to a WINPID.
    if [ -n "${FM_TEST_EXTRA_CYG_ROWS:-}" ]; then
      printf '%s\n' "$FM_TEST_EXTRA_CYG_ROWS" | while read -r xpid xppid xwin; do
        printf '   %s       %s    %s    %s  ?         1000 00:00:00 bash\n' "$xpid" "$xppid" "$xpid" "$xwin"
      done
    fi
    ;;
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
  # the stub's table carries cygpid 9999 mapped to WINPID=500, so asking for
  # pid 9999 only resolves when the translation ran.
  out=$(FM_TEST_OWN_WINPID=500 FM_TEST_EXTRA_CYG_ROWS='9999 1 500' FM_TEST_WIN32_TABLE="$(devin_table)" \
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

test_devin_classification_and_control_rows() {
  # shellcheck source=bin/fm-agent-process-lib.sh
  . "$ROOT/bin/fm-agent-process-lib.sh"
  # shellcheck source=bin/fm-control-lib.sh
  . "$ROOT/bin/fm-control-lib.sh"

  # Process-name classification is anchored and case-sensitive, the same shape
  # as agy and omp: devin.exe is the CLI, Devin.exe the Electron app, and no
  # substring or suffix is ever the harness.
  [ "$(fm_agent_process_classify_name devin)" = agent ] \
    || fail "devin must classify as an agent process"
  [ "$(fm_agent_process_classify_name 'C:/Users/Admin/AppData/Local/devin/cli/bin/devin')" = agent ] \
    || fail "a devin install path must classify as an agent process"
  [ "$(fm_agent_process_classify_name Devin)" != agent ] \
    || fail "the Electron desktop app must never classify as the CLI"
  [ "$(fm_agent_process_classify_name devinfoo)" != agent ] \
    || fail "devinfoo must not classify as an agent"
  [ "$(fm_agent_process_classify_name mydevin)" != agent ] \
    || fail "mydevin must not classify as an agent"
  [ "$(fm_agent_process_classify_name devin-helper)" != agent ] \
    || fail "devin-helper must not classify as an agent"

  # Control-plane rows, every value from data/devin-harness/repl-facts.md.
  fm_control_harness_supported devin \
    || fail "devin must be a verified control harness"
  [ "$(fm_control_harness_family devin)" = devin ] \
    || fail "devin must resolve to its own adapter family"
  fm_control_harness_family devin-helper \
    && fail "devin-helper must not be guessed into the devin adapter"
  fm_control_harness_family Devin \
    && fail "Devin must not be guessed into the devin adapter"
  fm_control_harness_family devinfoo \
    && fail "devinfoo must not be guessed into the devin adapter"
  fm_control_harness_supports_kind devin secondmate \
    || fail "devin must support the secondmate kind"
  [ "$(fm_control_interrupt_key devin)" = Escape ] \
    || fail "devin's interrupt key must be Escape"
  [ "$(fm_control_interrupt_repeat devin)" = 2 ] \
    || fail "devin's interrupt must be delivered twice back-to-back"
  [ -z "$(fm_control_interrupt_clear_key devin)" ] \
    || fail "devin's interrupt needs no clear key - no repollution was observed"
  [ "$(fm_control_interrupt_ack_source devin)" = none ] \
    || fail "devin's interrupt ack source must be none"
  [ "$(fm_control_exit_command devin)" = /quit ] \
    || fail "devin's exit command must be /quit"
  pass "devin: process classification and control rows match the probed adapter mechanics"
}

# The recipe and flag helpers live inside bin/fm-spawn.sh's main body, so the
# suite extracts the exact function text rather than duplicating it here.
extract_spawn_fn() {  # <fn-name>
  sed -n "/^$1() {/,/^}/p" "$ROOT/bin/fm-spawn.sh"
}

test_devin_launch_recipe_and_flags() {
  local recipe
  eval "$(extract_spawn_fn shell_quote)"
  eval "$(extract_spawn_fn launch_template)"
  eval "$(extract_spawn_fn model_flag_for_harness)"
  eval "$(extract_spawn_fn effort_flag_for_harness)"

  recipe=$(launch_template devin ship)
  [ -n "$recipe" ] || fail "devin must resolve a launch template"
  assert_contains "$recipe" 'env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT -u FM_PI_HARNESS' \
    "devin launch must clear foreign primary markers"
  assert_contains "$recipe" '__DEVINBIN__' "devin launch must resolve its binary through a placeholder"
  assert_contains "$recipe" '--respect-workspace-trust false' \
    "devin launch must suppress the workspace-trust picker"
  assert_contains "$recipe" '--permission-mode dangerous' \
    "devin launch must request the bypass permission tier"
  assert_contains "$recipe" '__MODELFLAG__' "devin launch must carry the model flag placeholder"
  assert_contains "$recipe" '-- "$(__OPINPUT__ encode launch-brief < __BRIEF__)"' \
    "devin launch must pass the brief after the -- prompt boundary"

  recipe=$(launch_template devin secondmate)
  [ -n "$recipe" ] || fail "devin must resolve a secondmate launch template"
  assert_contains "$recipe" '--permission-mode dangerous' \
    "devin's secondmate launch lost the bypass permission tier"

  [ "$(model_flag_for_harness devin some-model)" = "--model 'some-model' " ] \
    || fail "model_flag_for_harness devin must emit --model '<id> '"
  [ -z "$(effort_flag_for_harness devin high)" ] \
    || fail "devin exposes no effort flag; the axis stays in task metadata only"
  pass "devin: launch recipe carries trust suppression, dangerous mode, and the -- brief boundary"
}

test_devin_spawn_gates_accept() {
  # The bare-adapter positional case (--secondmate <harness>) must name devin,
  # and the remote-secondmate harness gates must accept it on both the parent
  # spawn side and the host-local control side.
  grep -F "'' | claude | codex | opencode | pi | pi-signed | grok | kimi | cursor | gemini | muse | rovo | omp | agy | devin)" \
    "$ROOT/bin/fm-spawn.sh" >/dev/null \
    || fail "fm-spawn.sh's bare secondmate adapter list must accept devin"
  grep -F "claude | codex | opencode | pi | pi-signed | grok | kimi | cursor | devin) ;;" \
    "$ROOT/bin/fm-spawn.sh" >/dev/null \
    || fail "fm-spawn.sh's remote secondmate harness gate must accept devin"
  grep -c 'claude|codex|opencode|pi|pi-signed|grok|kimi|cursor|devin' \
    "$ROOT/bin/fm-remote-secondmate-control.sh" | grep -qx 2 \
    || fail "fm-remote-secondmate-control.sh must accept devin in both its launch and relaunch gates"

  # Behavioral proof for the host-local gate: a seeded secondmate home reaches
  # past the harness check for devin but not for an unverified name.
  local home out
  home="$TMP_ROOT/remote-home"
  mkdir -p "$home/bin" "$home/state" "$home/data"
  printf 'sm-gate\n' > "$home/.fm-secondmate-home"
  : > "$home/AGENTS.md"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-remote-secondmate-control.sh" \
    launch sm-gate spaceship - - herdr 2>&1 || true)
  assert_contains "$out" 'unverified remote secondmate harness' \
    "an unverified name must still be refused by the remote gate"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-remote-secondmate-control.sh" \
    launch sm-gate devin - - herdr 2>&1 || true)
  case "$out" in *'unverified remote secondmate harness'*)
    fail "devin must not be refused as an unverified remote secondmate harness" ;;
  esac
  pass "devin: secondmate, remote-spawn, and remote-control gates all accept the adapter"
}

test_devin_busy_classification() {
  # shellcheck source=bin/fm-busy-lib.sh
  . "$ROOT/bin/fm-busy-lib.sh"
  local state verdict
  state="$TMP_ROOT/busy-state"
  mkdir -p "$state"

  verdict=$(fm_busy_classify tmux t1 devin t1 "$state" \
    "$(printf 'output line\nThinking · 12s (esc twice to interrupt)\n❭ Guide Devin while it works\n')")
  [ "$verdict" = 'busy devin-regex' ] \
    || fail "the probed busy signature must classify busy, got '$verdict'"

  verdict=$(fm_busy_classify tmux t1 devin t1 "$state" \
    "$(printf 'output line\n❭ Ask Devin to build features, fix bugs, or work on your code\n')")
  [ "$verdict" = 'idle devin-regex' ] \
    || fail "the idle composer must classify idle, got '$verdict'"

  verdict=$(fm_busy_classify tmux t1 devin t1 "$state" \
    "$(printf 'unrelated output\n')")
  [ "$verdict" = 'unknown devin-regex' ] \
    || fail "a tail without either signature must classify unknown, got '$verdict'"
  pass "devin: the probed pane signatures classify busy, idle, and unknown"
}

test_devin_detected_by_native_comm
test_devin_rejects_electron_and_substrings
test_devin_comm_beats_inherited_claude_marker
test_devin_win32_ancestry_detects
test_devin_win32_ancestry_descent
test_devin_win32_no_table_fails_closed
test_devin_classification_and_control_rows
test_devin_launch_recipe_and_flags
test_devin_spawn_gates_accept
test_devin_busy_classification
