#!/usr/bin/env bash
# compile_perlbench.sh — build 500.perlbench_r for wasm32-unknown-wasi
# NOTE: Large benchmark (362 KLOC) — may hit WASI compat issues
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

BENCH="500.perlbench_r"
SRC="${SPEC_ROOT:-$REPO_ROOT}/benchspec/CPU/$BENCH/src"
OUT="$BUILD_DIR/bin/$BENCH/$PLAT_DIR"
mkdir -p "$OUT"

if [[ ! -d "$SRC" ]]; then
  echo "ERROR: source directory $SRC not found -- run 'make extract' first" >&2
  exit 1
fi

# Platform selection: wasm32 is ILP32 (→ IA32), native x86_64 (→ X64)
CFLAGS="-O2 -std=c99 -pthread -fno-strict-aliasing"
CFLAGS+=" -DSPEC -DSPEC_CPU -DNDEBUG -DSPEC_AUTO_SUPPRESS_OPENMP"
if [[ "$TARGET" == "native" || "$TARGET" == "lfi" ]]; then
  CFLAGS+=" -DSPEC_LINUX_X64 -DPERL_CORE"
else
  CFLAGS+=" -DSPEC_LINUX_IA32 -DPERL_CORE"
fi
CFLAGS+=" -DDOUBLE_SLASHES_SPECIAL=0"
CFLAGS+=" -D_LARGE_FILES -D_LARGEFILE_SOURCE -D_FILE_OFFSET_BITS=64"
CFLAGS+=" -DSPEC_NO_USE_STDIO_PTR -DSPEC_NO_USE_STDIO_BASE"
CFLAGS+=" -I$SRC -I$SRC/dist/IO -I$SRC/cpan/Time-HiRes"
CFLAGS+=" -I$SRC/cpan/HTML-Parser -I$SRC/ext/re -I$SRC/specrand"
if [[ "$TARGET" == "native" || "$TARGET" == "lfi" ]]; then
  LDFLAGS=""
else
  LDFLAGS="-Wl,--import-memory,--export-memory,--shared-memory,--max-memory=67108864"
  LDFLAGS+=" -Wl,--export=__stack_pointer,--export=__stack_low"
fi

echo "[perlbench] compiling $BENCH..."

# Source list from Spec/object.pm
SRCS=(
  av.c caretx.c deb.c doio.c doop.c dump.c globals.c gv.c hv.c keywords.c
  locale.c mg.c numeric.c op.c pad.c perl.c perlapi.c perlio.c perlmain.c
  perly.c pp.c pp_ctl.c pp_hot.c pp_pack.c pp_sort.c pp_sys.c
  regcomp.c regexec.c run.c scope.c sv.c taint.c toke.c
  universal.c utf8.c util.c reentr.c mro_core.c mathoms.c
  specrand/specrand.c
  dist/PathTools/Cwd.c
  dist/Data-Dumper/Dumper.c
  ext/Devel-Peek/Peek.c
  cpan/Digest-MD5/MD5.c
  cpan/Digest-SHA/SHA.c
  DynaLoader.c
  dist/IO/IO.c
  dist/IO/poll.c
  cpan/MIME-Base64/Base64.c
  Opcode.c
  dist/Storable/Storable.c
  ext/Sys-Hostname/Hostname.c
  cpan/Time-HiRes/HiRes.c
  ext/XS-Typemap/stdio.c
  ext/attributes/attributes.c
  cpan/HTML-Parser/Parser.c
  ext/mro/mro.c
  ext/re/re.c
  ext/re/re_comp.c
  ext/re/re_exec.c
  ext/arybase/arybase.c
  ext/PerlIO-scalar/scalar.c
  ext/PerlIO-via/via.c
  ext/File-Glob/bsd_glob.c
  ext/File-Glob/Glob.c
  ext/Hash-Util/Util.c
  ext/Hash-Util-FieldHash/FieldHash.c
  ext/Tie-Hash-NamedCapture/NamedCapture.c
  cpan/Scalar-List-Utils/ListUtil.c
)

OBJS=()
for src in "${SRCS[@]}"; do
  objname="$(echo "${src%.c}" | sed 's|/|_|g').o"
  obj="$OUT/$objname"
  $CC $CFLAGS -c "$SRC/$src" -o "$obj"
  OBJS+=("$obj")
done

$CC $LDFLAGS "${OBJS[@]}" -lm -o "$OUT/perlbench_r${BIN_EXT}"

echo "[perlbench] built $OUT/perlbench_r${BIN_EXT}"

if [[ "$TARGET" == "wasm" ]]; then
  WASM_OPT="${WASM_OPT:-${LIND_WASM_ROOT}/tools/binaryen/bin/wasm-opt}"
  LIND_BOOT="${LIND_BOOT:-${LIND_WASM_ROOT}/build/lind-boot}"

  if [[ -x "$WASM_OPT" ]]; then
    echo "[perlbench] running wasm-opt..."
    "$WASM_OPT" --epoch-injection --asyncify --debuginfo -O2 \
      "$OUT/perlbench_r.wasm" -o "$OUT/perlbench_r.opt.wasm"
    echo "[perlbench] built $OUT/perlbench_r.opt.wasm"
  fi

  if [[ -x "$LIND_BOOT" ]]; then
    INPUT="$OUT/perlbench_r.opt.wasm"
    [[ -f "$INPUT" ]] || INPUT="$OUT/perlbench_r.wasm"
    echo "[perlbench] running lind-boot --precompile..."
    "$LIND_BOOT" --precompile "$INPUT" || true
    [[ -f "$OUT/perlbench_r.opt.cwasm" ]] && mv "$OUT/perlbench_r.opt.cwasm" "$OUT/perlbench_r.cwasm"
    [[ -f "$OUT/perlbench_r.cwasm" ]] && echo "[perlbench] built $OUT/perlbench_r.cwasm"
  fi
fi

echo "[perlbench] done"
