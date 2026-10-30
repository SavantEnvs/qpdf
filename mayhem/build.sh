#!/usr/bin/env bash
#
# mayhem/build.sh — build qpdf's OSS-Fuzz harnesses (sanitized, libFuzzer + standalone) and the
# qtest/ctest suite (normal flags). Runs in the commit image as `mayhem` in /mayhem; re-runnable
# and offline (zlib/libjpeg come from apt -dev packages baked by the Dockerfile).
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

: "${SRC:=/mayhem}"
cd "$SRC"

FUZZERS="qpdf_fuzzer qpdf_crypt_fuzzer qpdf_crypt_insecure_fuzzer qpdf_lin_fuzzer qpdf_pages_fuzzer
  qpdf_outlines_fuzzer ascii85_fuzzer dct_fuzzer flate_fuzzer hex_fuzzer json_fuzzer lzw_fuzzer
  pngpredictor_fuzzer runlength_fuzzer tiffpredictor_fuzzer"

# 1) Test suite first, NORMAL flags, in its own (gitignored) build dir. The fuzz targets in this
#    tree link qpdf's own file-input runner because LIB_FUZZING_ENGINE is unset for this configure.
env -u LIB_FUZZING_ENGINE -u SANITIZER_FLAGS \
  cmake -S . -B build.test -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
    -DCMAKE_C_FLAGS="$COVERAGE_FLAGS" -DCMAKE_CXX_FLAGS="$COVERAGE_FLAGS" \
    -DCMAKE_EXE_LINKER_FLAGS="$COVERAGE_FLAGS" -DCMAKE_SHARED_LINKER_FLAGS="$COVERAGE_FLAGS" \
    -DWERROR=OFF -DREQUIRE_SHELLS=OFF
env -u LIB_FUZZING_ENGINE -u SANITIZER_FLAGS cmake --build build.test -j"$MAYHEM_JOBS"

# 2) Sanitized fuzz build. -fsanitize=fuzzer-no-link puts SanCov in the library itself (not just
#    the harness TU), unconditionally, so coverage exists even with the empty sanitizer off-switch.
mkdir -p build/mayhem-out
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o build/lsan_off.o
FZ="$SANITIZER_FLAGS -fsanitize=fuzzer-no-link -O1 $DEBUG_FLAGS"
cmake -S . -B build -DCMAKE_BUILD_TYPE=None \
  -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
  -DCMAKE_C_FLAGS="$FZ" -DCMAKE_CXX_FLAGS="$FZ" \
  -DCMAKE_EXE_LINKER_FLAGS="$SRC/build/lsan_off.o" \
  -DBUILD_SHARED_LIBS=OFF -DBUILD_STATIC_LIBS=ON \
  -DUSE_IMPLICIT_CRYPTO=OFF -DREQUIRE_CRYPTO_NATIVE=ON \
  -DWERROR=OFF -DREQUIRE_SHELLS=OFF -DENABLE_QTC=OFF
cmake --build build -j"$MAYHEM_JOBS" --target $FUZZERS

# 3) Per harness: the libFuzzer binary, plus a standalone run-once reproducer made by re-using the
#    harness's own link line with qpdf's file-input driver in place of -fsanitize=fuzzer.
FLAGS_MK=build/fuzz/CMakeFiles/qpdf_fuzzer.dir/flags.make
mk_var() { sed -n "s/^$1 = //p" "$FLAGS_MK"; }
# shellcheck disable=SC2046
$CXX $(mk_var CXX_DEFINES) $(mk_var CXX_INCLUDES) $(mk_var CXX_FLAGS) \
  -c fuzz/standalone_fuzz_target_runner.cc -o build/mayhem-out/standalone_main.o
for t in $FUZZERS; do
  cp "build/fuzz/$t" "build/mayhem-out/$t"
  (cd build/fuzz && sed -e 's# -fsanitize=fuzzer # '"$SRC"'/build/mayhem-out/standalone_main.o #' \
       -e "s# -o $t # -o $SRC/build/mayhem-out/$t-standalone #" \
       "CMakeFiles/$t.dir/link.txt" | bash -e)
done
ls -l build/mayhem-out
