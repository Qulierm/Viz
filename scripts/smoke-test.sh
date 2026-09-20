#!/usr/bin/env bash
#
# smoke-test.sh - launch the packaged Viz.app and prove that it actually starts and
# stays alive, then clean the process up again.
#
# The script deliberately avoids `open`, `ps` and `pgrep`: those tools are unavailable
# in restricted environments. The app is launched directly and tracked by PID.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

WINDOW_SECONDS=6
CHECK_INTERVAL=0.5
CHECKS=$((WINDOW_SECONDS * 2))   # 12 checks x 0.5 s

usage() {
  cat <<EOF
Usage: bash scripts/smoke-test.sh [--help]

Launches the packaged app, verifies it is still alive after ${WINDOW_SECONDS} seconds,
checks the log for crash signatures, and terminates the process again.

Environment:
  VIZ_APP    Path to the app bundle (default \$ROOT/build/Viz.app)
EOF
}

app_path() {
  local path="${VIZ_APP:-$ROOT/build/Viz.app}"
  # Accept relative paths by resolving them against the repository root.
  if [[ "$path" != /* ]]; then
    path="$ROOT/$path"
  fi
  printf '%s\n' "$path"
}

APP="$(app_path)"
EXEC="$APP/Contents/MacOS/Viz"
LOG="$ROOT/build/smoke-test.log"

PID=""
CLEANUP_DONE=0
LEFTOVER=0

die() {
  echo "error: $*" >&2
  exit 1
}

# Terminate the launched process and verify it is really gone. A process that survives
# cleanup is a failure, so the outcome is recorded in LEFTOVER.
do_cleanup() {
  CLEANUP_DONE=1
  if [[ -z "$PID" ]]; then
    return 0
  fi

  echo "==> Stopping pid=$PID"
  if kill -0 "$PID" 2>/dev/null; then
    kill -TERM "$PID" 2>/dev/null || true
    # Give the app up to 3 seconds to exit on its own.
    local i
    for ((i = 0; i < 6; i++)); do
      if ! kill -0 "$PID" 2>/dev/null; then
        break
      fi
      sleep 0.5
    done
    if kill -0 "$PID" 2>/dev/null; then
      echo "==> pid=$PID ignored SIGTERM, sending SIGKILL"
      kill -KILL "$PID" 2>/dev/null || true
    fi
  fi

  # Reap the child so a zombie cannot keep `kill -0` succeeding.
  wait "$PID" 2>/dev/null || true

  if kill -0 "$PID" 2>/dev/null; then
    LEFTOVER=1
    echo "error: pid=$PID is still alive after cleanup" >&2
  else
    echo "==> Cleanup complete: pid=$PID no longer exists"
  fi
}

# Always clean up, even when the liveness check fails or the script is interrupted.
finish() {
  local status=$?
  if [[ "$CLEANUP_DONE" != "1" ]]; then
    do_cleanup || true
  fi
  if [[ "$LEFTOVER" == "1" ]]; then
    status=1
  fi
  exit "$status"
}
trap finish EXIT

print_log_tail() {
  echo "--- last 40 lines of $LOG ---"
  tail -40 "$LOG" 2>/dev/null || echo "(no log output)"
  echo "--- end of log ---"
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
[[ -d "$APP" ]] || die "app bundle not found at $APP (build it with: bash scripts/build-app.sh)"
[[ -x "$EXEC" ]] || die "executable not found at $EXEC (build it with: bash scripts/build-app.sh)"

mkdir -p "$(dirname "$LOG")"
: >"$LOG"

# ---------------------------------------------------------------------------
# Launch and check liveness
# ---------------------------------------------------------------------------
echo "==> Launching $EXEC"
nohup "$EXEC" >"$LOG" 2>&1 &
PID=$!
echo "==> pid=$PID, waiting up to ${WINDOW_SECONDS}s"

ALIVE=1
for ((i = 0; i < CHECKS; i++)); do
  if ! kill -0 "$PID" 2>/dev/null; then
    ALIVE=0
    break
  fi
  sleep "$CHECK_INTERVAL"
done

if [[ "$ALIVE" != "1" ]]; then
  print_log_tail
  die "the app exited before surviving ${WINDOW_SECONDS}s"
fi

# A process that lingers while crashing is still a failure.
if grep -Eq 'Fatal error|Segmentation fault|illegal instruction' "$LOG"; then
  print_log_tail
  die "crash signature found in $LOG"
fi

echo "==> App alive after ${WINDOW_SECONDS}s (pid=$PID)"
echo "==> Log: $LOG"
# Optional extra evidence; denied in restricted environments, never required.
ps -p "$PID" -o pid=,comm= 2>/dev/null || true

echo "==> Log tail after ${WINDOW_SECONDS}s"
print_log_tail

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------
do_cleanup
if [[ "$LEFTOVER" == "1" ]]; then
  die "cleanup failed: pid=$PID is still running"
fi

echo "==> Smoke test passed"
