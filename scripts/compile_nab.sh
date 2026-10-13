#!/usr/bin/env bash
# compile_nab.sh — build 544.nab_r for wasm32-unknown-wasi
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

CFLAGS="-O2 -std=c99 -pthread -DSPEC -DSPEC_CPU -DNDEBUG -DNOPERFLIB -DNOREDUCE -DSPEC_AUTO_SUPPRESS_OPENMP"
if [[ "$TARGET" == "native" || "$TARGET" == "lfi" ]]; then
  LDFLAGS=""
else
  LDFLAGS="-Wl,--import-memory,--export-memory,--shared-memory,--max-memory=67108864"
  LDFLAGS+=" -Wl,--export=__stack_pointer,--export=__stack_low"
fi

if [[ "$TARGET" == "lfi" ]]; then
  # LFI sandbox: the LFI clang (musl, static PIE); same flags otherwise
  # (musl headers are stricter than glibc's: some sources rely on <fcntl.h>/<string.h>/
  # <unistd.h> coming in transitively, or on struct stat64 without _LARGEFILE64_SOURCE)
  LFI_COMPAT="-D_GNU_SOURCE -D_LARGEFILE64_SOURCE -include fcntl.h -include string.h -include unistd.h"
  CC="x86_64_lfi-linux-musl-clang -static-pie $LFI_COMPAT"; CXX="x86_64_lfi-linux-musl-clang++ -static-pie $LFI_COMPAT"
  PLAT_DIR="lfi"; BIN_EXT=""
fi

BENCH="544.nab_r"
SRC="$REPO_ROOT/benchspec/CPU/$BENCH/src"
OUT="$BUILD_DIR/bin/$BENCH/$PLAT_DIR"
mkdir -p "$OUT"

if [[ ! -d "$SRC" ]]; then
  echo "ERROR: source directory $SRC not found -- run 'make extract' first" >&2
  exit 1
fi

echo "[nab] compiling $BENCH..."

SRCS=(
  nabmd.c
  sff.c
  nblist.c
  prm.c
  memutil.c
  molutil.c
  molio.c
  binpos.c
  database.c
  select_atoms.c
  reslib.c
  chirvol.c
  errormsg.c
  traceback.c
  rand2.c
  regex-alpha/regcomp.c
  regex-alpha/regerror.c
  regex-alpha/regexec.c
  regex-alpha/regfree.c
  specrand/specrand.c
)

OBJS=()
for src in "${SRCS[@]}"; do
  obj="$OUT/$(basename "${src%.c}").o"
  $CC $CFLAGS -I"$SRC" -I"$SRC/regex-alpha" -I"$SRC/specrand" -c "$SRC/$src" -o "$obj"
  OBJS+=("$obj")
done

$CC $LDFLAGS "${OBJS[@]}" -lm -o "$OUT/nab_r${BIN_EXT}"

echo "[nab] built $OUT/nab_r${BIN_EXT}"

if [[ "$TARGET" == "wasm" ]]; then
  WASM_OPT="${WASM_OPT:-${LIND_WASM_ROOT}/tools/binaryen/bin/wasm-opt}"
  LIND_BOOT="${LIND_BOOT:-${LIND_WASM_ROOT}/build/lind-boot}"

  if [[ -x "$WASM_OPT" ]]; then
    echo "[nab] running wasm-opt..."
    "$WASM_OPT" --epoch-injection --asyncify --debuginfo -O2 \
      "$OUT/nab_r.wasm" -o "$OUT/nab_r.opt.wasm"
    echo "[nab] built $OUT/nab_r.opt.wasm"
  fi

  if [[ -x "$LIND_BOOT" ]]; then
    INPUT="$OUT/nab_r.opt.wasm"
    [[ -f "$INPUT" ]] || INPUT="$OUT/nab_r.wasm"
    echo "[nab] running lind-boot --precompile..."
    "$LIND_BOOT" --precompile "$INPUT" || true
    [[ -f "$OUT/nab_r.opt.cwasm" ]] && mv "$OUT/nab_r.opt.cwasm" "$OUT/nab_r.cwasm"
    [[ -f "$OUT/nab_r.cwasm" ]] && echo "[nab] built $OUT/nab_r.cwasm"
  fi
fi

echo "[nab] done"
