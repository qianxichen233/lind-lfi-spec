#!/usr/bin/env bash
# compile_xalancbmk.sh — build 523.xalancbmk_r for wasm32-unknown-wasi
# BLOCKED: requires C++ standard library (libc++)
# NOTE: Very large benchmark (520 KLOC)
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

CLANGPP="${CLANG}++"
if [[ ! -x "$CLANGPP" ]]; then
  CLANGPP="$(dirname "$CLANG")/clang++"
fi
if [[ ! -x "$CLANGPP" ]]; then
  echo "ERROR: cannot find clang++" >&2
  exit 1
fi

TARGET="${TARGET:-wasm}"

if [[ "$TARGET" == "native" || "$TARGET" == "lfi" ]]; then
  CXX="$CLANGPP"
  PLAT_DIR="native-linux"
  BIN_EXT=""
else
  CXX="$CLANGPP --target=wasm32-unknown-wasi --sysroot=$SYSROOT"
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

BENCH="523.xalancbmk_r"
SRC="${SPEC_ROOT:-$REPO_ROOT}/benchspec/CPU/$BENCH/src"
OUT="$BUILD_DIR/bin/$BENCH/$PLAT_DIR"
mkdir -p "$OUT"

if [[ ! -d "$SRC" ]]; then
  echo "ERROR: source directory $SRC not found -- run 'make extract' first" >&2
  exit 1
fi

CXXFLAGS="-O2 -std=c++14 -pthread -DSPEC -DSPEC_CPU -DNDEBUG -DSPEC_AUTO_SUPPRESS_OPENMP"
CXXFLAGS+=" -DSPEC_LINUX -DAPP_NO_THREADS -DXALAN_INMEM_MSG_LOADER -DPROJ_XMLPARSER"
CXXFLAGS+=" -DPROJ_XMLUTIL -DPROJ_PARSERS -DPROJ_SAX4C -DPROJ_SAX2"
CXXFLAGS+=" -DPROJ_DOM -DPROJ_VALIDATORS"
CXXFLAGS+=" -DXML_USE_INMEM_MESSAGELOADER"
CXXFLAGS+=" -I$SRC -I$SRC/xercesc -I$SRC/xercesc/dom -I$SRC/xercesc/dom/impl"
CXXFLAGS+=" -I$SRC/xercesc/sax -I$SRC/xercesc/util/MsgLoaders/InMemory"
CXXFLAGS+=" -I$SRC/xercesc/util/Transcoders/Iconv -I$SRC/xalanc/include"
if [[ "$TARGET" == "native" || "$TARGET" == "lfi" ]]; then
  LDFLAGS=""
else
  LDFLAGS="-Wl,--import-memory,--export-memory,--shared-memory,--max-memory=67108864"
  LDFLAGS+=" -Wl,--export=__stack_pointer,--export=__stack_low"
fi

echo "[xalancbmk] compiling $BENCH (this may take a while)..."

OBJS=()
for src in $(find "$SRC" -name '*.cpp' -o -name '*.cc' | sort); do
  relpath="${src#$SRC/}"
  objname="$(echo "$relpath" | sed 's|/|_|g; s|\.cpp$||; s|\.cc$||').o"
  obj="$OUT/$objname"
  $CXX $CXXFLAGS -c "$src" -o "$obj"
  OBJS+=("$obj")
done

$CXX $LDFLAGS "${OBJS[@]}" -o "$OUT/xalancbmk_r${BIN_EXT}"

echo "[xalancbmk] built $OUT/xalancbmk_r${BIN_EXT}"

if [[ "$TARGET" == "wasm" ]]; then
  WASM_OPT="${WASM_OPT:-${LIND_WASM_ROOT}/tools/binaryen/bin/wasm-opt}"

  if [[ -x "$WASM_OPT" ]]; then
    echo "[xalancbmk] running wasm-opt..."
    "$WASM_OPT" --epoch-injection --asyncify --debuginfo -O2 \
      "$OUT/xalancbmk_r.wasm" -o "$OUT/xalancbmk_r.opt.wasm"
    echo "[xalancbmk] built $OUT/xalancbmk_r.opt.wasm"
  fi
fi

echo "[xalancbmk] done"
