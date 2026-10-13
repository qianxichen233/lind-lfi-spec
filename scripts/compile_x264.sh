#!/usr/bin/env bash
# compile_x264.sh — build 525.x264_r for wasm32-unknown-wasi
# NOTE: x264 uses signal.h — may need stubs on WASI
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

BENCH="525.x264_r"
SRC="$REPO_ROOT/benchspec/CPU/$BENCH/src"
OUT="$BUILD_DIR/bin/$BENCH/$PLAT_DIR"
mkdir -p "$OUT"

if [[ ! -d "$SRC" ]]; then
  echo "ERROR: source directory $SRC not found -- run 'make extract' first" >&2
  exit 1
fi

CFLAGS="-O2 -std=c99 -pthread -fno-strict-aliasing -DSPEC -DSPEC_CPU -DNDEBUG -DSPEC_AUTO_SUPPRESS_OPENMP -DSPEC_AUTO_BYTEORDER=0x12345678"
if [[ "$TARGET" == "native" || "$TARGET" == "lfi" ]]; then
  LDFLAGS=""
else
  LDFLAGS="-Wl,--import-memory,--export-memory,--shared-memory,--max-memory=67108864"
  LDFLAGS+=" -Wl,--export=__stack_pointer,--export=__stack_low"
fi

echo "[x264] compiling $BENCH (x264 encoder)..."

# --- x264 encoder ---
X264_CFLAGS="$CFLAGS -I$SRC/ldecod_src/inc -I$SRC/x264_src -I$SRC/x264_src/common -I$SRC/x264_src/extras"
X264_SRCS=(
  x264_src/x264.c
  x264_src/common/common.c
  x264_src/common/cabac.c
  x264_src/common/cpu.c
  x264_src/common/dct.c
  x264_src/common/deblock.c
  x264_src/common/frame.c
  x264_src/common/macroblock.c
  x264_src/common/mc.c
  x264_src/common/mdate.c
  x264_src/common/mvpred.c
  x264_src/common/pixel.c
  x264_src/common/predict.c
  x264_src/common/quant.c
  x264_src/common/rectangle.c
  x264_src/common/set.c
  x264_src/common/vlc.c
  x264_src/encoder/analyse.c
  x264_src/encoder/cabac.c
  x264_src/encoder/cavlc.c
  x264_src/encoder/encoder.c
  x264_src/encoder/lookahead.c
  x264_src/encoder/macroblock.c
  x264_src/encoder/me.c
  x264_src/encoder/ratecontrol.c
  x264_src/encoder/set.c
  x264_src/extras/getopt.c
  x264_src/input/yuv.c
  x264_src/input/y4m.c
  x264_src/input/timecode.c
  x264_src/input/thread.c
  x264_src/output/raw.c
  x264_src/output/matroska.c
  x264_src/output/matroska_ebml.c
  x264_src/output/flv.c
  x264_src/output/flv_bytestream.c
)

OBJS=()
for src in "${X264_SRCS[@]}"; do
  objname="$(echo "${src%.c}" | sed 's|/|_|g').o"
  obj="$OUT/$objname"
  $CC $X264_CFLAGS -c "$SRC/$src" -o "$obj"
  OBJS+=("$obj")
done

$CC $LDFLAGS "${OBJS[@]}" -lm -o "$OUT/x264_r${BIN_EXT}"

echo "[x264] built $OUT/x264_r${BIN_EXT}"

# --- ldecod decoder ---
echo "[x264] compiling ldecod (H.264 decoder)..."

LDECOD_CFLAGS="$CFLAGS -I$SRC/ldecod_src/inc"
LDECOD_SRCS=($(find "$SRC/ldecod_src" -maxdepth 1 -name '*.c' | sort))

# configfile.h defines 'InputParameters cfgparams;' at file scope (no extern),
# causing duplicate definitions in every TU that includes it.  SPEC's native
# build uses '-z muldefs' which wasm-ld doesn't support, so we make the symbol
# weak via #pragma so wasm-ld can merge the copies.
WEAK_HDR="$OUT/ldecod_weak.h"
printf '#pragma weak cfgparams\n' > "$WEAK_HDR"

OBJS=()
for src in "${LDECOD_SRCS[@]}"; do
  obj="$OUT/ldecod_$(basename "${src%.c}").o"
  $CC $LDECOD_CFLAGS -include "$WEAK_HDR" -c "$src" -o "$obj"
  OBJS+=("$obj")
done

$CC $LDFLAGS "${OBJS[@]}" -lm -o "$OUT/ldecod_r${BIN_EXT}"

echo "[x264] built $OUT/ldecod_r${BIN_EXT}"

# --- image validator ---
echo "[x264] compiling imagevalidator..."
$CC $CFLAGS -c "$SRC/image_validator/ImageValidator.c" -o "$OUT/imagevalidator.o"
$CC $LDFLAGS "$OUT/imagevalidator.o" -lm -o "$OUT/imagevalidate_r${BIN_EXT}"

echo "[x264] built $OUT/imagevalidate_r${BIN_EXT}"

if [[ "$TARGET" == "wasm" ]]; then
  WASM_OPT="${WASM_OPT:-${LIND_WASM_ROOT}/tools/binaryen/bin/wasm-opt}"
  LIND_BOOT="${LIND_BOOT:-${LIND_WASM_ROOT}/build/lind-boot}"

  if [[ -x "$WASM_OPT" ]]; then
    for wasm in "$OUT"/*.wasm; do
      echo "[x264] optimizing $(basename "$wasm")..."
      "$WASM_OPT" --epoch-injection --asyncify --debuginfo -O2 \
        "$wasm" -o "${wasm%.wasm}.opt.wasm"
    done
  fi

  if [[ -x "$LIND_BOOT" ]]; then
    for wasm in "$OUT"/*.opt.wasm; do
      [[ -f "$wasm" ]] || continue
      echo "[x264] precompiling $(basename "$wasm")..."
      "$LIND_BOOT" --precompile "$wasm" || true
      cwasm="${wasm%.wasm}.cwasm"
      if [[ -f "$cwasm" ]]; then
        final="${cwasm/.opt.cwasm/.cwasm}"
        mv "$cwasm" "$final"
        echo "[x264] built $final"
      fi
    done
  fi
fi

echo "[x264] done"
