#!/usr/bin/env bash
# compile_povray.sh — build 511.povray_r for wasm32-unknown-wasi
# BLOCKED: requires C++ standard library (libc++)
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
  CC="$CLANG"
  PLAT_DIR="native-linux"
  BIN_EXT=""
else
  CXX="$CLANGPP --target=wasm32-unknown-wasi --sysroot=$SYSROOT"
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

BENCH="511.povray_r"
SRC="${SPEC_ROOT:-$REPO_ROOT}/benchspec/CPU/$BENCH/src"
OUT="$BUILD_DIR/bin/$BENCH/$PLAT_DIR"
mkdir -p "$OUT"

if [[ ! -d "$SRC" ]]; then
  echo "ERROR: source directory $SRC not found -- run 'make extract' first" >&2
  exit 1
fi

COMMON_FLAGS="-O2 -pthread -DSPEC -DSPEC_CPU -DNDEBUG -DSPEC_AUTO_SUPPRESS_OPENMP"
COMMON_FLAGS+=" -I$SRC/frontend -I$SRC/base -I$SRC -I$SRC/spec_qsort"
CFLAGS="$COMMON_FLAGS -std=c99"
CXXFLAGS="$COMMON_FLAGS -std=c++14"
if [[ "$TARGET" == "native" || "$TARGET" == "lfi" ]]; then
  COMMON_FLAGS+=" -DSPEC_LP64"
  CFLAGS+=" -DSPEC_LP64"
  CXXFLAGS+=" -DSPEC_LP64"
  LDFLAGS=""
else
  LDFLAGS="-Wl,--import-memory,--export-memory,--shared-memory,--max-memory=67108864"
  LDFLAGS+=" -Wl,--export=__stack_pointer,--export=__stack_low"
fi

echo "[povray] compiling $BENCH..."

# Source lists from simple-build-povray_r-511.sh
CXX_SRCS=(
  atmosph.cpp bbox.cpp bcyl.cpp benchmark.cpp bezier.cpp blob.cpp boxes.cpp
  bsphere.cpp camera.cpp chi2.cpp colour.cpp colutils.cpp cones.cpp csg.cpp
  discs.cpp express.cpp fncode.cpp fnintern.cpp fnpovfpu.cpp fnsyntax.cpp
  fpmetric.cpp fractal.cpp function.cpp hcmplx.cpp hfield.cpp histogra.cpp
  iff.cpp image.cpp interior.cpp isosurf.cpp lathe.cpp lbuffer.cpp
  lightgrp.cpp lighting.cpp mathutil.cpp matrices.cpp media.cpp mesh.cpp
  normal.cpp objects.cpp octree.cpp optout.cpp parse.cpp parsestr.cpp
  parstxtr.cpp pattern.cpp pgm.cpp photons.cpp pigment.cpp planes.cpp
  point.cpp poly.cpp polygon.cpp polysolv.cpp povmsend.cpp povmsrec.cpp
  povray.cpp pov_mem.cpp pov_util.cpp ppm.cpp prism.cpp quadrics.cpp
  quatern.cpp radiosit.cpp rad_data.cpp ray.cpp rendctrl.cpp render.cpp
  renderio.cpp reswords.cpp sor.cpp spheres.cpp sphsweep.cpp splines.cpp
  statspov.cpp super.cpp targa.cpp texture.cpp tokenize.cpp torus.cpp
  triangle.cpp truetype.cpp txttest.cpp userdisp.cpp userio.cpp vbuffer.cpp
  vlbuffer.cpp warps.cpp
  base/fileinputoutput.cpp base/povms.cpp base/povmscpp.cpp
  base/processoptions.cpp base/stringutilities.cpp base/textstream.cpp
  base/textstreambuffer.cpp
  frontend/defaultplatformbase.cpp frontend/defaultrenderfrontend.cpp
  frontend/messageoutput.cpp frontend/processrenderoptions.cpp
  frontend/renderfrontend.cpp
)
C_SRCS=(
  spec_qsort/spec_qsort.c
)

mkdir -p "$OUT/base" "$OUT/frontend" "$OUT/spec_qsort"

OBJS=()

# C++ files
for src in "${CXX_SRCS[@]}"; do
  objname="$(echo "${src%.cpp}" | sed 's|/|_|g').o"
  obj="$OUT/$objname"
  $CXX $CXXFLAGS -c "$SRC/$src" -o "$obj"
  OBJS+=("$obj")
done

# C files
for src in "${C_SRCS[@]}"; do
  objname="$(echo "${src%.c}" | sed 's|/|_|g').o"
  obj="$OUT/$objname"
  $CC $CFLAGS -c "$SRC/$src" -o "$obj"
  OBJS+=("$obj")
done

$CXX $LDFLAGS "${OBJS[@]}" -lm -o "$OUT/povray_r${BIN_EXT}"

echo "[povray] built $OUT/povray_r${BIN_EXT}"

if [[ "$TARGET" == "wasm" ]]; then
  WASM_OPT="${WASM_OPT:-${LIND_WASM_ROOT}/tools/binaryen/bin/wasm-opt}"

  if [[ -x "$WASM_OPT" ]]; then
    echo "[povray] running wasm-opt..."
    "$WASM_OPT" --epoch-injection --asyncify --debuginfo -O2 \
      "$OUT/povray_r.wasm" -o "$OUT/povray_r.opt.wasm"
    echo "[povray] built $OUT/povray_r.opt.wasm"
  fi
fi

echo "[povray] done"
