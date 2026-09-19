#!/bin/bash
# Run the macshot unit tests and print a readable summary of any failures.
#
# Usage:
#   scripts/run-tests.sh                        # all tests
#   scripts/run-tests.sh AnnotationTests        # one test class
#   scripts/run-tests.sh AnnotationTests/testX  # one test
set -uo pipefail

cd "$(dirname "$0")/.."

CONFIGURATION="${CONFIGURATION:-Debug}"
RESULT_BUNDLE="${TMPDIR:-/tmp}/macshot-tests-$$.xcresult"
rm -rf "$RESULT_BUNDLE"

ARGS=(
  -scheme macshotTests
  -configuration "$CONFIGURATION"
  -destination 'platform=macOS'
  -resultBundlePath "$RESULT_BUNDLE"
)
for filter in "$@"; do
  ARGS+=(-only-testing:"macshotTests/$filter")
done

xcodebuild "${ARGS[@]}" test > "${TMPDIR:-/tmp}/macshot-tests-$$.log" 2>&1
STATUS=$?

LOG="${TMPDIR:-/tmp}/macshot-tests-$$.log"

if grep -q "error:" "$LOG"; then
  echo "=== Build errors ==="
  grep -E "error:" "$LOG" | sort -u | head -40
  rm -rf "$RESULT_BUNDLE"
  exit 1
fi

# Per-test results come from the result bundle; xcodebuild's own output no
# longer includes assertion messages.
xcrun xcresulttool get test-results summary --path "$RESULT_BUNDLE" --format json 2>/dev/null \
  | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
print("=== %s: %d passed, %d failed, %d skipped (%.1fs) ===" % (
    d.get("result", "?"), d.get("passedTests", 0), d.get("failedTests", 0),
    d.get("skippedTests", 0), d.get("totalTestCount", 0) and d.get("duration", 0) or 0))
for t in d.get("testFailures", []):
    print("\nFAIL %s.%s" % (t.get("targetName", ""), t.get("testName", "")))
    msg = (t.get("failureText") or "").strip()
    for line in msg.splitlines():
        print("     " + line)
'

rm -rf "$RESULT_BUNDLE"
exit $STATUS
