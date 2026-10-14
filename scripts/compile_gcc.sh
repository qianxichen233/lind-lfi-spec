#!/usr/bin/env bash
# compile_gcc.sh — build 502.gcc_r for wasm32-unknown-wasi
# NOTE: Very large benchmark (1304 KLOC, 388 .c files)
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

BENCH="502.gcc_r"
SRC="${SPEC_ROOT:-$REPO_ROOT}/benchspec/CPU/$BENCH/src"
# LFI: a copy of the source with set_cfg_hooks taking a pointer instead of a ~300-byte struct by
# value: the LFI v0.12 compiler copies such an argument with an unsandboxed "rep movsq" that the
# verifier rejects. Same behaviour; the edit is made here, to a private copy, at build time.
if [[ "$TARGET" == "lfi" ]]; then
  ORIG="${SPEC_ROOT:-$REPO_ROOT}/benchspec/CPU/$BENCH/src"
  SRC="$BUILD_DIR/src-gcc-lfi"
  if [[ -d "$ORIG" ]]; then
    rm -rf "$SRC"; cp -r "$ORIG" "$SRC"
    python3 - "$SRC" <<'PY'
import sys
d = sys.argv[1]
def edit(name, pairs):
    p = d + "/" + name
    s = open(p, encoding="latin-1").read()
    for old, new in pairs:
        if s.count(old) != 1:
            sys.exit(f"compile_gcc: expected exactly one occurrence of {old!r} in {name}")
        s = s.replace(old, new)
    open(p, "w", encoding="latin-1").write(s)
edit("cfghooks.c", [
    ("set_cfg_hooks (struct cfg_hooks new_cfg_hooks)", "set_cfg_hooks_p (const struct cfg_hooks *new_cfg_hooks)"),
    ("*cfg_hooks = new_cfg_hooks;", "*cfg_hooks = *new_cfg_hooks;"),
])
edit("cfghooks.h", [
    ("extern void set_cfg_hooks (struct cfg_hooks);",
     "extern void set_cfg_hooks_p (const struct cfg_hooks *);\n#define set_cfg_hooks(h) set_cfg_hooks_p (&(h))"),
])
PY
  fi
fi
OUT="$BUILD_DIR/bin/$BENCH/$PLAT_DIR"
mkdir -p "$OUT"

if [[ ! -d "$SRC" ]]; then
  echo "ERROR: source directory $SRC not found -- run 'make extract' first" >&2
  exit 1
fi

CFLAGS="-O2 -std=c99 -fgnu89-inline -pthread -fno-strict-aliasing"
CFLAGS+=" -DSPEC -DSPEC_CPU -DNDEBUG -DSPEC_AUTO_SUPPRESS_OPENMP"
CFLAGS+=" -DSPEC_502 -DIN_GCC -DHAVE_CONFIG_H"
[[ "$TARGET" == "native" || "$TARGET" == "lfi" ]] && CFLAGS+=" -DSPEC_LP64"
CFLAGS+=" -I$SRC -I$SRC/include -I$SRC/spec_qsort"
if [[ "$TARGET" == "native" || "$TARGET" == "lfi" ]]; then
  LDFLAGS=""
else
  LDFLAGS="-Wl,--import-memory,--export-memory,--shared-memory,--max-memory=67108864"
  LDFLAGS+=" -Wl,--export=__stack_pointer,--export=__stack_low"
fi

echo "[gcc] compiling $BENCH (this may take a while)..."

# Source list from Spec/object.pm (388 files — do NOT glob, some .c files
# like gcov-io.c are #included by other files and must not be compiled standalone)
SRCS=(
    main.c cc1-checksum.c alias.c alloca.c alloc-pool.c argv.c attribs.c
    auto-inc-dec.c bb-reorder.c bid2dpd_dpd2bid.c bitmap.c bt-load.c
    c-lang.c c-errors.c c-lex.c c-pragma.c c-decl.c c-typeck.c c-convert.c
    c-aux-info.c c-common.c c-opts.c c-format.c c-semantics.c c-ppoutput.c
    c-objc-common.c c-dump.c c-parser.c c-gimplify.c c-pretty-print.c c-omp.c
    caller-save.c calls.c cfg.c cfganal.c cfgbuild.c cfgcleanup.c cfgexpand.c
    cfghooks.c cfglayout.c cfgloop.c cfgloopanal.c cfgloopmanip.c cfgrtl.c
    cgraph.c cgraphbuild.c cgraphunit.c combine.c combine-stack-adj.c concat.c
    convert.c coverage.c cp-demangle.c cp-demint.c cplus-dem.c
    cpp_directives.c cpp_lex.c cpp_errors.c cpp_expr.c cpp_charset.c
    cpp_macro.c cpp_traditional.c cpp_line-map.c cpp_symtab.c
    cpp_identifiers.c cpp_mkdeps.c cpp_pch.c cpp_directives-only.c
    crc32.c cse.c cselib.c dbxout.c dbgcnt.c dce.c ddg.c debug.c
    decContext.c decimal128.c decimal32.c decimal64.c decNumber.c
    df-byte-scan.c df-core.c df-problems.c df-scan.c dfp.c diagnostic.c
    dojump.c dominance.c domwalk.c double-int.c dse.c dwarf2asm.c dwarf2out.c
    dyn-string.c ebitmap.c emit-rtl.c et-forest.c except.c explow.c expmed.c
    expr.c fdmatch.c fibheap.c filename_cmp.c final.c fixed-value.c
    floatformat.c fold-const.c fopen_unlocked.c function.c fwprop.c gcse.c
    genrtl.c getopt1.c getopt.c getpwd.c getruntime.c ggc-common.c ggc-page.c
    gimple.c gimple-iterator.c gimple-low.c gimple-pretty-print.c gimplify.c
    graph.c graphds.c graphite.c graphite-blocking.c
    graphite-clast-to-gimple.c graphite-dependences.c graphite-interchange.c
    graphite-poly.c graphite-ppl.c graphite-scop-detection.c
    graphite-sese-to-poly.c gtype-desc.c haifa-sched.c hashtab.c hex.c
    hooks.c host-ieee128.c host-ieee32.c host-ieee64.c host-linux.c
    i386.c i386-c.c ifcvt.c incpath.c init-regs.c insn-attrtab.c
    insn-automata.c insn-emit.c insn-extract.c insn-modes.c insn-opinit.c
    insn-output.c insn-peep.c insn-preds.c insn-recog.c integrate.c
    ipa-cp.c ipa-inline.c ipa-prop.c ipa-pure-const.c ipa-reference.c
    ipa-struct-reorg.c ipa-type-escape.c ipa-utils.c ipa.c
    ira.c ira-build.c ira-costs.c ira-conflicts.c ira-color.c ira-emit.c
    ira-lives.c jump.c lambda-code.c lambda-mat.c lambda-trans.c langhooks.c
    lbasename.c lcm.c lists.c loop-doloop.c loop-init.c loop-invariant.c
    loop-iv.c loop-unroll.c loop-unswitch.c lower-subreg.c lrealpath.c
    lto-cgraph.c lto-streamer-in.c lto-streamer-out.c lto-section-in.c
    lto-section-out.c lto-symtab.c lto-opts.c lto-streamer.c lto-wpa-fixup.c
    make-relative-prefix.c make-temp-file.c partition.c matrix-reorg.c mcf.c
    md5.c mkstemps.c mode-switching.c modulo-sched.c objalloc.c obstack.c
    omega.c omp-low.c optabs.c options.c opts-common.c opts.c params.c
    passes.c physmem.c plugin.c pointer-set.c postreload-gcse.c postreload.c
    predict.c pretty-print.c print-rtl.c print-tree.c profile.c recog.c
    reg-stack.c regcprop.c regex.c reginfo.c regmove.c regrename.c regstat.c
    reload.c reload1.c reorg.c resource.c rtl-error.c rtl.c rtlanal.c
    rtlhooks.c safe-ctype.c sbitmap.c sched-deps.c sched-ebb.c sched-rgn.c
    sched-vis.c sdbout.c sel-sched-ir.c sel-sched-dump.c sel-sched.c sese.c
    sha1.c simplify-rtx.c sort.c spaces.c sparseset.c splay-tree.c sreal.c
    stack-ptr-mod.c statistics.c stmt.c stor-layout.c store-motion.c
    stringpool.c strsignal.c stub-objc.c targhooks.c timevar.c tracer.c
    tree-affine.c tree-call-cdce.c tree-cfg.c tree-cfgcleanup.c tree-chrec.c
    tree-complex.c tree-data-ref.c tree-dfa.c tree-dump.c tree-eh.c
    tree-if-conv.c tree-inline.c tree-into-ssa.c tree-iterator.c
    tree-loop-distribution.c tree-loop-linear.c tree-mudflap.c tree-nested.c
    tree-nrv.c tree-object-size.c tree-optimize.c tree-outof-ssa.c
    tree-parloops.c tree-phinodes.c tree-predcom.c tree-pretty-print.c
    tree-profile.c tree-scalar-evolution.c tree-sra.c tree-switch-conversion.c
    tree-ssa-address.c tree-ssa-alias.c tree-ssa-ccp.c tree-ssa-coalesce.c
    tree-ssa-copy.c tree-ssa-copyrename.c tree-ssa-dce.c tree-ssa-dom.c
    tree-ssa-dse.c tree-ssa-forwprop.c tree-ssa-ifcombine.c tree-ssa-live.c
    tree-ssa-loop-ch.c tree-ssa-loop-im.c tree-ssa-loop-ivcanon.c
    tree-ssa-loop-ivopts.c tree-ssa-loop-manip.c tree-ssa-loop-niter.c
    tree-ssa-loop-prefetch.c tree-ssa-loop-unswitch.c tree-ssa-loop.c
    tree-ssa-math-opts.c tree-ssa-operands.c tree-ssa-phiopt.c
    tree-ssa-phiprop.c tree-ssa-pre.c tree-ssa-propagate.c tree-ssa-reassoc.c
    tree-ssa-sccvn.c tree-ssa-sink.c tree-ssa-structalias.c tree-ssa-ter.c
    tree-ssa-threadedge.c tree-ssa-threadupdate.c tree-ssa-uncprop.c
    tree-ssa.c tree-ssanames.c tree-stdarg.c tree-tailcall.c
    tree-vect-generic.c tree-vect-patterns.c tree-vect-data-refs.c
    tree-vect-stmts.c tree-vect-loop.c tree-vect-loop-manip.c tree-vect-slp.c
    tree-vectorizer.c tree-vrp.c tree.c unlink-if-ordinary.c value-prof.c
    var-tracking.c varpool.c varasm.c varray.c vec.c vmsdbgout.c web.c
    xatexit.c xcoffout.c xexit.c xmalloc.c xmemdup.c xstrdup.c xstrerror.c
    xstrndup.c c-cppbuiltin.c c-pch.c cpp_files.c cpp_init.c cppdefault.c
    intl.c prefix.c strerror.c toplev.c vasprintf.c version.c builtins.c
    real.c mini-gmp.c
    spec_qsort/spec_qsort.c
)

OBJS=()
for src in "${SRCS[@]}"; do
  objname="$(echo "${src%.c}" | sed 's|/|_|g').o"
  obj="$OUT/$objname"
  $CC $CFLAGS -c "$SRC/$src" -o "$obj"
  OBJS+=("$obj")
done

$CC $LDFLAGS "${OBJS[@]}" -lm -o "$OUT/cpugcc_r${BIN_EXT}"

echo "[gcc] built $OUT/cpugcc_r${BIN_EXT}"

if [[ "$TARGET" == "wasm" ]]; then
  WASM_OPT="${WASM_OPT:-${LIND_WASM_ROOT}/tools/binaryen/bin/wasm-opt}"
  LIND_BOOT="${LIND_BOOT:-${LIND_WASM_ROOT}/build/lind-boot}"

  if [[ -x "$WASM_OPT" ]]; then
    echo "[gcc] running wasm-opt..."
    "$WASM_OPT" --epoch-injection --asyncify --debuginfo -O2 \
      "$OUT/cpugcc_r.wasm" -o "$OUT/cpugcc_r.opt.wasm"
    echo "[gcc] built $OUT/cpugcc_r.opt.wasm"
  fi

  if [[ -x "$LIND_BOOT" ]]; then
    INPUT="$OUT/cpugcc_r.opt.wasm"
    [[ -f "$INPUT" ]] || INPUT="$OUT/cpugcc_r.wasm"
    echo "[gcc] running lind-boot --precompile..."
    "$LIND_BOOT" --precompile "$INPUT" || true
    [[ -f "$OUT/cpugcc_r.opt.cwasm" ]] && mv "$OUT/cpugcc_r.opt.cwasm" "$OUT/cpugcc_r.cwasm"
    [[ -f "$OUT/cpugcc_r.cwasm" ]] && echo "[gcc] built $OUT/cpugcc_r.cwasm"
  fi
fi

echo "[gcc] done"
