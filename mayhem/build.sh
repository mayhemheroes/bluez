#!/usr/bin/env bash
#
# mayhem/build.sh — build BlueZ's fuzz harnesses + the upstream unit-test suite.
#
# Runs inside the commit image (mayhem/Dockerfile) as /mayhem. The base image exports the build
# contract (CC, CXX, LIB_FUZZING_ENGINE, SANITIZER_FLAGS, DEBUG_FLAGS, SRC, STANDALONE_FUZZ_MAIN).
#
# BlueZ needs the ELL source tree next to it: configure looks for ${srcdir}/../ell/ell/ell.h.
# The Dockerfile pre-clones ELL to /ell (so /mayhem/../ell == /ell), which keeps the offline
# re-run air-gapped — build.sh never touches the network.
#
# Two independent out-of-tree builds:
#   build-normal — clean upstream flags → the unit-test suite (mayhem/test.sh only RUNS it).
#   build-asan   — the whole project instrumented (ASan+UBSan halting, + libFuzzer coverage) →
#                  the objects/libs every harness links against, so the FUZZED code is instrumented.
#
# We ship all 5 OSS-Fuzz harnesses (fuzz_sdp/xml/textfile/gobex/hci) — same code paths, ported to
# the in-image /mayhem layout and linked against the instrumented tree.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

CONFIGURE_ARGS=(--enable-library --disable-datafiles --disable-manpages --disable-systemd)
UDEVDIR=/tmp/udev

./bootstrap

# --------------------------------------------------------------------------------------------
# 1) NORMAL build (unit-test oracle) — the project's own flags, NO sanitizers. Objects here are
#    reused by mayhem/test.sh's `make check` to build+run the 37 upstream unit tests.
# --------------------------------------------------------------------------------------------
rm -rf "$SRC/build-normal"
mkdir -p "$SRC/build-normal"
(
  cd "$SRC/build-normal"
  ../configure "${CONFIGURE_ARGS[@]}" --enable-testing --with-udevdir="$UDEVDIR" \
      CC="$CC" CFLAGS="${COVERAGE_FLAGS}" LDFLAGS="${COVERAGE_FLAGS}"
  make -j"$MAYHEM_JOBS"
)

# --------------------------------------------------------------------------------------------
# 2) INSTRUMENTED build — ASan + UBSan (halting) + libFuzzer coverage so the fuzzed code is both
#    instrumented AND edge-tracked. UBSan's `function` check is relaxed: BlueZ deliberately calls
#    generic free callbacks (e.g. sdp_data_free) through differently-typed pointers, a benign C
#    idiom that would otherwise abort on every input; ASan + the rest of UBSan stay halting.
#    A FULL `make` gives every object the harnesses link against, instrumented.
# --------------------------------------------------------------------------------------------
PROJECT_FLAGS="$SANITIZER_FLAGS -fsanitize=fuzzer-no-link -fno-sanitize=function $DEBUG_FLAGS"
rm -rf "$SRC/build-asan"
mkdir -p "$SRC/build-asan"
(
  cd "$SRC/build-asan"
  ../configure "${CONFIGURE_ARGS[@]}" --enable-testing --with-udevdir="$UDEVDIR" CC="$CC" CFLAGS="$PROJECT_FLAGS"
  make -j"$MAYHEM_JOBS"
)

A="$SRC/build-asan"
LIBS=("$A/lib/.libs/libbluetooth-internal.a" "$A/src/.libs/libshared-glib.a")
INCLUDES=(-I"$SRC" -I"$SRC/src" -I"$SRC/lib" -I"$SRC/lib/bluetooth" -I"$SRC/gobex" -I"$A"
          $(pkg-config --cflags glib-2.0 dbus-1))
SYSLIBS=($(pkg-config --libs glib-2.0 dbus-1) -ldl -lpthread)

GOBEX_OBJS=("$A"/gobex/gobex.o "$A"/gobex/gobex-*.o)

# target -> extra instrumented objects it links against (beyond LIBS)
build_target() {
  local name="$1"; shift
  local extra=("$@")
  echo ">>> building $name"
  # fuzzer binary
  $CC $PROJECT_FLAGS $LIB_FUZZING_ENGINE "${INCLUDES[@]}" \
      "$SRC/mayhem/$name.c" "${extra[@]}" -o "/mayhem/$name" \
      "${LIBS[@]}" "${SYSLIBS[@]}"
  # run-once standalone reproducer (no libFuzzer runtime — crashes naturally on a bad input)
  $CC $PROJECT_FLAGS "$STANDALONE_FUZZ_MAIN" "${INCLUDES[@]}" \
      "$SRC/mayhem/$name.c" "${extra[@]}" -o "/mayhem/$name-standalone" \
      "${LIBS[@]}" "${SYSLIBS[@]}"
}

build_target fuzz_sdp
build_target fuzz_hci
build_target fuzz_xml      "$A/src/bluetoothd-sdp-xml.o"
build_target fuzz_textfile "$A/src/textfile.o"
build_target fuzz_gobex    "${GOBEX_OBJS[@]}"

echo "build.sh: done — fuzz_sdp/hci/xml/textfile/gobex built (+ -standalone); unit tests in build-normal/"
