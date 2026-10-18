#!/bin/sh
# Runs every automated test that does not need an Apple Watch:
#   1. Swift unit tests of the shipping shared sources (macOS, SwiftPM)
#   2. Receiver API tests (Python unittest)
#   3. End-to-end Swift uploader -> receiver -> verify (fictional data)
# The SwiftPM build directory lives outside the repository (iCloud/Finder xattrs break codesign).
# Exits non-zero as soon as one stage fails.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export WR_SPM_BUILD="${WR_SPM_BUILD:-${TMPDIR:-/tmp}/workoutrescue-spm}"
LOG="$(mktemp)"
trap 'rm -f "$LOG"' EXIT
cd "$ROOT"

echo "== 1/3 swift test"
if swift test --scratch-path "$WR_SPM_BUILD" >"$LOG" 2>&1; then grep -E "Executed [0-9]+ tests" "$LOG" | tail -1
else grep -E "error:|failed" "$LOG" | head -20; echo "swift test FAILED"; exit 1; fi

echo "== 2/3 receiver unittest"
if (cd receiver && python3 -m unittest discover -s tests) >"$LOG" 2>&1; then grep -E "^Ran|^OK" "$LOG"
else grep -E "^FAIL|^ERROR|Error" "$LOG" | head -20; echo "receiver tests FAILED"; exit 1; fi

echo "== 3/3 end-to-end"
"$ROOT/scripts/e2e.sh"
echo "ALL TESTS PASSED"
