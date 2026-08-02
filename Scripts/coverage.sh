#!/bin/bash
# Reports line coverage for the AIChatApp target only.
#
# Scoped to the app's own sources deliberately. `xccov` reports every linked target by default,
# so the 25 SPM dependencies would be folded in and the number would describe the ecosystem
# rather than this app — flattering, and useless as a gate.
set -euo pipefail

# DerivedData must live OUTSIDE the project folder. This repo sits in an iCloud-synced
# directory, and iCloud attaches extended attributes to files it manages; codesign rejects the
# resulting bundle with "resource fork, Finder information, or similar detritus not allowed".
DD="${DERIVED_DATA:-/tmp/aichatapp-coverage-dd}"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
THRESHOLD="${COVERAGE_THRESHOLD:-100}"

cd "$PROJECT_DIR"

if [ "${SKIP_TEST_RUN:-0}" != "1" ]; then
  xcodebuild \
    -project AIChatApp.xcodeproj \
    -scheme AIChatApp \
    -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
    -derivedDataPath "$DD" \
    -skipMacroValidation \
    -enableCodeCoverage YES \
    test > /tmp/aichatapp-coverage-build.log 2>&1 || {
      echo "BUILD/TEST FAILED — tail of log:"; tail -30 /tmp/aichatapp-coverage-build.log; exit 1; }
fi

RESULT=$(find "$DD/Logs/Test" -name '*.xcresult' -maxdepth 1 | sort | tail -1)
[ -n "$RESULT" ] || { echo "no .xcresult found under $DD/Logs/Test"; exit 1; }

xcrun xccov view --report --json "$RESULT" > /tmp/aichatapp-coverage.json

python3 - "$THRESHOLD" <<'PY'
import json, sys

threshold = float(sys.argv[1])
report = json.load(open('/tmp/aichatapp-coverage.json'))

target = next((t for t in report['targets'] if t['name'] == 'AIChatApp.app'), None)
if target is None:
    target = next((t for t in report['targets'] if t['name'].startswith('AIChatApp')), None)
if target is None:
    print('AIChatApp target not present in coverage report'); sys.exit(1)

files = sorted(target['files'], key=lambda f: f['lineCoverage'])
covered = sum(f['coveredLines'] for f in files)
total = sum(f['executableLines'] for f in files)
pct = (covered / total * 100) if total else 100.0

print(f"{'FILE':<38} {'COV':>8} {'COVERED/TOTAL':>16}")
print('-' * 66)
for f in files:
    name = f['name']
    fpct = f['lineCoverage'] * 100
    flag = '' if fpct >= 99.995 else '   <-- gap'
    print(f"{name:<38} {fpct:7.2f}% {f['coveredLines']:>7}/{f['executableLines']:<8}{flag}")
print('-' * 66)
print(f"{'TOTAL':<38} {pct:7.2f}% {covered:>7}/{total:<8}")

if pct + 1e-9 < threshold:
    print(f"\nBELOW THRESHOLD: {pct:.2f}% < {threshold:.2f}%")
    sys.exit(1)
print(f"\nAT OR ABOVE THRESHOLD ({threshold:.2f}%)")
PY
