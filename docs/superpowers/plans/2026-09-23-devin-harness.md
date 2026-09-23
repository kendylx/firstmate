# Implementation Plan: Devin harness adapter

- **Goal:** Make `devin` (Devin CLI 3000.11.1) a verified firstmate harness end to end: a Devin session acquires the fleet lock and owns normal supervision, and firstmate spawns Devin workers as crewmates/scouts/secondmates on the herdr backend.
- **Architecture:** Standard adapter model — devin interactive REPL inside a herdr pane, steering via fm-send durable inbox. All Windows process-ancestry surfaces gain a shared Win32_Process fallback (capability-detected by trying). Fleet locks gain a `mklink /J` junction fallback when `ln -s` cannot produce real symlinks.
- **Tech stack:** Bash 3.2-compatible shell, PowerShell `Get-CimInstance Win32_Process` (Windows-only fallback), `cmd //c mklink /J` + `cygpath -w`, herdr 0.9.1 backend, devin CLI 3000.11.1.
- **Spec:** `data/devin-harness/design.md` (approved).

## Global constraints

- Never claim unrelated commands as devin: basename match is anchored `^devin$` (case-sensitive — `Devin.exe` Electron excluded); `devin` is NOT added to `FM_HARNESS_NAMES` path-component matching, because devin has no version-named install and a lowercase `devin/` directory in an ordinary script path must not claim the harness (refinement of design §A; safer and recognition-equivalent).
- Windows fallback surfaces are capability-detected by trying, never by `uname` matching; sticky flags cache the verdict once per process (existing `_FM_WIN32_*` convention).
- `ln -s` stays the first lock mechanism; the junction path only runs when symlinks provably don't work; failure falls through to today's identical `return 1`.
- `rmdir`-only cleanup of a copy-mode `ln -s` leftover — never `rm -r` on a path that could be a foreign mid-acquire lock dir.
- `fm_lock_points_to_owner` compares canonicalized directories (junction readlink text form may differ from the owner dir's MSYS string).
- No silent fallback to unverified adapters; no env marker for devin (`AI_AGENT` is an inherited launcher value, documented unreliable); preserve read-only behavior whenever the harness cannot be verified.
- `config/crew-dispatch.json` keeps `"default"` — its harness becomes `"devin"` only after live spawn verification (captain's stated intent).
- No merge without explicit captain authority; PR is the delivery.
- Never put "captain" or direct address in code, comments, tests, commits, or docs.
- TDD: failing test before each production change, then minimal implementation, then green, then commit. Live probes record evidence instead of unit tests.

## Discovered preconditions (must land first)

- **Uncommitted WIP in primary checkout:** `bin/fm-session-lock-lib.sh` (+166 lines) and `tests/fm-session-lock-ancestry.test.sh` (+154) contain a complete Win32 ancestry fallback (`_fm_win32_available/_fm_win32_load_table/_fm_win32_lookup`, sticky flags, fakebin `ps`/`powershell.exe` test harness). Its 3 new unit tests PASS on this host. This is prerequisite infrastructure — land it as the first commit on the feature branch, then refactor it into the shared lib in Task 1.
- **Known host-failure baseline** (POSIX-only fixtures, not regressions): `test_same_session_id_owns_a_recycled_background_chain` fails because `ln -s` copies instead of linking (a "symlinked sidecar" fixture cannot exist); `test_e2e_version_named_session_claims_the_home` fails because the fake `claude` fixture is a bash script — invisible to the Win32 table. Task 10 makes both fixtures Windows-capable.
- `bin/fm-harness.sh` currently prints `unknown` on this host (verified): its `ps -o` ancestry walk is blind. Fixing it is required — `fm-supervision-instructions.sh`, `fm-harness.sh secondmate/resolve_crew` fallback, and the primary verdict all read it.
- Verified live: `kill -0 <devin-winpid>` fails on Git Bash; `fm_harness_pid_alive` (WIP) already covers `.lock` line-1 liveness; `fm_pid_alive` callers only ever pass cygwin pids and stay unchanged.

## File map

| File | Change |
|---|---|
| `bin/fm-win32-proc-lib.sh` | NEW — shared Win32 process table: `fm_win32_proc_available`, `fm_win32_proc_load`, `fm_win32_proc_fields <pid>` → `ppid\tcomm\targs`, `fm_win32_proc_pairs`, `fm_win32_pid_alive` |
| `bin/fm-session-lock-lib.sh` | devin in `FM_HARNESS_RE`; refactor inline `_fm_win32_*` to source shared lib |
| `bin/fm-wake-lib.sh` | `fm_lock_try_create` junction fallback + symlink-capability probe + `rmdir` leftover cleanup; `fm_lock_points_to_owner` canonical compare |
| `bin/fm-harness.sh` | source shared lib; `ps`-first/win32-fallback helpers wired into `harness_process_verdict`, `harness_ancestry`, `ancestry_names_omp`, `harness_ancestry_descent`; `devin)` verdict arm |
| `bin/fm-sessionstart-nudge.sh` | source shared lib; Win32 fallback in the 8-hop lock-owner walk |
| `bin/fm-branch-outcome.sh` | source shared lib; Win32 fallback in the caller-legitimacy ancestry walk |
| `bin/fm-agent-process-lib.sh` | `devin) printf 'agent'` arm (anchored) |
| `bin/fm-control-lib.sh` | devin in `fm_control_harnesses`, `fm_control_harness_family`, `fm_control_interrupt_key/repeat/clear_key/ack_source`, `fm_control_exit_command` (values from Task 6 probe) |
| `bin/fm-supervision-instructions.sh` | `devin` in snippet routing + `repair_line` + `ordinary_wake_line` arms |
| `docs/supervision-protocols/devin.md` | NEW — foreground-checkpoint protocol modeled on `codex.md` |
| `docs/sessionstart-nudge.md` | devin listed with codex TUI as having no tracked session-open channel; spawned workers get the instruction via launch brief |
| `bin/fm-spawn.sh` | devin: header lists, remote-secondmate gate (line ~844), ARG3 case (line ~1703), recipe arm (~1942), `resolve_pi_executable` arm (~2175), `model_flag_for_harness` (~2340), `__DEVINBIN__` substitution (~4633), env-prefix list (~4637); `supervision_model` needs no arm (persistent default, per design) |
| `bin/fm-bootstrap.sh` | static `verified_harnesses` += devin; `effort_ok` adds `or $h == "devin"` to the `false` group (line ~1146) |
| `AGENTS.md` | section 4 verified-harness list (line ~218) += devin (primary/secondmate/crewmate-capable group) |
| `docs/configuration.md` | verified-adapter enumeration (line ~326) += devin |
| `.agents/skills/harness-adapters/SKILL.md` | devin in list + operation matrix |
| `.agents/skills/harness-adapters/references/harness/devin.md` | NEW — verified facts, written after live verification |
| `config/crew-dispatch.json` | `"default": {"harness": "devin"}` — applied only after live spawn verification |
| `tests/fm-session-lock-ancestry.test.sh` | devin match/negative cases + win32-table devin ancestry; Windows-capable fixtures |
| `tests/fm-lock-junction.test.sh` | NEW — junction fallback logic via fakebin `ln`/`cmd`/`cygpath` |
| `tests/fm-win32-proc-lib.test.sh` | NEW — shared lib units via fake `powershell.exe` |
| `tests/fm-devin-harness.test.sh` | NEW — verdict arm, control rows, recipe flags, instruction routing, classify (mirrors `fm-agy-harness.test.sh`) |
| `tests/fm-sessionstart-nudge.test.sh` | Win32-walk case for the silence check |
| `tests/fm-harness-adapter-references.test.sh` | devin reference-doc coverage (auto if table-driven) |
| `tests/fm-secondmate-harness.test.sh` | devin secondmate/remote-gate cases |

## Tasks

### Task 0 — Branch, worktree, land the WIP

**Purpose:** preserve the uncommitted Win32-ancestry work as the feature base without stranding the primary checkout.

**Steps:**
1. `git checkout -b feat/devin-harness` in the primary checkout.
2. Run `bash tests/fm-session-lock-ancestry.test.sh` — expect it to abort at the known symlink-fixture failure; this is the recorded baseline, not a blocker.
3. Commit the WIP: `fix(bin): fall back to the Win32 process table when Cygwin ps cannot see ancestry` (message notes it preserves prior uncommitted session work).
4. `git checkout main` — primary returns to default branch (tangle guard stays green).
5. `git worktree add ../firstmate-devin feat/devin-harness` — all further work runs in the worktree.
6. Verify: `git -C ../firstmate-devin status` clean, branch `feat/devin-harness`; primary `git status` clean on `main` (the untracked `ErrorReports/` and `sa_out2.txt` stay untouched).

### Task 1 — Extract shared `bin/fm-win32-proc-lib.sh`

**Purpose:** the WIP's Win32 machinery serves 3 more consumers (fm-harness, sessionstart-nudge, branch-outcome); extract once, source everywhere.

**Interface:**
```bash
fm_win32_proc_available()      # sticky capability: powershell present
fm_win32_proc_load()           # one-shot whole-table load (cached)
fm_win32_proc_fields() { # <pid> -> "<ppid>\t<comm>\t<args>"
  # comm = ExecutablePath (Name when empty), \ -> /, trailing .exe dropped
}
fm_win32_proc_pairs()          # -> "<pid>\t<ppid>" lines for descent walks
fm_win32_pid_alive() { # <pid> -> table membership after load
}
```

**TDD:**
1. Write `tests/fm-win32-proc-lib.test.sh`: fake `powershell.exe` on PATH printing a canned table; assert fields lookup returns `ppid/comm/args`, `.exe` stripped, `\\`→`/`, pairs lists, alive verdicts, sticky unavailable when powershell absent, one-load caching (marker file counts calls).
2. Run — fails (file absent).
3. Create lib (move WIP bodies, renamed, header documenting capability-by-trying); refactor `fm-session-lock-lib.sh` to `. "$SCRIPT_DIR/fm-win32-proc-lib.sh"` and call the shared names (delete `_fm_win32_*` inline copies; keep `fm_harness_pid_alive`'s kill-0-first shape).
4. Run both suites — win32 unit tests green; ancestry suite reaches its recorded baseline (same two known host failures, nothing new).
5. Commit `refactor(bin): extract the Win32 process-table fallback into a shared lib`.

### Task 2 — `devin` in session-lock identity

**TDD:**
1. Add cases to `tests/fm-session-lock-ancestry.test.sh` (lib_eval harness):
   - `fm_harness_process_matches "devin" "devin -- brief"` → 0
   - comm `C:/Users/Admin/AppData/Local/devin/cli/bin/devin` (win32-lookup shape) → 0
   - `fm_harness_process_matches "Devin" ...` → 1 (Electron excluded)
   - `devinfoo`, `mydevin`, `node /x/devin-helper` → 1
   - path `/home/u/devin/tool.sh` → 1 (proves the NAMES exclusion)
   - win32-table ancestry: fake `powershell.exe` table `bash→devin.exe→devin.exe` → `fm_harness_ancestry_pids` emits the devin pids; anchor = outermost contiguous devin pid.
2. Run — fails (`devin` unrecognized).
3. `FM_HARNESS_RE='claude|codex|opencode|grok|kimi|^pi$|^pi-signed$|^omp$|^devin$'`; `FM_HARNESS_NAMES` unchanged; comment records the names-exclusion rationale.
4. Run — new cases green, baseline unchanged.
5. Commit `feat(bin): recognize devin as a session-lock harness`.

### Task 3 — Junction fallback in `fm-wake-lib.sh`

**Interface changes:**
```bash
_FM_LOCK_SYMLINK_CAPABLE=   # '' unknown, 0 capable, 1 incapable (sticky)
_FM_LOCK_JUNCTION_UNAVAILABLE=0

fm_lock_symlink_capable()    # probe once: ln -s on a mktemp dir + [ -L ]
fm_lock_junction_create() {  # <lockdir> <ownerdir>
  # cygpath -w both sides; cmd //c mklink /J; refuses when tools absent
}
```

`fm_lock_try_create` restructures to: prepare owner → `linked=0` → if symlink-capable, try `ln -s`+verify (else-arm unchanged behavior) → else/stray-cleaned + `rmdir` leftover + junction attempt + verify → claim path shared.

`fm_lock_points_to_owner` gains canonical fallback: `[ "$actual" = "$ownerdir" ]` fast path, else `cd`/`pwd -P` compare both dirs.

**TDD:**
1. Write `tests/fm-lock-junction.test.sh`:
   - fakebin `ln` that copies instead of linking (simulates this host); fake `cmd` implementing `mklink /J` as real `ln -s`; fake `cygpath` echoing input → `fm_lock_try_create` acquires, `fm_lock_points_to_owner` true, release removes the link without touching owner contents.
   - `cmd` absent (base-path-sans) → identical `return 1` failure path as today.
   - foreign non-empty dir at `$lockdir` survives the `rmdir` cleanup.
   - `ln -s` works → junction never attempted (marker file on fake `cmd`).
   - junction readlink text differing in case → canonical compare still verifies.
2. Run — fails (helpers absent).
3. Implement helpers + restructure + canonical compare.
4. Run — green; `tests/fm-watcher-lock.test.sh` still green.
5. Live spot-check on this host: `fm_lock_try_create` via `bin/fm-lock.sh` now creates a real junction under `state/` (inspect `readlink`).
6. Commit `fix(bin): create lock links through a junction fallback when ln -s cannot symlink`.

### Task 4 — `fm-harness.sh` Win32 ancestry + `devin` verdict

**TDD:**
1. Cases in `tests/fm-devin-harness.test.sh` + win32-fallback cases for the walks:
   - fakebin `ps` erroring on `-o` + fake `powershell.exe` table `bash→devin.exe→devin.exe` → `bin/fm-harness.sh` prints `devin`.
   - `ancestry_names_omp` and `harness_ancestry_descent` get the same fallback (table-driven).
   - comm `devin` → `comm devin`; `Devin`, `devinfoo` → no arm.
   - precedence: a `claude` marker inherited under a devin ancestor does not outrank ancestry.
2. Run — fails.
3. Source `fm-win32-proc-lib.sh`; add `fm_proc_comm/fm_proc_ppid/fm_proc_args/fm_proc_pairs` ps-first helpers; wire into `harness_process_verdict` (comm+args), `ancestry_names_omp`, `harness_ancestry`, `harness_ancestry_descent`; add `devin) echo "comm devin"; return ;;` arm after `agy)` with evidence comment; update usage comment list.
4. Run — green incl. `tests/fm-harness-precedence.test.sh`.
5. Live: `bash bin/fm-harness.sh` in this Devin session prints `devin`.
6. Commit `feat(bin): detect devin and read ancestry from the Win32 table when ps cannot`.

### Task 5 — Win32 fallback in `fm-sessionstart-nudge.sh` + `fm-branch-outcome.sh`

**TDD:**
1. `tests/fm-sessionstart-nudge.test.sh` + branch-outcome's suite: fake-ps-fails + fake `powershell.exe` table; lock-owner pid in the table → nudge stays silent / legitimacy accepted; absent → nudge prints / legitimacy refused.
2. Run — fails.
3. Source the shared lib in both scripts; wrap their `ps -o ppid=` reads with the fallback (nudge's hard-coded 8-hop loop keeps its own bounds).
4. Run — green.
5. Commit `fix(bin): let the nudge silence check and drain legitimacy walk reach Win32 ancestry`.

**Checkpoint:** run `<worktree>/bin/fm-lock.sh` from this session — expect `lock acquired: harness pid <devin-winpid>`; `status` reports held; a second acquire refuses politely.

### Task 6 — Devin REPL fact probe (evidence, no code)

**Purpose:** pin every value the control/spawn tables need before writing them. Drive a real `devin` REPL inside a herdr window on a scratch dir; record results in `data/devin-harness/repl-facts.md`.

**Facts to capture:** `devin -- "<prompt>"` interactive semantics; composer/busy signature text; interrupt key + count + repollution; exit command (`/exit` vs `/quit` vs Ctrl+D); whether `--respect-workspace-trust false` suppresses a fresh-dir trust dialog interactively (else locate devin's trust store for a pre-registration script); `--permission-mode dangerous` behavior; `devin list` output shape + session-id location (sessions.db) for resume; hooks/settings surface under `~/.config/devin/` and `%APPDATA%\devin\cli\`; multi-line typed input acceptance (fm-send steering path); pane busy-age fallback feasibility.

**Gate:** if the REPL cannot run acceptably in a herdr pane → stop, report to captain, re-open design (print-turn fallback is out of v1 scope).

### Task 7 — Process classification + control-plane rows

**TDD:**
1. `tests/fm-devin-harness.test.sh` cases: `fm_agent_process_classify_name devin` → `agent`; `Devin`/`devinfoo` → not agent; every `fm_control_*` row returns the probed value; `fm_control_harness_family devin*` stays exact-only (`devin-helper` → no family); `supports_kind devin secondmate` → 0.
2. Run — fails.
3. `fm-agent-process-lib.sh`: `devin) printf 'agent' ;;` arm with anchored comment. `fm-control-lib.sh`: harnesses list, family exact arm, interrupt/repeat/clear/ack/exit rows per Task 6 evidence; no wiring/token arms (devin installs no firstmate wiring in v1).
4. Run — green.
5. Commit `feat(bin): classify and control devin as a verified adapter`.

### Task 8 — Supervision protocol + instructions + nudge doc

**TDD:**
1. Cases: `fm-supervision-instructions.sh --harness devin` renders `devin.md` (not `unknown.md`); `--repair-line` and ordinary-wake paths print the devin checkpoint wording; `docs/sessionstart-nudge.md` diff shows devin's channel status.
2. Run — fails.
3. Write `docs/supervision-protocols/devin.md` (codex.md shape, minus the PreToolUse seatbelt); add `devin` to the snippet case and both line functions (codex-mirroring wording); update `docs/sessionstart-nudge.md` — devin joins codex TUI in the "no tracked session-open channel" group, spawned workers get the instruction via launch brief.
4. Run — green + `tests/fm-harness-adapter-references.test.sh`.
5. Commit `feat(docs): give devin a foreground-checkpoint supervision protocol`.

### Task 9 — Spawn adapter + bootstrap validator

**TDD:**
1. `tests/fm-devin-harness.test.sh` recipe cases: resolved `devin` arm emits marker-unsets, `__DEVINBIN__`, `--permission-mode dangerous`, `--respect-workspace-trust false`, `__MODELFLAG__`, `--` prompt boundary, `__OPINPUT__` brief encoding; `model_flag_for_harness devin X` → `--model 'X' `; effort emits nothing; remote-gate and ARG3 case accept `devin`; `crew_dispatch_validate` accepts `"devin"` and rejects `devin`+effort.
2. Run — fails.
3. Implement all `fm-spawn.sh` arms + `fm-bootstrap.sh` list/effort arm; secondmate refusal lists stay devin-free (primary-capable); readiness gate uses Task 6's busy signature (generic path if harness-agnostic, devin arm otherwise); trust handling per Task 6 finding (flag alone, or a `bin/fm-devin-trust.sh` + post-launch answer arm mirroring agy).
4. Run — green + `tests/fm-secondmate-harness.test.sh`, `tests/fm-control.test.sh`.
5. Commit `feat(bin): spawn devin workers through the standard adapter surface`.

### Task 10 — Windows-capable test fixtures (unblock the red baseline)

1. `test_same_session_id_owns_a_recycled_background_chain`: probe `ln -s` capability once; when incapable, skip only the symlinked-sidecar sub-assertion (rest of the test still runs).
2. e2e ancestry fixtures: on Windows-capable path, ship the fake harness as a renamed binary — copy `bash.exe` → `fakebin/claude.exe` (Win32 table sees `claude.exe` → `comm claude`); POSIX keeps the script form. Selection by `fm_win32_proc_available` probe, never `uname`.
3. Run the full ancestry suite — fully green on this host for the first time.
4. Commit `test: make session-lock e2e fixtures work where ln -s and POSIX process names are unavailable`.

### Task 11 — Live verification ladder (evidence)

1. `<worktree>/bin/fm-lock.sh` in this session → `lock acquired`; second session refuses politely; `status` names the devin pid.
2. `<worktree>/bin/fm-session-start.sh` → full locked digest (drain, fleet sync, checks execute); supervision block renders `devin.md`.
3. `fm-spawn.sh` a scout on `--harness devin --backend herdr` → brief delivered; `fm-send` steer lands in the REPL; turn-end detected (hook if found in Task 6, else busy-age); `fm-crew-state.sh` reports real state; `fm-teardown.sh` clean.
4. `fm-bootstrap.sh` re-run → after `config/crew-dispatch.json` flips to `"devin"`, `CREW_DISPATCH` line is silent.
5. Record outputs in `data/devin-harness/live-evidence.md`.

### Task 12 — Docs, config, review, PR

1. `AGENTS.md` §218 + `docs/configuration.md` §326 lists; `harness-adapters` SKILL.md + `references/harness/devin.md` written FROM the Task 6/11 evidence (never from guesses); `config/crew-dispatch.json` `"default"→"devin"`.
2. `requesting-code-review` skill → fix findings → `verification-before-completion` with real command output.
3. Push `feat/devin-harness`, open PR via `gh` (template: summary + test plan + environment disclosure); report to captain — merge stays the captain's call.

## Task dependencies

T0 → T1 → T2 → T3 → T4 → T5 → (checkpoint) → T6 → T7 → T8 → T9 → T10 → T11 → T12. T6 is a hard gate for T7/T9 values; T10 may run earlier whenever convenient once its fixtures exist.
