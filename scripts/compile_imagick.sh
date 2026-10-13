#!/usr/bin/env bash
# compile_imagick.sh — build 538.imagick_r for wasm32-unknown-wasi
# NOTE: Large benchmark (259 KLOC) — may hit WASI compat issues
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

if [[ "$TARGET" == "lfi" ]]; then
  # LFI sandbox: the LFI clang (musl, static PIE); same flags otherwise
  # (musl headers are stricter than glibc's: some sources rely on <fcntl.h>/<string.h>/
  # <unistd.h> coming in transitively, or on struct stat64 without _LARGEFILE64_SOURCE)
  LFI_COMPAT="-D_GNU_SOURCE -D_LARGEFILE64_SOURCE -include fcntl.h -include string.h -include unistd.h"
  CC="x86_64_lfi-linux-musl-clang -static-pie $LFI_COMPAT"; CXX="x86_64_lfi-linux-musl-clang++ -static-pie $LFI_COMPAT"
  PLAT_DIR="lfi"; BIN_EXT=""
fi

BENCH="538.imagick_r"
SRC="$REPO_ROOT/benchspec/CPU/$BENCH/src"
OUT="$BUILD_DIR/bin/$BENCH/$PLAT_DIR"
mkdir -p "$OUT"

if [[ ! -d "$SRC" ]]; then
  echo "ERROR: source directory $SRC not found -- run 'make extract' first" >&2
  exit 1
fi

CFLAGS="-O2 -pthread -DSPEC -DNDEBUG -DSPEC_AUTO_SUPPRESS_OPENMP"
CFLAGS+=" -I$SRC -I$SRC/magick -I$SRC/coders -I$SRC/filters -I$SRC/wand"
if [[ "$TARGET" == "native" || "$TARGET" == "lfi" ]]; then
  LDFLAGS=""
else
  LDFLAGS="-Wl,--import-memory,--export-memory,--shared-memory,--max-memory=67108864"
  LDFLAGS+=" -Wl,--export=__stack_pointer,--export=__stack_low"
fi

echo "[imagick] compiling $BENCH..."

OBJS=()

# Compile all .c files in each source directory
for dir in magick coders filters wand utilities; do
  for src in "$SRC/$dir"/*.c; do
    [[ -f "$src" ]] || continue
    obj="$OUT/${dir}_$(basename "${src%.c}").o"
    $CC $CFLAGS -c "$src" -o "$obj"
    OBJS+=("$obj")
  done
done

$CC $LDFLAGS "${OBJS[@]}" -lm -o "$OUT/imagick_r${BIN_EXT}"

echo "[imagick] built $OUT/imagick_r${BIN_EXT}"

if [[ "$TARGET" == "wasm" ]]; then
  WASM_OPT="${WASM_OPT:-${LIND_WASM_ROOT}/tools/binaryen/bin/wasm-opt}"
  LIND_BOOT="${LIND_BOOT:-${LIND_WASM_ROOT}/build/lind-boot}"

  if [[ -x "$WASM_OPT" ]]; then
    echo "[imagick] running wasm-opt..."
    "$WASM_OPT" --epoch-injection --asyncify --debuginfo -O2 \
      "$OUT/imagick_r.wasm" -o "$OUT/imagick_r.opt.wasm"
    echo "[imagick] built $OUT/imagick_r.opt.wasm"
  fi

  if [[ -x "$LIND_BOOT" ]]; then
    INPUT="$OUT/imagick_r.opt.wasm"
    [[ -f "$INPUT" ]] || INPUT="$OUT/imagick_r.wasm"
    echo "[imagick] running lind-boot --precompile..."
    "$LIND_BOOT" --precompile "$INPUT" || true
    [[ -f "$OUT/imagick_r.opt.cwasm" ]] && mv "$OUT/imagick_r.opt.cwasm" "$OUT/imagick_r.cwasm"
    [[ -f "$OUT/imagick_r.cwasm" ]] && echo "[imagick] built $OUT/imagick_r.cwasm"
  fi
fi

echo "[imagick] done"
