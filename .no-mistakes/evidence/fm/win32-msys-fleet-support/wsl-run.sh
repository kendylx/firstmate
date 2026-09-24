#!/usr/bin/env bash
# Runs only test_lsof_absent_reaps_tmux_process_group from each tree on Linux (WSL Ubuntu, lsof installed).
EV=/mnt/c/Users/Admin/.no-mistakes/evidence/01M39KACBBRDMZ0AT8YMPFKA00
for v in prefix fixed; do
  d=/tmp/fm-nm-lsof-$v; rm -rf "$d"; mkdir -p "$d"; python3 -c "import tarfile,sys; tarfile.open(sys.argv[1]).extractall(sys.argv[2])" "$EV/$v.tar" "$d"
  n=$(grep -n "^test_local_only_fork_remote_allows$" "$d/tests/fm-teardown.test.sh" | cut -d: -f1); head -n $((n-1)) "$d/tests/fm-teardown.test.sh" > "$d/tests/only-lsof-absent.test.sh"
  echo test_lsof_absent_reaps_tmux_process_group >> "$d/tests/only-lsof-absent.test.sh"
  chmod +x "$d/tests/only-lsof-absent.test.sh"
  echo "===== $v tree ($(uname -sr), lsof=$(command -v lsof)) ====="
  ( cd "$d" && TMPDIR=/tmp bash tests/only-lsof-absent.test.sh ); echo "exit=$?"
done
