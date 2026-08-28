#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

test_tmp=$(mktemp -d)
restart_pid_one=""
restart_pid_two=""

cleanup() {
  [[ -n $restart_pid_one ]] && kill "$restart_pid_one" 2>/dev/null || true
  [[ -n $restart_pid_two ]] && kill "$restart_pid_two" 2>/dev/null || true
  rm -rf "$test_tmp"
}
trap cleanup EXIT

wrapper_root="$test_tmp/wrapper-root"
wrapper_bin="$test_tmp/wrapper-bin"
mkdir -p "$wrapper_root/shell" "$wrapper_bin"
touch "$wrapper_root/shell/shell.qml"

cat >"$wrapper_bin/qs" <<'SH'
#!/bin/bash

[[ -n ${MAGIKOS_TEST_QS_ARGS:-} ]] && printf '%s\n' "$*" >"$MAGIKOS_TEST_QS_ARGS"

if [[ ${MAGIKOS_TEST_QS_HANG:-0} == 1 ]]; then
  sleep 5
elif [[ ${MAGIKOS_TEST_QS_STARTING:-0} == 1 ]]; then
  printf 'Not ready to accept queries yet.\n'
else
  printf 'ok\n'
fi
SH
chmod +x "$wrapper_bin/qs"

wrapper_error=$(PATH="$wrapper_bin:$PATH" \
  MAGIKOS_PATH="$wrapper_root" \
  MAGIKOS_SHELL_IPC_TIMEOUT=0.1s \
  MAGIKOS_TEST_QS_HANG=1 \
  "$ROOT/bin/magikos-shell" shell ping 2>&1) && fail "hung shell IPC returns a failure"
[[ $wrapper_error == "magikos-shell is not responding" ]] || fail "hung shell IPC reports that the shell is unresponsive" "$wrapper_error"
pass "shell IPC calls time out when Quickshell is unresponsive"

# A starting shell answers on stdout and exits 0, so a ping reads it as up.
wrapper_error=$(PATH="$wrapper_bin:$PATH" \
  MAGIKOS_PATH="$wrapper_root" \
  MAGIKOS_TEST_QS_STARTING=1 \
  "$ROOT/bin/magikos-shell" shell ping 2>&1) && fail "a starting shell answers IPC calls with a failure"
[[ $wrapper_error == "magikos-shell is not ready" ]] || fail "a starting shell reports that it is not ready" "$wrapper_error"
pass "shell IPC calls fail while Quickshell is still starting"

PATH="$wrapper_bin:$PATH" \
MAGIKOS_PATH="$wrapper_root" \
MAGIKOS_TEST_QS_STARTING=1 \
  "$ROOT/bin/magikos-shell" -q shell ping >/dev/null 2>&1 ||
  fail "quiet best-effort IPC calls tolerate a starting shell"
pass "quiet best-effort IPC calls tolerate a starting shell"

wrapper_args="$test_tmp/wrapper-args"
PATH="$wrapper_bin:$PATH" \
MAGIKOS_PATH="$wrapper_root" \
MAGIKOS_TEST_QS_ARGS="$wrapper_args" \
  "$ROOT/bin/magikos-shell" shell ping >/dev/null

grep -F -- 'ipc -n -p' "$wrapper_args" >/dev/null || fail "shell IPC targets the newest live Quickshell instance"
pass "shell IPC targets the newest live Quickshell instance"

restart_root="$test_tmp/restart-root"
restart_bin="$restart_root/bin"
restart_state="$test_tmp/restart-pids"
restart_procs="$test_tmp/restart-procs"
restart_log="$test_tmp/restart.log"
restart_env_log="$test_tmp/restart-env.log"
restart_race_log="$test_tmp/restart-race.log"
dispatch_log="$test_tmp/dispatch.log"
ipc_log="$test_tmp/ipc.log"
runtime_dir="$test_tmp/runtime"
mkdir -p "$restart_root/shell" "$restart_bin" "$runtime_dir"
touch "$restart_root/shell/shell.qml"
ln -s "$ROOT/bin/magikos-shell" "$restart_bin/magikos-shell"
ln -s "$ROOT/bin/magikos-launch-shell" "$restart_bin/magikos-launch-shell"
ln -s "$ROOT/bin/magikos-cmd-missing" "$restart_bin/magikos-cmd-missing"
# The recovery path checks for any surviving Quickshell before deciding to
# re-lock, and the development session may be running one outside the sandbox.
# The stub mirrors live processes through a file the fake Quickshell maintains.
cat >"$restart_bin/pgrep" <<'SH'
#!/bin/bash

[[ -s $MAGIKOS_TEST_QS_PROCS ]]
SH

cat >"$restart_bin/qs" <<'SH'
#!/bin/bash

printf '%s\n' "$*" >>"$MAGIKOS_TEST_IPC_LOG"

case "$*" in
  *'shell ping')
    [[ $* == *"-p $MAGIKOS_TEST_SESSION_PATH/shell"* ]] &&
      grep -Fx '303' "$MAGIKOS_TEST_QS_STATE" >/dev/null &&
      printf 'ok\n'
    ;;
  *'lock lock')
    touch "$MAGIKOS_TEST_QS_STATE.locked"
    printf 'ok\n'
    ;;
  *'lock status')
    # A lock status answer only exists once a live shell is up: while the stale
    # instances are being killed there is nothing to ask, which is exactly the
    # dead-locker shape the recovery path exists for.
    grep -Fx '303' "$MAGIKOS_TEST_QS_STATE" >/dev/null || exit 1
    if [[ -f $MAGIKOS_TEST_QS_STATE.locked ]]; then
      printf '{"secure": true, "requested": true}\n'
    else
      printf '{"secure": false, "requested": false}\n'
    fi
    ;;
esac
SH

cat >"$restart_bin/quickshell" <<'SH'
#!/bin/bash

printf '%s\n' "$*" >>"$MAGIKOS_TEST_QS_LOG"

case " $* " in
  *' kill -p '*)
    pid=$(head -n 1 "$MAGIKOS_TEST_QS_STATE")
    [[ $pid =~ ^[0-9]+$ ]] || exit 1
    kill "$pid" 2>/dev/null
    # Repo builds answer before the process has fully exited: drop the pid
    # from the live-process list on a delay so the restart script has to
    # wait out survivors itself before launching the replacement.
    awk -v p="$pid" '$0 != p' "$MAGIKOS_TEST_QS_STATE" >"$MAGIKOS_TEST_QS_STATE.next"
    mv "$MAGIKOS_TEST_QS_STATE.next" "$MAGIKOS_TEST_QS_STATE"
    (
      sleep 0.3
      awk -v p="$pid" '$0 != p' "$MAGIKOS_TEST_QS_PROCS" >"$MAGIKOS_TEST_QS_PROCS.next"
      mv "$MAGIKOS_TEST_QS_PROCS.next" "$MAGIKOS_TEST_QS_PROCS"
    ) &
    disown
    ;;
  *' -n -p '*)
    [[ -s $MAGIKOS_TEST_QS_PROCS ]] && printf 'launched over a survivor\n' >"$MAGIKOS_TEST_QS_RACE_LOG"
    printf '%s\n' "${MAGIKOS_TEST_TRANSIENT_ENV-unset}" >"$MAGIKOS_TEST_QS_ENV_LOG"
    printf '303\n' >"$MAGIKOS_TEST_QS_STATE"
    printf '303\n' >"$MAGIKOS_TEST_QS_PROCS"
    ;;
esac
SH

cat >"$restart_bin/swaymsg" <<'SH'
#!/bin/bash

if [[ ${1:-} == "exec" ]]; then
  printf '%s\n' "$*" >>"$MAGIKOS_TEST_DISPATCH_LOG"
  MAGIKOS_PATH="$MAGIKOS_TEST_SESSION_PATH" \
    magikos-launch-shell
fi
SH

# Keep the test hermetic where journald has no usable stream socket.
cat >"$restart_bin/systemd-cat" <<'SH'
#!/bin/bash

while (( $# > 0 )); do
  [[ $1 == "--" ]] && { shift; break; }
  shift
done
exec "$@"
SH

cat >"$restart_bin/systemctl" <<'SH'
#!/bin/bash

if [[ ${1:-} == "--user" && ${2:-} == "show-environment" ]]; then
  printf 'MAGIKOS_PATH=%s\n' "$MAGIKOS_TEST_SESSION_PATH"
elif [[ ${1:-} == "--user" && ${2:-} == "try-restart" ]]; then
  exit 0
else
  exit 1
fi
SH

chmod +x "$restart_bin/qs" "$restart_bin/quickshell" "$restart_bin/swaymsg" "$restart_bin/pgrep" "$restart_bin/systemd-cat" "$restart_bin/systemctl"

sleep 30 &
restart_pid_one=$!
sleep 30 &
restart_pid_two=$!
printf '%s\n%s\n' "$restart_pid_one" "$restart_pid_two" >"$restart_state"
printf '%s\n%s\n' "$restart_pid_one" "$restart_pid_two" >"$restart_procs"

caller_root="$test_tmp/caller-root"
mkdir -p "$caller_root/shell"
touch "$caller_root/shell/shell.qml"

PATH="$restart_bin:$PATH" \
MAGIKOS_PATH="$caller_root" \
XDG_RUNTIME_DIR="$runtime_dir" \
MAGIKOS_TEST_QS_STATE="$restart_state" \
MAGIKOS_TEST_QS_PROCS="$restart_procs" \
MAGIKOS_TEST_QS_RACE_LOG="$restart_race_log" \
MAGIKOS_TEST_QS_LOG="$restart_log" \
MAGIKOS_TEST_QS_ENV_LOG="$restart_env_log" \
MAGIKOS_TEST_DISPATCH_LOG="$dispatch_log" \
MAGIKOS_TEST_IPC_LOG="$ipc_log" \
MAGIKOS_TEST_SESSION_PATH="$restart_root" \
  timeout 5 "$ROOT/bin/magikos-restart-shell"

if kill -0 "$restart_pid_one" 2>/dev/null; then
  fail "restart stops the first matching shell instance"
fi
if kill -0 "$restart_pid_two" 2>/dev/null; then
  fail "restart stops duplicate matching shell instances"
fi
wait "$restart_pid_one" 2>/dev/null || true
wait "$restart_pid_two" 2>/dev/null || true
restart_pid_one=""
restart_pid_two=""
[[ $(<"$restart_state") == 303 ]] || fail "restart leaves exactly one fresh shell instance"
[[ $(grep -c '^-n -p ' "$restart_log") == 1 ]] || fail "restart launches one fresh shell process"
grep -F "kill -p $restart_root/shell --any-display" "$restart_log" >/dev/null || fail "restart stops the shell from the session checkout"
grep -F "exec env MAGIKOS_PATH='$restart_root' magikos-launch-shell" "$dispatch_log" >/dev/null ||
  fail "restart launches the fresh shell from the session checkout through Sway" "$(cat "$dispatch_log")"
grep -F "ipc -n -p $restart_root/shell call -- shell ping" "$ipc_log" >/dev/null || fail "restart checks readiness in the session checkout"
pass "restart replaces duplicate shell instances from the session checkout"
[[ ! -e $restart_race_log ]] || fail "restart launches over a shell that has not fully exited" "$(cat "$restart_race_log")"
pass "restart waits for dying shells before launching the replacement"

: >"$restart_log"
printf '303\n' >"$restart_state"
touch "$restart_state.locked"

locked_error=$(PATH="$restart_bin:$PATH" \
  MAGIKOS_PATH="$restart_root" \
  XDG_RUNTIME_DIR="$runtime_dir" \
  MAGIKOS_TEST_QS_STATE="$restart_state" \
  MAGIKOS_TEST_QS_PROCS="$restart_procs" \
  MAGIKOS_TEST_QS_RACE_LOG="$restart_race_log" \
  MAGIKOS_TEST_QS_LOG="$restart_log" \
  MAGIKOS_TEST_DISPATCH_LOG="$dispatch_log" \
  MAGIKOS_TEST_IPC_LOG="$ipc_log" \
  MAGIKOS_TEST_SESSION_PATH="$restart_root" \
  "$ROOT/bin/magikos-restart-shell" 2>&1) && fail "restart refuses while the shell lock is active"

[[ $locked_error == "Refusing to restart Magikos shell while the session is locked." ]] || fail "locked restart explains why it was refused" "$locked_error"
[[ $(<"$restart_state") == 303 ]] || fail "locked restart preserves the running shell"
[[ ! -s $restart_log ]] || fail "locked restart does not stop or launch Quickshell"
pass "restart preserves the shell while its lock is active"

# A LOCK session without an active locker — dead shell or a crash-handler
# relaunch holding no lock — is the failsafe: restart must proceed,
# re-acquire the session lock, and wait for it to report secure.
sleep 30 &
restart_pid_one=$!
printf '%s\n' "$restart_pid_one" >"$restart_state"
: >"$restart_procs"
rm -f "$restart_state.locked"
: >"$restart_log"
: >"$ipc_log"

PATH="$restart_bin:$PATH" \
  MAGIKOS_PATH="$restart_root" \
  XDG_RUNTIME_DIR="$runtime_dir" \
  MAGIKOS_TEST_QS_STATE="$restart_state" \
  MAGIKOS_TEST_QS_PROCS="$restart_procs" \
  MAGIKOS_TEST_QS_RACE_LOG="$restart_race_log" \
  MAGIKOS_TEST_QS_LOG="$restart_log" \
  MAGIKOS_TEST_QS_ENV_LOG="$restart_env_log" \
  MAGIKOS_TEST_DISPATCH_LOG="$dispatch_log" \
  MAGIKOS_TEST_IPC_LOG="$ipc_log" \
  MAGIKOS_TEST_SESSION_PATH="$restart_root" \
  timeout 5 "$ROOT/bin/magikos-restart-shell" || fail "locked restart recovers when the lock client is dead"

if kill -0 "$restart_pid_one" 2>/dev/null; then
  fail "dead-lock recovery stops the stale shell instance"
fi
wait "$restart_pid_one" 2>/dev/null || true
restart_pid_one=""
[[ $(<"$restart_state") == 303 ]] || fail "dead-lock recovery leaves one fresh shell instance"
grep -F "ipc -n -p $restart_root/shell call -- lock lock" "$ipc_log" >/dev/null || fail "dead-lock recovery re-acquires the session lock"
grep -F "ipc -n -p $restart_root/shell call -- lock status" "$ipc_log" >/dev/null || fail "dead-lock recovery waits for the lock to become secure"
pass "restart recovers a locked session whose lock client died"
