#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

test_tmp=$(mktemp -d)

cleanup() {
  rm -rf "$test_tmp"
}
trap cleanup EXIT

declared_root="$test_tmp/declared"
live_root="$test_tmp/live"
other_root="$test_tmp/other"
ipc_bin="$test_tmp/bin"
runtime_dir="$test_tmp/runtime"
mkdir -p "$declared_root/shell" "$live_root/shell" "$other_root/shell" "$ipc_bin" "$runtime_dir"
touch "$declared_root/shell/shell.qml"

live_trees="$test_tmp/live-trees"
ipc_log="$test_tmp/ipc.log"

# Fake qs: the declared tree never answers, listed trees do. The IPC log keeps
# every invocation so assertions can see which tree was finally targeted.
cat >"$ipc_bin/qs" <<'SH'
#!/bin/bash

printf '%s\n' "$*" >>"$MAGIKOS_TEST_IPC_LOG"

case " $* " in
  *" list --all"*)
    while IFS= read -r tree; do
      [[ -n $tree ]] || continue
      printf 'Instance abc:\n'
      printf '  Process ID: 123\n'
      printf '  Config path: %s/shell/shell.qml\n' "$tree"
    done <"$MAGIKOS_TEST_LIVE_TREES"
    ;;
  *" -p $MAGIKOS_TEST_DECLARED_TREE/shell "*)
    exit 1
    ;;
  *)
    printf 'ok\n'
    ;;
esac
SH
chmod +x "$ipc_bin/qs"

run_shell_ipc() {
  PATH="$ipc_bin:$PATH" \
  MAGIKOS_PATH="$declared_root" \
  MAGIKOS_SHELL_IPC_TIMEOUT=0.5s \
  XDG_RUNTIME_DIR="$runtime_dir" \
  MAGIKOS_TEST_IPC_LOG="$ipc_log" \
  MAGIKOS_TEST_DECLARED_TREE="$declared_root" \
  MAGIKOS_TEST_LIVE_TREES="$live_trees" \
  env -u WAYLAND_DISPLAY "$ROOT/bin/magikos-shell" "$@"
}

# A stale session MAGIKOS_PATH points at a dead tree while another Magikos
# shell instance is live: the call must be retargeted at the running instance.
: >"$ipc_log"
printf '%s\n' "$live_root" >"$live_trees"
output=$(run_shell_ipc shell ping) || fail "shell IPC falls back to the live instance after drift"
[[ $output == ok ]] || fail "fallback IPC answers from the live instance" "$output"
grep -F "list --all" "$ipc_log" >/dev/null || fail "shell IPC consults live instances when the declared tree is down"
grep -F " -p $live_root/shell call" "$ipc_log" >/dev/null ||
  fail "shell IPC retries against the live instance tree" "$(cat "$ipc_log")"
pass "shell IPC retargets a live instance when the declared tree has none"

# Several instances may be live at once. The packaged install root wins so the
# behavior stays deterministic on machines with more than one checkout.
: >"$ipc_log"
printf '%s\n' "$other_root" "/usr/share/magikos" >"$live_trees"
output=$(run_shell_ipc shell ping) || fail "shell IPC falls back when several instances are live"
grep -F " -p /usr/share/magikos/shell call" "$ipc_log" >/dev/null ||
  fail "shell IPC prefers the packaged install root" "$(cat "$ipc_log")"
pass "shell IPC prefers the packaged install root among live instances"

# No instance anywhere: the drift fallback must preserve the original failure.
: >"$ipc_log"
: >"$live_trees"
error=$(run_shell_ipc shell ping 2>&1) && fail "shell IPC still fails when no instance is live anywhere"
[[ $error == "magikos-shell is not running" ]] || fail "missing shell reports the usual message" "$error"
pass "shell IPC keeps the not-running failure when no live instance exists"

# A hung declared shell is a different failure: bypassing it would silently
# answer commands from another tree while the session shell is wedged.
: >"$ipc_log"
hang_bin="$test_tmp/hang-bin"
mkdir -p "$hang_bin"
cat >"$hang_bin/qs" <<'SH'
#!/bin/bash

case " $* " in
  *" -p "*)
    sleep 5
    ;;
esac
SH
chmod +x "$hang_bin/qs"
error=$(PATH="$hang_bin:$PATH" \
  MAGIKOS_PATH="$declared_root" \
  MAGIKOS_SHELL_IPC_TIMEOUT=0.2s \
  XDG_RUNTIME_DIR="$runtime_dir" \
  timeout 5 "$ROOT/bin/magikos-shell" shell ping 2>&1) && fail "hung declared shell still reports unresponsive"
[[ $error == "magikos-shell is not responding" ]] || fail "hung shell keeps the unresponsive failure" "$error"
pass "shell IPC does not fall back past an unresponsive declared shell"
