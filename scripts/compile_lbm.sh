#!/usr/bin/env bash
# compile_lbm.sh — build 519.lbm_r for wasm32-unknown-wasi
set -euo pipefail

# -------- Paths ---------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$SCRIPT_DIR/.."
BUILD_DIR="$REPO_ROOT/build"
TOOL_ENV="$BUILD_DIR/.toolchain.env"

# -------- Toolchain -----------------------------------------------------------
if [[ -r "$TOOL_ENV" ]]; then
  . "$TOOL_ENV"
else
  echo "ERROR: $TOOL_ENV not found — run 'make preflight' first" >&2
  exit 1
fi

LIND_WASM_ROOT="${LIND_WASM_ROOT:-$(cd "$REPO_ROOT/.." && pwd)}"
SYSROOT="${BASE_SYSROOT:-$LIND_WASM_ROOT/build/sysroot}"

TARGET="${TARGET:-wasm}"

if [[ "$TARGET" == "native" || "$TARGET" == "lfi" ]]; then
  CC="$CLANG"
  PLAT_DIR="native-linux"
  BIN_EXT=""
else
  CC="$CLANG --target=wasm32-unknown-wasi --sysroot=$SYSROOT"
  PLAT_DIR="wasm32-wasi"
  BIN_EXT=".wasm"
fi

# -------- Flags ---------------------------------------------------------------
# -DSPEC        : enables SPEC mode (uses time.h instead of sys/times.h)
# -DNDEBUG      : standard for optimised builds
# -DSPEC_AUTO_SUPPRESS_OPENMP : disables OpenMP (no threads in WASI)
CFLAGS="-O2 -pthread -DSPEC -DNDEBUG -DSPEC_AUTO_SUPPRESS_OPENMP"
if [[ "$TARGET" == "native" || "$TARGET" == "lfi" ]]; then
  LDFLAGS=""
else
  LDFLAGS="-Wl,--import-memory,--export-memory,--shared-memory,--max-memory=67108864"
  LDFLAGS+=" -Wl,--export=__stack_pointer,--export=__stack_low"
fi

# -------- Source + output dirs ------------------------------------------------
if [[ "$TARGET" == "lfi" ]]; then
  # LFI sandbox: the LFI clang (musl, static PIE); same flags otherwise
  # (musl headers are stricter than glibc's: some sources rely on <fcntl.h>/<string.h>/
  # <unistd.h> coming in transitively, or on struct stat64 without _LARGEFILE64_SOURCE)
  LFI_COMPAT="-D_GNU_SOURCE -D_LARGEFILE64_SOURCE -include fcntl.h -include string.h -include unistd.h"
  CC="x86_64_lfi-linux-musl-clang -static-pie $LFI_COMPAT"; CXX="x86_64_lfi-linux-musl-clang++ -static-pie $LFI_COMPAT"
  PLAT_DIR="lfi"; BIN_EXT=""
fi

BENCH="519.lbm_r"
SRC="${SPEC_ROOT:-$REPO_ROOT}/benchspec/CPU/$BENCH/src"
OUT="$BUILD_DIR/bin/$BENCH/$PLAT_DIR"
mkdir -p "$OUT"

if [[ ! -d "$SRC" ]]; then
  echo "ERROR: source directory $SRC not found — run 'make extract' first" >&2
  exit 1
fi

echo "[lbm] compiling $BENCH..."

# -------- Compile -------------------------------------------------------------
$CC $CFLAGS -c "$SRC/lbm.c"  -o "$OUT/lbm.o"
$CC $CFLAGS -c "$SRC/main.c" -o "$OUT/main.o"

# -------- Link ----------------------------------------------------------------
$CC $LDFLAGS "$OUT/lbm.o" "$OUT/main.o" -lm -o "$OUT/lbm_r${BIN_EXT}"

echo "[lbm] built $OUT/lbm_r${BIN_EXT}"

if [[ "$TARGET" == "wasm" ]]; then
  WASM_OPT="${WASM_OPT:-${LIND_WASM_ROOT}/tools/binaryen/bin/wasm-opt}"
  LIND_BOOT="${LIND_BOOT:-${LIND_WASM_ROOT}/build/lind-boot}"

  if [[ -x "$WASM_OPT" ]]; then
    echo "[lbm] running wasm-opt..."
    "$WASM_OPT" --epoch-injection --asyncify --debuginfo -O2 \
      "$OUT/lbm_r.wasm" -o "$OUT/lbm_r.opt.wasm"
    echo "[lbm] built $OUT/lbm_r.opt.wasm"
  fi

  if [[ -x "$LIND_BOOT" ]]; then
    INPUT="$OUT/lbm_r.opt.wasm"
    [[ -f "$INPUT" ]] || INPUT="$OUT/lbm_r.wasm"
    echo "[lbm] running lind-boot --precompile..."
    "$LIND_BOOT" --precompile "$INPUT" || true
    [[ -f "$OUT/lbm_r.opt.cwasm" ]] && mv "$OUT/lbm_r.opt.cwasm" "$OUT/lbm_r.cwasm"
    [[ -f "$OUT/lbm_r.cwasm" ]] && echo "[lbm] built $OUT/lbm_r.cwasm"
  fi
fi

echo "[lbm] done"
