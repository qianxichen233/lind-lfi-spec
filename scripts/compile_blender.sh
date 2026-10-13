#!/usr/bin/env bash
# compile_blender.sh — build 526.blender_r for wasm32-unknown-wasi
# BLOCKED: requires C++ standard library (libc++)
# NOTE: Extremely large benchmark (1577 KLOC, ~1005 source files)
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

BENCH="526.blender_r"
SRC="$REPO_ROOT/benchspec/CPU/$BENCH/src"
OUT="$BUILD_DIR/bin/$BENCH/$PLAT_DIR"
mkdir -p "$OUT"

if [[ ! -d "$SRC" ]]; then
  echo "ERROR: source directory $SRC not found -- run 'make extract' first" >&2
  exit 1
fi

# Include paths from Spec/object.pm (120+ directories)
INCLUDES=(
  -I"$SRC/specrand"
  -I"$SRC/blender/extern/binreloc/include"
  -I"$SRC/blender/extern/colamd/Include"
  -I"$SRC/blender/extern/glew/include"
  -I"$SRC/blender/extern/libmv"
  -I"$SRC/blender/extern/libmv/intern"
  -I"$SRC/blender/extern/Eigen3"
  -I"$SRC/blender/extern/rangetree"
  -I"$SRC/blender/extern/wcwidth"
  -I"$SRC/blender/intern"
  -I"$SRC/blender/intern/atomic"
  -I"$SRC/blender/intern/audaspace/intern"
  -I"$SRC/blender/intern/cycles/blender"
  -I"$SRC/blender/intern/elbeem/extern"
  -I"$SRC/blender/intern/ghost"
  -I"$SRC/blender/intern/ghost/intern"
  -I"$SRC/blender/intern/glew-mx"
  -I"$SRC/blender/intern/glew-mx/intern"
  -I"$SRC/blender/intern/guardedalloc"
  -I"$SRC/blender/intern/guardedalloc/intern"
  -I"$SRC/blender/intern/iksolver/extern"
  -I"$SRC/blender/intern/locale"
  -I"$SRC/blender/intern/memutil"
  -I"$SRC/blender/intern/mikktspace"
  -I"$SRC/blender/intern/opencolorio"
  -I"$SRC/blender/intern/raskter"
  -I"$SRC/blender/intern/smoke/extern"
  -I"$SRC/blender/intern/string"
  -I"$SRC/blender/intern/utfconv"
  -I"$SRC/blender/source/blender/blenfont"
  -I"$SRC/blender/source/blender/blenfont/intern"
  -I"$SRC/blender/source/blender/blenkernel"
  -I"$SRC/blender/source/blender/blenkernel/intern"
  -I"$SRC/blender/source/blender/blenlib"
  -I"$SRC/blender/source/blender/blenlib/intern"
  -I"$SRC/blender/source/blender/blenloader"
  -I"$SRC/blender/source/blender/blenloader/intern"
  -I"$SRC/blender/source/blender/bmesh"
  -I"$SRC/blender/source/blender/bmesh/intern"
  -I"$SRC/blender/source/blender/bmesh/tools"
  -I"$SRC/blender/source/blender/collada"
  -I"$SRC/blender/source/blender/compositor"
  -I"$SRC/blender/source/blender/editors/animation"
  -I"$SRC/blender/source/blender/editors/armature"
  -I"$SRC/blender/source/blender/editors/curve"
  -I"$SRC/blender/source/blender/editors/gpencil"
  -I"$SRC/blender/source/blender/editors/include"
  -I"$SRC/blender/source/blender/editors/interface"
  -I"$SRC/blender/source/blender/editors/io"
  -I"$SRC/blender/source/blender/editors/mask"
  -I"$SRC/blender/source/blender/editors/mesh"
  -I"$SRC/blender/source/blender/editors/metaball"
  -I"$SRC/blender/source/blender/editors/object"
  -I"$SRC/blender/source/blender/editors/physics"
  -I"$SRC/blender/source/blender/editors/render"
  -I"$SRC/blender/source/blender/editors/screen"
  -I"$SRC/blender/source/blender/editors/sculpt_paint"
  -I"$SRC/blender/source/blender/editors/sound"
  -I"$SRC/blender/source/blender/editors/space_action"
  -I"$SRC/blender/source/blender/editors/space_buttons"
  -I"$SRC/blender/source/blender/editors/space_clip"
  -I"$SRC/blender/source/blender/editors/space_console"
  -I"$SRC/blender/source/blender/editors/space_file"
  -I"$SRC/blender/source/blender/editors/space_graph"
  -I"$SRC/blender/source/blender/editors/space_image"
  -I"$SRC/blender/source/blender/editors/space_info"
  -I"$SRC/blender/source/blender/editors/space_logic"
  -I"$SRC/blender/source/blender/editors/space_nla"
  -I"$SRC/blender/source/blender/editors/space_node"
  -I"$SRC/blender/source/blender/editors/space_outliner"
  -I"$SRC/blender/source/blender/editors/space_script"
  -I"$SRC/blender/source/blender/editors/space_sequencer"
  -I"$SRC/blender/source/blender/editors/space_text"
  -I"$SRC/blender/source/blender/editors/space_time"
  -I"$SRC/blender/source/blender/editors/space_userpref"
  -I"$SRC/blender/source/blender/editors/space_view3d"
  -I"$SRC/blender/source/blender/editors/transform"
  -I"$SRC/blender/source/blender/editors/util"
  -I"$SRC/blender/source/blender/editors/uvedit"
  -I"$SRC/blender/source/blender/gpu"
  -I"$SRC/blender/source/blender/gpu/intern"
  -I"$SRC/blender/source/blender/ikplugin"
  -I"$SRC/blender/source/blender/ikplugin/intern"
  -I"$SRC/blender/source/blender/imbuf"
  -I"$SRC/blender/source/blender/imbuf/intern"
  -I"$SRC/blender/source/blender/imbuf/intern/openexr"
  -I"$SRC/blender/source/blender/makesdna"
  -I"$SRC/blender/source/blender/makesrna"
  -I"$SRC/blender/source/blender/makesrna/intern"
  -I"$SRC/blender/source/blender/modifiers"
  -I"$SRC/blender/source/blender/modifiers/intern"
  -I"$SRC/blender/source/blender/nodes"
  -I"$SRC/blender/source/blender/nodes/composite"
  -I"$SRC/blender/source/blender/nodes/intern"
  -I"$SRC/blender/source/blender/nodes/shader"
  -I"$SRC/blender/source/blender/nodes/texture"
  -I"$SRC/blender/source/blender/python"
  -I"$SRC/blender/source/blender/render/extern/include"
  -I"$SRC/blender/source/blender/render/intern/include"
  -I"$SRC/blender/source/blender/render/intern/raytrace"
  -I"$SRC/blender/source/blender/windowmanager"
  -I"$SRC/blender/source/gameengine/BlenderRoutines"
  -I"$SRC/blender_bin/source/blender/makesrna/intern"
  -I"$SRC/include"
  -I"$SRC/libpng"
  -I"$SRC/zlib"
)

# Defines from Spec/object.pm + simple-build script
DEFINES="-DSPEC -DSPEC_CPU -DNDEBUG -DSPEC_AUTO_SUPPRESS_OPENMP"
DEFINES+=" -DSPEC_AUTO_BYTEORDER=0x12345678"
DEFINES+=" -DGLEW_NO_ES -DGLEW_STATIC -DWITH_DNA_GHASH"
DEFINES+=" -DWITH_GL_PROFILE_COMPAT -DWITH_HEADLESS -DHAVE_UNSIGNED_CHAR"
DEFINES+=" -DSPEC_LINUX"
if [[ "$TARGET" == "native" || "$TARGET" == "lfi" ]]; then
  DEFINES+=" -DSPEC_LP64"
fi

COMMON_FLAGS="-O2 -funsigned-char ${DEFINES} ${INCLUDES[*]}"
CFLAGS="$COMMON_FLAGS -std=c99"
CXXFLAGS="$COMMON_FLAGS -std=c++14"
if [[ "$TARGET" == "native" || "$TARGET" == "lfi" ]]; then
  LDFLAGS=""
else
  LDFLAGS="-Wl,--import-memory,--export-memory,--shared-memory,--max-memory=134217728"
  LDFLAGS+=" -Wl,--export=__stack_pointer,--export=__stack_low"
fi

echo "[blender] compiling $BENCH (this will take a long time)..."

# Exact source list from Spec/object.pm (1039 files) — do NOT use find
SRCLIST="$REPO_ROOT/blender_r_sources.txt"
if [[ ! -r "$SRCLIST" ]]; then
  echo "ERROR: $SRCLIST not found" >&2
  exit 1
fi

OBJS=()
while IFS= read -r src; do
  [[ -z "$src" || "$src" == \#* ]] && continue
  fullpath="$SRC/$src"
  objname="$(echo "${src}" | sed 's|/|_|g; s|\.cpp$||; s|\.cc$||; s|\.c$||').o"
  obj="$OUT/$objname"
  case "$src" in
    *.cpp|*.cc) $CXX $CXXFLAGS -c "$fullpath" -o "$obj" ;;
    *.c)        $CC  $CFLAGS   -c "$fullpath" -o "$obj" ;;
  esac
  OBJS+=("$obj")
done < "$SRCLIST"

$CXX $LDFLAGS "${OBJS[@]}" -o "$OUT/blender_r${BIN_EXT}"

echo "[blender] built $OUT/blender_r${BIN_EXT}"

if [[ "$TARGET" == "wasm" ]]; then
  WASM_OPT="${WASM_OPT:-${LIND_WASM_ROOT}/tools/binaryen/bin/wasm-opt}"

  if [[ -x "$WASM_OPT" ]]; then
    echo "[blender] running wasm-opt..."
    "$WASM_OPT" --epoch-injection --asyncify --debuginfo -O2 \
      "$OUT/blender_r.wasm" -o "$OUT/blender_r.opt.wasm"
    echo "[blender] built $OUT/blender_r.opt.wasm"
  fi
fi

echo "[blender] done"
