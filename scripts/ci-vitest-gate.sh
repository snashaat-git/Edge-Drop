#!/usr/bin/env bash
# Run the unit suite and fail only on regressions.
#
# Four upstream tests exercise Windows/Store-only code paths (storePaths ×2,
# storePackaging, trayTheme) and cannot pass on Linux. They are the port's
# baseline, not a reason to ignore the suite: this gate fails when the failure
# count grows past the baseline or the passing count drops, so a real regression
# still breaks the build.
#
#   scripts/ci-vitest-gate.sh [baseline-failures] [minimum-passing]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BASELINE_FAILURES="${1:-4}"
MIN_PASSED="${2:-900}"
LOG="${LOG:-/tmp/vitest-ci.log}"

cd "$ROOT"

# CI sets CI=true, which makes the reporter colourise even with stdout redirected
# to a file; those escape codes break any parsing of the summary line.
strip_ansi() { sed -E $'s/\x1b\\[[0-9;]*[A-Za-z]//g'; }

set +e
# --retry=1 absorbs one timing-sensitive upstream test (the mocked release fetch
# runs on a 100ms fast-check clock and fails under load); a real regression fails
# both attempts.
NO_COLOR=1 FORCE_COLOR=0 npx vitest run --reporter=dot --retry=1 2>&1 | strip_ansi >"$LOG"
VITEST_EXIT=${PIPESTATUS[0]}
set -e

SUMMARY="$(grep -E 'Tests +[0-9]+ (failed|passed)' "$LOG" | tail -1 || true)"
if [ -z "$SUMMARY" ]; then
  echo "vitest produced no summary (exit $VITEST_EXIT); last 40 lines:" >&2
  tail -40 "$LOG" >&2
  exit 1
fi

FAILED=$(printf '%s' "$SUMMARY" | grep -oE '[0-9]+ failed' | grep -oE '[0-9]+' || true)
PASSED=$(printf '%s' "$SUMMARY" | grep -oE '[0-9]+ passed' | grep -oE '[0-9]+' || true)
FAILED=${FAILED:-0}
PASSED=${PASSED:-0}

echo "vitest: $SUMMARY"
echo "baseline allows <= $BASELINE_FAILURES failures, requires >= $MIN_PASSED passing"

if [ "$FAILED" -gt "$BASELINE_FAILURES" ]; then
  echo "FAIL: $FAILED failing tests, baseline is $BASELINE_FAILURES" >&2
  grep -E '^ FAIL ' "$LOG" | head -20 >&2
  exit 1
fi
if [ "$PASSED" -lt "$MIN_PASSED" ]; then
  echo "FAIL: $PASSED passing tests, expected at least $MIN_PASSED" >&2
  exit 1
fi
if [ "$VITEST_EXIT" -ne 0 ] && [ "$FAILED" -eq 0 ]; then
  echo "FAIL: vitest exited $VITEST_EXIT without reporting failures (crash?)" >&2
  tail -30 "$LOG" >&2
  exit 1
fi

echo "PASS: no regression against the Windows-only baseline"
