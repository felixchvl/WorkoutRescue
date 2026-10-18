#!/bin/sh
# Runs every automated test that does not need an Apple Watch:
#   1. Swift unit tests of the shipping shared sources (macOS, SwiftPM)
#   2. Receiver API tests (Python unittest)
#   3. End-to-end Swift uploader -> receiver -> verify (fictional data)
# The SwiftPM build directory lives outside the repository (iCloud/Finder xattrs break codesign).
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export WR_SPM_BUILD="${WR_SPM_BUILD:-${TMPDIR:-/tmp}/workoutrescue-spm}"
cd "$ROOT"
echo "== 1/3 swift test"
swift test --scratch-path "$WR_SPM_BUILD" 2>&1 | grep -E "error:|failed|Executed .* tests" | tail -5
echo "== 2/3 receiver unittest"
(cd receiver && python3 -m unittest discover -s tests 2>&1 | tail -3)
echo "== 3/3 end-to-end"
"$ROOT/scripts/e2e.sh"
