#!/bin/sh
# End-to-end test with fictional data only: the shipping Swift uploader (built for macOS by
# SwiftPM) sends demo workouts to a real receiver/server.py on loopback, then the stored files
# are re-read, compared with the source, and checked by receiver/verify.py.
# Touches no device and no real Health data. Temporary directory removed at the end.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
PORT="${WR_E2E_PORT:-18787}"
TOKEN="$(python3 "$ROOT/receiver/scripts/gen_token.py")"
cleanup() { [ -n "${PID:-}" ] && kill "$PID" 2>/dev/null || true; rm -rf "$WORK"; }
trap cleanup EXIT

WR_TOKEN="$TOKEN" python3 "$ROOT/receiver/server.py" --host 127.0.0.1 --port "$PORT" --export-dir "$WORK/exports" 2>"$WORK/server.log" &
PID=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do curl -sf "http://127.0.0.1:$PORT/health" >/dev/null 2>&1 && break; sleep 0.3; done

cd "$ROOT"
WR_E2E_URL="http://127.0.0.1:$PORT" WR_E2E_TOKEN="$TOKEN" WR_E2E_EXPORT_DIR="$WORK/exports" \
  swift test --scratch-path "${WR_SPM_BUILD:-${TMPDIR:-/tmp}/workoutrescue-spm}" --filter EndToEndTests 2>&1 | grep -E "Test Case|error|Executed" || true
echo "--- receiver/verify.py"
python3 "$ROOT/receiver/verify.py" "$WORK/exports"
STATUS=$?
echo "--- receiver log (errors/warnings)"
grep -E "WARNING|ERROR" "$WORK/server.log" || echo "(none)"
exit $STATUS
