#!/usr/bin/env bash
# deploy_spec.sh — Deploy binaries + test input data for SPEC benchmarks
#   Default (wasm):   → $LINDFS/spec/<bench>/
#   --native:         → $LIND_WASM_ROOT/native-spec/<bench>/
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$SCRIPT_DIR/.."
BUILD_DIR="$REPO_ROOT/build"
BENCH_SRC="$REPO_ROOT/benchspec/CPU"

LIND_WASM_ROOT="${LIND_WASM_ROOT:-$HOME/lind-wasm}"
LINDFS="$LIND_WASM_ROOT/lindfs"

MODE="wasm"

# -------- Helpers -------------------------------------------------------------

die()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "[deploy] $*"; }

# Copy a wasm binary — prefer .cwasm, then .opt.wasm, then .wasm
copy_wasm() {
  local bench="$1" exe="$2" dest="$3"
  local wasm_dir="$BUILD_DIR/bin/$bench/wasm32-wasi"
  if [[ -f "$wasm_dir/${exe}.cwasm" ]]; then
    cp "$wasm_dir/${exe}.cwasm" "$dest/${exe}.cwasm"
  elif [[ -f "$wasm_dir/${exe}.opt.wasm" ]]; then
    cp "$wasm_dir/${exe}.opt.wasm" "$dest/${exe}.wasm"
  elif [[ -f "$wasm_dir/${exe}.wasm" ]]; then
    cp "$wasm_dir/${exe}.wasm" "$dest/${exe}.wasm"
  else
    die "wasm binary not found: $wasm_dir/${exe}.wasm — run 'make ${bench%%.*}' first"
  fi
}

# Copy a native binary
copy_native() {
  local bench="$1" exe="$2" dest="$3"
  local native_dir="$BUILD_DIR/bin/$bench/${PLAT_DIR:-native-linux}"
  local p="$native_dir/$exe"
  [[ -x "$p" ]] || die "native binary not found: $p — run 'make ${bench%%.*}-native' first"
  cp "$p" "$dest/"
}

# Copy the appropriate binary based on MODE
copy_exe() {
  if [[ "$MODE" == "native" ]]; then
    copy_native "$@"
  else
    copy_wasm "$@"
  fi
}

# -------- Per-benchmark deploy functions --------------------------------------

deploy_lbm() {
  local dest="$SPEC_DIR/lbm_r"
  local data="$BENCH_SRC/519.lbm_r/data/test/input"
  mkdir -p "$dest"
  copy_exe "519.lbm_r" "lbm_r" "$dest"
  cp "$data/100_100_130_cf_a.of" "$dest/"
  info "lbm_r deployed"
}

deploy_mcf() {
  local dest="$SPEC_DIR/mcf_r"
  local data="$BENCH_SRC/505.mcf_r/data/test/input"
  mkdir -p "$dest"
  copy_exe "505.mcf_r" "mcf_r" "$dest"
  cp "$data/inp.in" "$dest/"
  info "mcf_r deployed"
}

deploy_nab() {
  local dest="$SPEC_DIR/nab_r"
  local data="$BENCH_SRC/544.nab_r/data/test/input"
  mkdir -p "$dest"
  copy_exe "544.nab_r" "nab_r" "$dest"
  cp -r "$data/hkrdenq" "$dest/"
  # nab builds filenames as argv[1]/argv[1].pdb — since lind-wasm inits CWD to /
  # and doesn't support relative paths, deploy data dir at lindfs root too
  if [[ "$MODE" == "wasm" ]]; then
    cp -r "$data/hkrdenq" "$LINDFS/"
  fi
  info "nab_r deployed"
}

deploy_xz() {
  local dest="$SPEC_DIR/xz_r"
  local data_test="$BENCH_SRC/557.xz_r/data/test/input"
  local data_all="$BENCH_SRC/557.xz_r/data/all/input"
  mkdir -p "$dest"
  copy_exe "557.xz_r" "xz_r" "$dest"
  cp "$data_all/cpu2006docs.tar.xz" "$dest/"
  cp "$data_test/control" "$dest/"
  info "xz_r deployed"
}

deploy_x264() {
  local dest="$SPEC_DIR/x264_r"
  local data="$BENCH_SRC/525.x264_r/data/test/input"
  mkdir -p "$dest"
  copy_exe "525.x264_r" "x264_r" "$dest"
  copy_exe "525.x264_r" "ldecod_r" "$dest"
  cp "$data/BuckBunny.264" "$dest/"
  cp "$data/control" "$dest/"
  info "x264_r deployed"
}

deploy_imagick() {
  local dest="$SPEC_DIR/imagick_r"
  local data="$BENCH_SRC/538.imagick_r/data/test/input"
  mkdir -p "$dest"
  copy_exe "538.imagick_r" "imagick_r" "$dest"
  cp "$data/test_input.tga" "$dest/"
  info "imagick_r deployed"
}

deploy_perlbench() {
  local dest="$SPEC_DIR/perlbench_r"
  local data_test="$BENCH_SRC/500.perlbench_r/data/test/input"
  local data_all="$BENCH_SRC/500.perlbench_r/data/all/input"
  mkdir -p "$dest"
  copy_exe "500.perlbench_r" "perlbench_r" "$dest"
  cp -r "$data_all/lib" "$dest/"
  cp "$data_test/makerand.pl" "$dest/"
  cp "$data_test/test.pl" "$dest/"
  cp "$data_test/TestInit.pm" "$dest/"
  cp -r "$data_test/t" "$dest/"
  cp -r "$data_test/regen" "$dest/"
  info "perlbench_r deployed"
}

deploy_gcc() {
  local dest="$SPEC_DIR/gcc_r"
  local data="$BENCH_SRC/502.gcc_r/data/test/input"
  mkdir -p "$dest"
  copy_exe "502.gcc_r" "cpugcc_r" "$dest"
  cp "$data/t1.c" "$dest/"
  info "gcc_r deployed"
}

# -------- C++ benchmarks ------------------------------------------------------

deploy_deepsjeng() {
  local dest="$SPEC_DIR/deepsjeng_r"
  local data="$BENCH_SRC/531.deepsjeng_r/data/test/input"
  mkdir -p "$dest"
  copy_exe "531.deepsjeng_r" "deepsjeng_r" "$dest"
  cp "$data/test.txt" "$dest/"
  info "deepsjeng_r deployed"
}

deploy_namd() {
  local dest="$SPEC_DIR/namd_r"
  local data_test="$BENCH_SRC/508.namd_r/data/test/input"
  local data_all="$BENCH_SRC/508.namd_r/data/all/input"
  mkdir -p "$dest"
  copy_exe "508.namd_r" "namd_r" "$dest"
  cp "$data_test/namd.in" "$dest/"
  cp "$data_all/apoa1.input" "$dest/"
  info "namd_r deployed"
}

deploy_leela() {
  local dest="$SPEC_DIR/leela_r"
  local data="$BENCH_SRC/541.leela_r/data/test/input"
  mkdir -p "$dest"
  copy_exe "541.leela_r" "leela_r" "$dest"
  cp "$data/test.sgf" "$dest/"
  info "leela_r deployed"
}

deploy_omnetpp() {
  local dest="$SPEC_DIR/omnetpp_r"
  local data="$BENCH_SRC/520.omnetpp_r/data/test/input"
  mkdir -p "$dest"
  copy_exe "520.omnetpp_r" "omnetpp_r" "$dest"
  cp "$data/control" "$dest/"
  cp "$data/omnetpp.ini" "$dest/"
  cp -r "$BENCH_SRC/520.omnetpp_r/data/all/input/ned" "$dest/"   # the NED model sources the run loads
  info "omnetpp_r deployed"
}

# -------- Main ----------------------------------------------------------------

ALL_BENCHMARKS="lbm mcf nab xz x264 imagick perlbench gcc deepsjeng namd leela omnetpp"

usage() {
  cat <<EOF
Usage: $0 [OPTIONS] [benchmark ...] | all

Options:
  --native    Deploy native Linux binaries (to native-spec/)
  -h, --help  Show this help

Benchmarks: $ALL_BENCHMARKS
EOF
  exit 1
}

targets=()
for arg in "$@"; do
  case "$arg" in
    --native)  MODE="native" ;;
    all)       targets=($ALL_BENCHMARKS) ;;
    lbm|mcf|nab|xz|x264|imagick|perlbench|gcc|deepsjeng|namd|leela|omnetpp) targets+=("$arg") ;;
    -h|--help) usage ;;
    *) die "unknown argument: $arg" ;;
  esac
done

[[ ${#targets[@]} -eq 0 ]] && targets=($ALL_BENCHMARKS)

if [[ "$MODE" == "native" ]]; then
  SPEC_DIR="${SPEC_DEPLOY:-$LIND_WASM_ROOT/native-spec}"
else
  SPEC_DIR="$LINDFS/spec"
  # lind needs /dev/null
  mkdir -p "$LINDFS/dev"
  [[ -e "$LINDFS/dev/null" ]] || touch "$LINDFS/dev/null"
fi

mkdir -p "$SPEC_DIR"
info "deploying to $SPEC_DIR ($MODE)"

for bench in "${targets[@]}"; do
  "deploy_${bench}"
done

info "done"
