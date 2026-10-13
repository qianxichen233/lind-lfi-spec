#!/usr/bin/env bash
# compile_omnetpp.sh — build 520.omnetpp_r for wasm32-unknown-wasi
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$SCRIPT_DIR/.."
BUILD_DIR="$REPO_ROOT/build"
TOOL_ENV="$BUILD_DIR/.toolchain.env"

if [[ -r "$TOOL_ENV" ]]; then
  . "$TOOL_ENV"
else
  echo "ERROR: $TOOL_ENV not found -- run 'make preflight' first" >&2
  exit 1
fi

LIND_WASM_ROOT="${LIND_WASM_ROOT:-$(cd "$REPO_ROOT/.." && pwd)}"
SYSROOT="${BASE_SYSROOT:-$LIND_WASM_ROOT/build/sysroot}"

if [[ -z "${CLANGPP:-}" || ! -x "$CLANGPP" ]]; then
  CLANGPP="${CLANG}++"
  [[ -x "$CLANGPP" ]] || CLANGPP="$(dirname "$CLANG")/clang++"
fi
[[ -x "$CLANGPP" ]] || { echo "ERROR: cannot find clang++ -- re-run 'make preflight'" >&2; exit 1; }

TARGET="${TARGET:-wasm}"

if [[ "$TARGET" == "native" || "$TARGET" == "lfi" ]]; then
  CXX="$CLANGPP"
  PLAT_DIR="native-linux"
  BIN_EXT=""
else
  CXX="$CLANGPP --target=wasm32-unknown-wasi --sysroot=$SYSROOT"
  CXX+=" -isystem $SYSROOT/include/wasm32-wasi/c++/v1"
  PLAT_DIR="wasm32-wasi"
  BIN_EXT=".wasm"
fi

if [[ "$TARGET" == "lfi" ]]; then
  # LFI sandbox: the LFI clang (musl, static PIE); same flags otherwise
  # (musl headers are stricter than glibc's: some sources rely on <fcntl.h>/<string.h>/
  # <unistd.h> coming in transitively, or on struct stat64 without _LARGEFILE64_SOURCE)
  LFI_COMPAT="-D_GNU_SOURCE -D_LARGEFILE64_SOURCE -include fcntl.h -include string.h -include unistd.h"
  CC="x86_64_lfi-linux-musl-clang -static-pie $LFI_COMPAT"; CXX="x86_64_lfi-linux-musl-clang++ -static-pie $LFI_COMPAT"
  PLAT_DIR="lfi"; BIN_EXT=""
fi

BENCH="520.omnetpp_r"
SRC="$REPO_ROOT/benchspec/CPU/$BENCH/src"
OUT="$BUILD_DIR/bin/$BENCH/$PLAT_DIR"
mkdir -p "$OUT"

if [[ ! -d "$SRC" ]]; then
  echo "ERROR: source directory $SRC not found -- run 'make extract' first" >&2
  exit 1
fi

# omnetpp's simulator core uses throw/try/catch pervasively (123 throw sites,
# 39 try blocks, 139 files) as its primary error-reporting mechanism, so
# -fno-exceptions is not viable.  Build with exceptions enabled and rely on
# libc++abi.a in the merged sysroot to satisfy __cxa_throw / _Unwind_*.  If
# lind-wasm cannot service the runtime calls, this will fail when an
# exception actually fires (the test workload should not raise any).
CXXFLAGS="-O2 -std=c++14 -pthread -DSPEC -DNDEBUG -DSPEC_AUTO_SUPPRESS_OPENMP"
CXXFLAGS+=" -DWITH_NETBUILDER"
CXXFLAGS+=" -I$SRC -I$SRC/simulator/platdep -I$SRC/simulator -I$SRC/model"
if [[ "$TARGET" == "native" || "$TARGET" == "lfi" ]]; then
  LDFLAGS=""
else
  LDFLAGS="-Wl,--import-memory,--export-memory,--shared-memory,--max-memory=67108864"
  LDFLAGS+=" -Wl,--export=__stack_pointer,--export=__stack_low,--export=__tls_base"
fi

echo "[omnetpp] compiling $BENCH..."

OBJS=()
for src in $(find "$SRC" -name '*.cc' -o -name '*.cpp' | sort); do
  obj="$OUT/$(basename "${src%.*}").o"
  $CXX $CXXFLAGS -c "$src" -o "$obj"
  OBJS+=("$obj")
done

# C++ exception runtime stubs.  lind-wasm's libc++abi.a does not provide
# the Itanium ABI exception symbols (__cxa_throw, __gxx_personality_v0,
# _Unwind_*).  These stubs satisfy the linker; if any actually fire at
# runtime, the process aborts.  Test workload should not throw.
if [[ "$TARGET" == "wasm" ]]; then
  STUBS_SRC="$SCRIPT_DIR/cpp_exception_stubs.c"
  STUBS_OBJ="$OUT/cpp_exception_stubs.o"
  $CLANG --target=wasm32-unknown-wasi --sysroot="$SYSROOT" \
    -O2 -c "$STUBS_SRC" -o "$STUBS_OBJ"
  OBJS+=("$STUBS_OBJ")
fi

$CXX $LDFLAGS "${OBJS[@]}" -lm -o "$OUT/omnetpp_r${BIN_EXT}"

echo "[omnetpp] built $OUT/omnetpp_r${BIN_EXT}"

if [[ "$TARGET" == "wasm" ]]; then
  WASM_OPT="${WASM_OPT:-${LIND_WASM_ROOT}/tools/binaryen/bin/wasm-opt}"
  LIND_BOOT="${LIND_BOOT:-${LIND_WASM_ROOT}/build/lind-boot}"

  if [[ -x "$WASM_OPT" ]]; then
    echo "[omnetpp] running wasm-opt..."
    "$WASM_OPT" --epoch-injection --asyncify --debuginfo -O2 \
      "$OUT/omnetpp_r.wasm" -o "$OUT/omnetpp_r.opt.wasm"
    echo "[omnetpp] built $OUT/omnetpp_r.opt.wasm"
  fi

  if [[ -x "$LIND_BOOT" ]]; then
    INPUT="$OUT/omnetpp_r.opt.wasm"
    [[ -f "$INPUT" ]] || INPUT="$OUT/omnetpp_r.wasm"
    echo "[omnetpp] running lind-boot --precompile..."
    "$LIND_BOOT" --precompile "$INPUT" || true
    [[ -f "$OUT/omnetpp_r.opt.cwasm" ]] && mv "$OUT/omnetpp_r.opt.cwasm" "$OUT/omnetpp_r.cwasm"
    [[ -f "$OUT/omnetpp_r.cwasm" ]] && echo "[omnetpp] built $OUT/omnetpp_r.cwasm"
  fi
fi

echo "[omnetpp] done"
