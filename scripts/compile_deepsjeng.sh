#!/usr/bin/env bash
# compile_deepsjeng.sh — build 531.deepsjeng_r for wasm32-unknown-wasi
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

# clang++ comes from .toolchain.env (preflight sets CLANGPP); fall back to
# deriving it from $CLANG if running an older toolchain.env.
if [[ -z "${CLANGPP:-}" || ! -x "$CLANGPP" ]]; then
  CLANGPP="${CLANG}++"
  [[ -x "$CLANGPP" ]] || CLANGPP="$(dirname "$CLANG")/clang++"
fi
[[ -x "$CLANGPP" ]] || { echo "ERROR: cannot find clang++ — re-run 'make preflight'" >&2; exit 1; }

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

# -------- Flags ---------------------------------------------------------------
# -fno-exceptions: lind-wasm libc++ does not yet support throw/try/catch.
CXXFLAGS="-O2 -std=c++14 -DSPEC -DNDEBUG -DSMALL_MEMORY -DSPEC_AUTO_SUPPRESS_OPENMP"
if [[ "$TARGET" == "native" || "$TARGET" == "lfi" ]]; then
  LDFLAGS=""
else
  CXXFLAGS+=" -fno-exceptions"
  LDFLAGS="-Wl,--import-memory,--export-memory,--shared-memory,--max-memory=67108864"
  LDFLAGS+=" -Wl,--export=__stack_pointer,--export=__stack_low,--export=__tls_base"
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

BENCH="531.deepsjeng_r"
SRC="${SPEC_ROOT:-$REPO_ROOT}/benchspec/CPU/$BENCH/src"
OUT="$BUILD_DIR/bin/$BENCH/$PLAT_DIR"
mkdir -p "$OUT"

if [[ ! -d "$SRC" ]]; then
  echo "ERROR: source directory $SRC not found — run 'make extract' first" >&2
  exit 1
fi

echo "[deepsjeng] compiling $BENCH..."

# -------- Source files --------------------------------------------------------
SRCS=(
  attacks.cpp
  bitboard.cpp
  bits.cpp
  board.cpp
  draw.cpp
  endgame.cpp
  epd.cpp
  generate.cpp
  initp.cpp
  make.cpp
  moves.cpp
  neval.cpp
  pawn.cpp
  preproc.cpp
  search.cpp
  see.cpp
  sjeng.cpp
  state.cpp
  ttable.cpp
  utils.cpp
)

# -------- Compile -------------------------------------------------------------
OBJS=()
for src in "${SRCS[@]}"; do
  obj="$OUT/${src%.cpp}.o"
  $CXX $CXXFLAGS -I"$SRC" -c "$SRC/$src" -o "$obj"
  OBJS+=("$obj")
done

# -------- Link ----------------------------------------------------------------
$CXX $LDFLAGS "${OBJS[@]}" -o "$OUT/deepsjeng_r${BIN_EXT}"

echo "[deepsjeng] built $OUT/deepsjeng_r${BIN_EXT}"

if [[ "$TARGET" == "wasm" ]]; then
  WASM_OPT="${WASM_OPT:-${LIND_WASM_ROOT}/tools/binaryen/bin/wasm-opt}"
  LIND_BOOT="${LIND_BOOT:-${LIND_WASM_ROOT}/build/lind-boot}"

  if [[ -x "$WASM_OPT" ]]; then
    echo "[deepsjeng] running wasm-opt..."
    "$WASM_OPT" --epoch-injection --asyncify --debuginfo -O2 \
      "$OUT/deepsjeng_r.wasm" -o "$OUT/deepsjeng_r.opt.wasm"
    echo "[deepsjeng] built $OUT/deepsjeng_r.opt.wasm"
  fi

  if [[ -x "$LIND_BOOT" ]]; then
    INPUT="$OUT/deepsjeng_r.opt.wasm"
    [[ -f "$INPUT" ]] || INPUT="$OUT/deepsjeng_r.wasm"
    echo "[deepsjeng] running lind-boot --precompile..."
    "$LIND_BOOT" --precompile "$INPUT" || true
    [[ -f "$OUT/deepsjeng_r.opt.cwasm" ]] && mv "$OUT/deepsjeng_r.opt.cwasm" "$OUT/deepsjeng_r.cwasm"
    [[ -f "$OUT/deepsjeng_r.cwasm" ]] && echo "[deepsjeng] built $OUT/deepsjeng_r.cwasm"
  fi
fi

echo "[deepsjeng] done"
