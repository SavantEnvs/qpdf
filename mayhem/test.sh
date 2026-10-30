#!/usr/bin/env bash
#
# mayhem/test.sh — RUN qpdf's own ctest/qtest suite (built by mayhem/build.sh into build.test/).
# exit 0 = pass. qtest compares real program output to golden files, so a neutered qpdf fails it.
#
# IMPORTANT:
#  * Must assert BEHAVIOR/OUTPUT, not just exit status. The oracle has to check asserted values /
#    golden-output diffs / known-answer results — so a PATCH that "fixes" a bug by making the program
#    exit(0) (or any no-op) FAILS here. Running inputs and checking only "exit 0 / didn't crash" is
#    NOT a functional test (it's trivially reward-hackable) — use the project's real assertion suite.
#  * Do NOT build here — mayhem/build.sh already compiled the test suite (with the project's normal
#    flags). This script only RUNS the pre-built tests and reports counts. If the test runner is
#    missing, that's a build.sh bug — fail loudly rather than silently rebuilding.
#  * REQUIRED OUTPUT — a CTRF (https://ctrf.io) summary so Mayhem/the PATCH grader reads the counts:
#      - writes a CTRF JSON report to ${CTRF_REPORT:-$SRC/ctrf-report.json}, and
#      - prints a one-line `CTRF {...}` marker to stdout (same JSON, compact).
#    Only `results.summary` (with tests/passed/failed/pending/skipped/other) is required.
#    Use the emit_ctrf helper below; it computes tests = passed+failed+skipped and sets the exit
#    code (0 iff failed==0). Map your framework's output to passed/failed/skipped.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

[ -d build.test ] || { echo "build.test/ missing: mayhem/build.sh did not build the suite" >&2; exit 1; }

log="$(mktemp)"
ctest --test-dir build.test -j"$MAYHEM_JOBS" -V > "$log" 2>&1
ctest_rc=$?
tail -25 "$log"

# Sum qtest's own per-suite summaries ("Total tests: N", "Passes: P", "Failures: F", ...).
sum_of() { awk -v k="$1" '$0 ~ "^[0-9]+: " k ": *[0-9]+$" { s += $NF } END { print s + 0 }' "$log"; }
passed=$(sum_of Passes)
failed=$(( $(sum_of Failures) + $(sum_of "Missing Tests") + $(sum_of "Unexpected Passes") ))
skipped=$(sum_of "Expected Failures")
[ "$ctest_rc" -eq 0 ] || [ "$failed" -gt 0 ] || failed=1
[ "$passed" -gt 0 ] || failed=$(( failed + 1 ))   # no qtest summary at all: the suite did not really run

emit_ctrf "cmake-ctest-qtest" "$passed" "$failed" "$skipped"
