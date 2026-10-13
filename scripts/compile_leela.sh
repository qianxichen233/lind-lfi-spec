#!/usr/bin/env bash
# compile_leela.sh — build 541.leela_r for wasm32-unknown-wasi
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

BENCH="541.leela_r"
SRC="$REPO_ROOT/benchspec/CPU/$BENCH/src"
OUT="$BUILD_DIR/bin/$BENCH/$PLAT_DIR"
mkdir -p "$OUT"

if [[ ! -d "$SRC" ]]; then
  echo "ERROR: source directory $SRC not found -- run 'make extract' first" >&2
  exit 1
fi

# -------- Patch leela source for -fno-exceptions ------------------------------
# leela's main loop (Leela.cpp) wraps everything in try/catch and uses
# `throw std::exception()` from SGFParser/SGFTree to signal end-of-file.
# Bundled Boost (boost/array.hpp, boost/exception/exception.hpp) has raw
# throws not gated by BOOST_NO_EXCEPTIONS.  Under -fno-exceptions clang
# refuses to parse any of these, so rewrite them to non-exception
# equivalents.  All patches are idempotent (no-op if already applied).
patch_in_place() {
  local file="$1" pattern="$2" replacement="$3"
  if [[ -f "$file" ]] && grep -qF "$pattern" "$file"; then
    sed -i "s|$(printf '%s\n' "$pattern" | sed 's:[][\\/.^$*]:\\&:g')|$replacement|" "$file"
    echo "[leela] patched $(basename "$(dirname "$file")")/$(basename "$file"): $pattern"
  fi
}
# Boost templates: rewrite raw throws to __builtin_trap (never reached on the
# benchmark inputs; rangecheck and clone_impl::rethrow are not exercised).
patch_in_place "$SRC/boost/array.hpp" \
  'throw std::out_of_range("array<>: index out of range");' \
  '__builtin_trap();'
patch_in_place "$SRC/boost/exception/exception.hpp" \
  'throw*this;' \
  '__builtin_trap();'
# Leela.cpp: empty catch handler is the program's normal termination path
# when the SGF file runs out of games.  Convert try/catch to plain branches.
patch_in_place "$SRC/Leela.cpp" \
  '    try {' \
  '    if (true) {'
patch_in_place "$SRC/Leela.cpp" \
  '    } catch (std::exception & e) {' \
  '    } else if (false) {'
# SGF parser/tree: `throw std::exception()` was caught by Leela.cpp's empty
# handler.  With the catch removed, exit(0) gives the same observable behavior.
for f in "$SRC/SGFParser.cpp" "$SRC/SGFTree.cpp"; do
  patch_in_place "$f" 'throw std::exception();' 'std::exit(0);'
done

# -fno-exceptions: lind-wasm libc++ does not yet support throw/try/catch.
# -include cstdlib: SGFParser.cpp / SGFTree.cpp use std::exit() after the
# throw → exit(0) patch above and don't include <cstdlib> directly.
CXXFLAGS="-O2 -std=c++14 -pthread -DSPEC -DNDEBUG -DSPEC_AUTO_SUPPRESS_OPENMP -include cstdlib"
if [[ "$TARGET" == "native" || "$TARGET" == "lfi" ]]; then
  LDFLAGS=""
else
  CXXFLAGS+=" -fno-exceptions"
  LDFLAGS="-Wl,--import-memory,--export-memory,--shared-memory,--max-memory=67108864"
  LDFLAGS+=" -Wl,--export=__stack_pointer,--export=__stack_low,--export=__tls_base"
fi

echo "[leela] compiling $BENCH..."

SRCS=($(find "$SRC" -maxdepth 1 -name '*.cpp' | sort))

OBJS=()
for src in "${SRCS[@]}"; do
  obj="$OUT/$(basename "${src%.cpp}").o"
  $CXX $CXXFLAGS -I"$SRC" -c "$src" -o "$obj"
  OBJS+=("$obj")
done

$CXX $LDFLAGS "${OBJS[@]}" -o "$OUT/leela_r${BIN_EXT}"

echo "[leela] built $OUT/leela_r${BIN_EXT}"

if [[ "$TARGET" == "wasm" ]]; then
  WASM_OPT="${WASM_OPT:-${LIND_WASM_ROOT}/tools/binaryen/bin/wasm-opt}"
  LIND_BOOT="${LIND_BOOT:-${LIND_WASM_ROOT}/build/lind-boot}"

  if [[ -x "$WASM_OPT" ]]; then
    echo "[leela] running wasm-opt..."
    "$WASM_OPT" --epoch-injection --asyncify --debuginfo -O2 \
      "$OUT/leela_r.wasm" -o "$OUT/leela_r.opt.wasm"
    echo "[leela] built $OUT/leela_r.opt.wasm"
  fi

  if [[ -x "$LIND_BOOT" ]]; then
    INPUT="$OUT/leela_r.opt.wasm"
    [[ -f "$INPUT" ]] || INPUT="$OUT/leela_r.wasm"
    echo "[leela] running lind-boot --precompile..."
    "$LIND_BOOT" --precompile "$INPUT" || true
    [[ -f "$OUT/leela_r.opt.cwasm" ]] && mv "$OUT/leela_r.opt.cwasm" "$OUT/leela_r.cwasm"
    [[ -f "$OUT/leela_r.cwasm" ]] && echo "[leela] built $OUT/leela_r.cwasm"
  fi
fi

echo "[leela] done"
