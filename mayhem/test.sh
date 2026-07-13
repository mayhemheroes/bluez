#!/usr/bin/env bash
#
# mayhem/test.sh — RUN BlueZ's upstream unit-test suite (automake `make check`, the entire
# TESTS = $(unit_tests) set) that mayhem/build.sh staged in build-normal/, then cross-check a
# handful of those test binaries by their ACTUAL OUTPUT.
#
# Why the output cross-check: automake judges a test purely by its exit code, so a program
# neutered to exit(0) would still "PASS" the suite. The behavioral guard below re-runs a set of
# core library tests and asserts each still prints its known "test passed" lines — a no-op /
# exit(0) sabotage produces no output and FAILS the guard. This makes the oracle assert behavior,
# not just exit status. Emits a CTRF summary and exits nonzero on any failure.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"
cd "$SRC"

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

BUILD_DIR="$SRC/build-normal"
if [ ! -f "$BUILD_DIR/Makefile" ]; then
  echo "test.sh: build-normal/Makefile missing — mayhem/build.sh did not run" >&2
  emit_ctrf "bluez-unit" 0 1 0
  exit 1
fi

# --- 1) run the full upstream suite -------------------------------------------------
LOG=$(mktemp)
set +e
make -C "$BUILD_DIR" -j"$MAYHEM_JOBS" check 2>&1 | tee "$LOG"
set -e

grab() { grep -E "^# $1:" "$LOG" | tail -1 | grep -oE '[0-9]+' | tail -1; }
TOTAL=$(grab TOTAL); PASS=$(grab PASS); SKIP=$(grab SKIP)
XFAIL=$(grab XFAIL); FAIL=$(grab FAIL); XPASS=$(grab XPASS); ERROR=$(grab ERROR)
: "${TOTAL:=0}" "${PASS:=0}" "${SKIP:=0}" "${XFAIL:=0}" "${FAIL:=0}" "${XPASS:=0}" "${ERROR:=0}"

if [ "$TOTAL" -eq 0 ]; then
  echo "test.sh: no automake summary found — suite did not run" >&2
  emit_ctrf "bluez-unit" 0 1 0
  exit 1
fi
suite_pass=$(( PASS + XFAIL ))
suite_fail=$(( FAIL + XPASS + ERROR ))

# --- 2) behavioral guard: core lib tests must still emit their "test passed" lines --
# Each of these upstream unit tests runs known-answer vectors and prints one "test passed" per
# subtest. A neutered binary prints nothing -> guard failure -> oracle fails (anti-reward-hack).
GUARDS=(test-crc test-uuid test-lib test-textfile test-ringbuf test-queue test-eir test-ecc)
guard_pass=0; guard_fail=0
for t in "${GUARDS[@]}"; do
  bin="$BUILD_DIR/unit/$t"
  if [ ! -x "$bin" ]; then
    echo "guard: $t not built — skipping (not a failure)"; continue
  fi
  n=$("$bin" 2>&1 | grep -c "test passed" || true)
  if [ "$n" -ge 1 ]; then
    echo "guard: $t -> $n 'test passed' (ok)"; guard_pass=$((guard_pass+1))
  else
    echo "guard: $t -> 0 'test passed' (FAIL — no behavioral output)" >&2; guard_fail=$((guard_fail+1))
  fi
done

passed=$(( suite_pass + guard_pass ))
failed=$(( suite_fail + guard_fail ))
emit_ctrf "bluez-unit" "$passed" "$failed" "$SKIP"
