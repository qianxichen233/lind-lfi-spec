#!/usr/bin/env bash
# compile_xz.sh — build 557.xz_r for wasm32-unknown-wasi
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

BENCH="557.xz_r"
SRC="${SPEC_ROOT:-$REPO_ROOT}/benchspec/CPU/$BENCH/src"
OUT="$BUILD_DIR/bin/$BENCH/$PLAT_DIR"
mkdir -p "$OUT"

if [[ ! -d "$SRC" ]]; then
  echo "ERROR: source directory $SRC not found -- run 'make extract' first" >&2
  exit 1
fi

CFLAGS="-O2 -std=c99 -pthread -fno-strict-aliasing"
CFLAGS+=" -DSPEC -DSPEC_CPU -DNDEBUG -DSPEC_AUTO_SUPPRESS_OPENMP"
CFLAGS+=" -DSPEC_AUTO_BYTEORDER=0x12345678 -DHAVE_CONFIG_H=1 -DSPEC_MEM_IO -DSPEC_XZ"
CFLAGS+=" -I$SRC -I$SRC/spec_mem_io -I$SRC/sha-2 -I$SRC/common"
CFLAGS+=" -I$SRC/liblzma/api -I$SRC/liblzma/check -I$SRC/liblzma/common"
CFLAGS+=" -I$SRC/liblzma/delta -I$SRC/liblzma/lz -I$SRC/liblzma/lzma"
CFLAGS+=" -I$SRC/liblzma/rangecoder -I$SRC/liblzma/simple"
if [[ "$TARGET" == "native" || "$TARGET" == "lfi" ]]; then
  LDFLAGS=""
else
  LDFLAGS="-Wl,--import-memory,--export-memory,--shared-memory,--max-memory=67108864"
  LDFLAGS+=" -Wl,--export=__stack_pointer,--export=__stack_low"
fi

echo "[xz] compiling $BENCH..."

# SPEC driver + support files
SRCS=(
  spec.c
  spec_xz.c
  pxz.c
  spec_mem_io/spec_mem_io.c
  sha-2/sha512.c
)

# liblzma common
SRCS+=(
  liblzma/common/common.c
  liblzma/common/block_util.c
  liblzma/common/easy_preset.c
  liblzma/common/filter_common.c
  liblzma/common/hardware_physmem.c
  liblzma/common/index.c
  liblzma/common/stream_flags_common.c
  liblzma/common/vli_size.c
  liblzma/common/alone_encoder.c
  liblzma/common/block_buffer_encoder.c
  liblzma/common/block_encoder.c
  liblzma/common/block_header_encoder.c
  liblzma/common/easy_buffer_encoder.c
  liblzma/common/easy_encoder.c
  liblzma/common/easy_encoder_memusage.c
  liblzma/common/filter_buffer_encoder.c
  liblzma/common/filter_encoder.c
  liblzma/common/filter_flags_encoder.c
  liblzma/common/index_encoder.c
  liblzma/common/stream_buffer_encoder.c
  liblzma/common/stream_encoder.c
  liblzma/common/stream_flags_encoder.c
  liblzma/common/vli_encoder.c
  liblzma/common/alone_decoder.c
  liblzma/common/auto_decoder.c
  liblzma/common/block_buffer_decoder.c
  liblzma/common/block_decoder.c
  liblzma/common/block_header_decoder.c
  liblzma/common/easy_decoder_memusage.c
  liblzma/common/filter_buffer_decoder.c
  liblzma/common/filter_decoder.c
  liblzma/common/filter_flags_decoder.c
  liblzma/common/index_decoder.c
  liblzma/common/index_hash.c
  liblzma/common/stream_buffer_decoder.c
  liblzma/common/stream_decoder.c
  liblzma/common/stream_flags_decoder.c
  liblzma/common/vli_decoder.c
)

# liblzma check
SRCS+=(
  liblzma/check/check.c
  liblzma/check/crc32_table.c
  liblzma/check/crc32_fast.c
  liblzma/check/crc64_table.c
  liblzma/check/crc64_fast.c
  liblzma/check/sha256.c
)

# liblzma lz
SRCS+=(
  liblzma/lz/lz_encoder.c
  liblzma/lz/lz_encoder_mf.c
  liblzma/lz/lz_decoder.c
)

# liblzma lzma
SRCS+=(
  liblzma/lzma/lzma_encoder.c
  liblzma/lzma/lzma_encoder_presets.c
  liblzma/lzma/lzma_encoder_optimum_fast.c
  liblzma/lzma/lzma_encoder_optimum_normal.c
  liblzma/lzma/fastpos_table.c
  liblzma/lzma/lzma_decoder.c
  liblzma/lzma/lzma2_encoder.c
  liblzma/lzma/lzma2_decoder.c
)

# liblzma rangecoder
SRCS+=(
  liblzma/rangecoder/price_table.c
)

# liblzma delta
SRCS+=(
  liblzma/delta/delta_common.c
  liblzma/delta/delta_encoder.c
  liblzma/delta/delta_decoder.c
)

# liblzma simple (arch filters)
SRCS+=(
  liblzma/simple/simple_coder.c
  liblzma/simple/simple_encoder.c
  liblzma/simple/simple_decoder.c
  liblzma/simple/x86.c
  liblzma/simple/powerpc.c
  liblzma/simple/ia64.c
  liblzma/simple/arm.c
  liblzma/simple/armthumb.c
  liblzma/simple/sparc.c
)

# xz command-line tool
SRCS+=(
  xz/args.c
  xz/coder.c
  xz/file_io.c
  xz/hardware.c
  xz/list.c
  xz/main.c
  xz/message.c
  xz/options.c
  xz/signals.c
  xz/util.c
)

# tuklib common utilities
SRCS+=(
  common/tuklib_physmem.c
  common/tuklib_cpucores.c
  common/tuklib_open_stdxxx.c
  common/tuklib_progname.c
  common/tuklib_exit.c
  common/tuklib_mbstr_width.c
  common/tuklib_mbstr_fw.c
)

OBJS=()
for src in "${SRCS[@]}"; do
  obj="$OUT/$(basename "${src%.c}").o"
  $CC $CFLAGS -c "$SRC/$src" -o "$obj"
  OBJS+=("$obj")
done

$CC $LDFLAGS "${OBJS[@]}" -o "$OUT/xz_r${BIN_EXT}"

echo "[xz] built $OUT/xz_r${BIN_EXT}"

if [[ "$TARGET" == "wasm" ]]; then
  WASM_OPT="${WASM_OPT:-${LIND_WASM_ROOT}/tools/binaryen/bin/wasm-opt}"
  LIND_BOOT="${LIND_BOOT:-${LIND_WASM_ROOT}/build/lind-boot}"

  if [[ -x "$WASM_OPT" ]]; then
    echo "[xz] running wasm-opt..."
    "$WASM_OPT" --epoch-injection --asyncify --debuginfo -O2 \
      "$OUT/xz_r.wasm" -o "$OUT/xz_r.opt.wasm"
    echo "[xz] built $OUT/xz_r.opt.wasm"
  fi

  if [[ -x "$LIND_BOOT" ]]; then
    INPUT="$OUT/xz_r.opt.wasm"
    [[ -f "$INPUT" ]] || INPUT="$OUT/xz_r.wasm"
    echo "[xz] running lind-boot --precompile..."
    "$LIND_BOOT" --precompile "$INPUT" || true
    [[ -f "$OUT/xz_r.opt.cwasm" ]] && mv "$OUT/xz_r.opt.cwasm" "$OUT/xz_r.cwasm"
    [[ -f "$OUT/xz_r.cwasm" ]] && echo "[xz] built $OUT/xz_r.cwasm"
  fi
fi

echo "[xz] done"
