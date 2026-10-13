#!/usr/bin/env bash
# run_spec.sh — Run SPEC CPU2017 C benchmarks in Lind or natively
#   Default (wasm):   runs from $LINDFS via lind-boot, chroot-absolute paths
#   --native:         runs from $LIND_WASM_ROOT/native-spec/, relative paths
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$SCRIPT_DIR/.."
BUILD_DIR="$REPO_ROOT/build"

LIND_WASM_ROOT="${LIND_WASM_ROOT:-$HOME/lind-wasm}"
LINDFS="$LIND_WASM_ROOT/lindfs"
LIND_BOOT="$LIND_WASM_ROOT/build/lind-boot"

MODE="wasm"   # wasm or native

# -------- Helpers -------------------------------------------------------------

die()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "[run] $*"; }

# Return the data directory prefix for file arguments.
# wasm:   chroot-absolute (e.g., /spec/lbm_r)
# native: relative "."    (CWD is the data dir)
data_prefix() {
  local bench_dir="$1"
  if [[ "$MODE" == "native" ]]; then
    echo "."
  else
    echo "/spec/$bench_dir"
  fi
}

# Run a single command under lind-boot (wasm) or directly (native), with timing.
# Stdout → <tag>.out, stderr → <tag>.err in the work directory.
# Usage: run_cmd <work_dir> <tag> <exe> [args...]
run_cmd() {
  local work_dir="$1"; shift
  local tag="$1"; shift
  local exe="$1"; shift
  local out_file="$work_dir/${tag}.out"
  local err_file="$work_dir/${tag}.err"

  local rc=0
  if [[ "$MODE" == "native" ]]; then
    pushd "$work_dir" > /dev/null
    info "  \$ $(basename "$exe") $*"
    info "  stdout → ${tag}.out  stderr → ${tag}.err"
    local t0
    t0=$(date +%s%N)
    ${RUNNER:-} "$exe" "$@" > "$out_file" 2> "$err_file" || rc=$?
    local t1
    t1=$(date +%s%N)
    popd > /dev/null
  else
    # lind-boot chroots to CWD — must run from $LINDFS
    pushd "$LINDFS" > /dev/null
    info "  \$ lind-boot $(basename "$exe") $*"
    info "  stdout → ${tag}.out  stderr → ${tag}.err"
    local t0
    t0=$(date +%s%N)
    sudo -E "$LIND_BOOT" ${RUNNER:-} "$exe" "$@" > "$out_file" 2> "$err_file" || rc=$?
    local t1
    t1=$(date +%s%N)
    popd > /dev/null
  fi

  local elapsed_ms=$(( (t1 - t0) / 1000000 ))
  if [[ $rc -ne 0 ]]; then
    info "  EXIT $rc  elapsed: ${elapsed_ms} ms"
  else
    info "  elapsed: ${elapsed_ms} ms"
  fi
}

# Resolve the executable path for a benchmark.
# wasm:   chroot-absolute path (lind-boot chroots before loading)
# native: host-absolute path into native-spec/
resolve_exe() {
  local bench_dir="$1" full_bench="$2" exe_name="$3"
  if [[ "$MODE" == "native" ]]; then
    local p="$NATIVE_SPEC/$bench_dir/$exe_name"
    [[ -x "$p" ]] || die "native binary not found: $p — run './deploy_spec.sh --native ${bench_dir%_r}' first"
    echo "$p"
  else
    # prefer .cwasm (precompiled), fall back to .wasm
    if [[ -f "$WASM_SPEC/$bench_dir/${exe_name}.cwasm" ]]; then
      echo "/spec/$bench_dir/${exe_name}.cwasm"
    elif [[ -f "$WASM_SPEC/$bench_dir/${exe_name}.wasm" ]]; then
      echo "/spec/$bench_dir/${exe_name}.wasm"
    else
      die "wasm binary not found in $WASM_SPEC/$bench_dir/ — run './deploy_spec.sh ${bench_dir%_r}' first"
    fi
  fi
}

# -------- Per-benchmark run functions -----------------------------------------

run_lbm() {
  info "=== 519.lbm_r ==="
  local work="$WORK_BASE/lbm_r"
  local d; d=$(data_prefix "lbm_r")
  local exe; exe=$(resolve_exe "lbm_r" "519.lbm_r" "lbm_r")
  run_cmd "$work" "lbm_r" "$exe" 20 "$d/reference.dat" 0 1 "$d/100_100_130_cf_a.of"
}

run_mcf() {
  info "=== 505.mcf_r ==="
  local work="$WORK_BASE/mcf_r"
  local d; d=$(data_prefix "mcf_r")
  local exe; exe=$(resolve_exe "mcf_r" "505.mcf_r" "mcf_r")
  run_cmd "$work" "mcf_r" "$exe" "$d/inp.in"
}

run_nab() {
  info "=== 544.nab_r ==="
  local work="$WORK_BASE/nab_r"
  local d; d=$(data_prefix "nab_r")
  local exe; exe=$(resolve_exe "nab_r" "544.nab_r" "nab_r")
  # nab builds filenames as argv[1]/argv[1].pdb so argv[1] must be a bare name;
  # data is deployed at $LINDFS/hkrdenq/ (wasm) or $work/hkrdenq/ (native)
  run_cmd "$work" "nab_r" "$exe" hkrdenq 1930344093 1000
}

run_gcc() {
  info "=== 502.gcc_r ==="
  local work="$WORK_BASE/gcc_r"
  local d; d=$(data_prefix "gcc_r")
  local exe; exe=$(resolve_exe "gcc_r" "502.gcc_r" "cpugcc_r")
  run_cmd "$work" "cpugcc_r" "$exe" "$d/t1.c" -O3 -finline-limit=50000 -o "$d/t1.opts-O3_-finline-limit_50000.s"
}

run_xz() {
  info "=== 557.xz_r ==="
  local work="$WORK_BASE/xz_r"
  local d; d=$(data_prefix "xz_r")
  local exe; exe=$(resolve_exe "xz_r" "557.xz_r" "xz_r")
  local control="$work/control"
  [[ -f "$control" ]] || die "control file not found: $control"

  local invocation=0
  while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
    read -r name size sum min max rest <<< "$line"
    local levels=()
    for token in $rest; do
      [[ "$token" =~ ^[0-9]e?$ ]] && levels+=("$token")
    done
    [[ ${#levels[@]} -eq 0 ]] && continue
    [[ "$size" -le 0 ]] 2>/dev/null && continue
    [[ -z "$sum" ]] && continue

    invocation=$((invocation + 1))
    local leveltext; leveltext=$(IFS=_; echo "${levels[*]}")
    info "  invocation $invocation: ${name}.xz level=${levels[*]}"
    run_cmd "$work" "${name}-${size}-${leveltext}" "$exe" "$d/${name}.xz" "$size" "$sum" "$min" "$max" "${levels[@]}"
  done < "$control"
}

run_x264() {
  info "=== 525.x264_r ==="
  local work="$WORK_BASE/x264_r"
  local d; d=$(data_prefix "x264_r")
  local control="$work/control"
  [[ -f "$control" ]] || die "control file not found: $control"

  local ctrl_line
  ctrl_line=$(grep -v '^\s*#' "$control" | grep -v '^\s*$' | head -1)
  read -r org_x264 yuv_output yuv_md5 new_x264 size seek_val frames frames2 yuvdump rest <<< "$ctrl_line"

  # Phase 1: decode h.264 → raw YUV
  info "  phase 1: ldecod"
  local ldecod_exe; ldecod_exe=$(resolve_exe "x264_r" "525.x264_r" "ldecod_r")
  run_cmd "$work" "inputgen_ldecod_r_x264" "$ldecod_exe" -i "$d/$org_x264" -o "$d/$yuv_output"

  # Phase 2: encode
  local x264_exe; x264_exe=$(resolve_exe "x264_r" "525.x264_r" "x264_r")

  local dumpyuv_args=()
  [[ -n "$yuvdump" ]] && dumpyuv_args=(--dumpyuv "$yuvdump")

  if [[ "$frames2" -gt 0 ]] 2>/dev/null; then
    local filebase
    filebase=$(printf "run_%0*d-%d_x264_r_x264" "$(( ${#frames} ))" 0 "$frames")

    info "  phase 2: x264 pass 1 (frames 0-$frames)"
    run_cmd "$work" "${filebase}_pass1" "$x264_exe" \
      --pass 1 --stats "$d/x264_stats.log" --bitrate 1000 \
      --frames "$frames" -o "$d/$new_x264" "$d/$yuv_output" "$size"

    info "  phase 2: x264 pass 2 (frames 0-$frames)"
    run_cmd "$work" "${filebase}_pass2" "$x264_exe" \
      --pass 2 --stats "$d/x264_stats.log" --bitrate 1000 \
      "${dumpyuv_args[@]}" \
      --frames "$frames" -o "$d/$new_x264" "$d/$yuv_output" "$size"

    filebase=$(printf "run_%0*d-%d_x264_r_x264" "$(( ${#frames2} ))" "$seek_val" "$frames2")
    info "  phase 2: x264 single-pass (seek=$seek_val frames=$frames2)"
    run_cmd "$work" "$filebase" "$x264_exe" \
      --seek "$seek_val" "${dumpyuv_args[@]}" \
      --frames "$frames2" -o "$d/$new_x264" "$d/$yuv_output" "$size"
  else
    local filebase
    filebase=$(printf "run_%0*d-%d_x264_r_x264" "$(( ${#frames} ))" 0 "$frames")

    info "  phase 2: x264 single-pass (frames=$frames)"
    run_cmd "$work" "$filebase" "$x264_exe" \
      "${dumpyuv_args[@]}" \
      --frames "$frames" -o "$d/$new_x264" "$d/$yuv_output" "$size"
  fi
}

run_imagick() {
  info "=== 538.imagick_r ==="
  local work="$WORK_BASE/imagick_r"
  local d; d=$(data_prefix "imagick_r")
  local exe; exe=$(resolve_exe "imagick_r" "538.imagick_r" "imagick_r")
  run_cmd "$work" "test_convert" "$exe" \
    -limit disk 0 "$d/test_input.tga" -shear 25 -resize 640x480 \
    -negate -alpha Off "$d/test_output.tga"
}

run_perlbench() {
  info "=== 500.perlbench_r ==="
  local work="$WORK_BASE/perlbench_r"
  local d; d=$(data_prefix "perlbench_r")
  local exe; exe=$(resolve_exe "perlbench_r" "500.perlbench_r" "perlbench_r")

  info "  test 1: makerand.pl"
  run_cmd "$work" "makerand" "$exe" "-I$d" "-I$d/lib" "$d/makerand.pl"

  info "  test 2: test.pl"
  run_cmd "$work" "test" "$exe" "-I$d" "-I$d/lib" "$d/test.pl"
}

# -------- C++ benchmarks ------------------------------------------------------

run_deepsjeng() {
  info "=== 531.deepsjeng_r ==="
  local work="$WORK_BASE/deepsjeng_r"
  local d; d=$(data_prefix "deepsjeng_r")
  local exe; exe=$(resolve_exe "deepsjeng_r" "531.deepsjeng_r" "deepsjeng_r")
  run_cmd "$work" "deepsjeng_r" "$exe" "$d/test.txt"
}

run_namd() {
  info "=== 508.namd_r ==="
  local work="$WORK_BASE/namd_r"
  local d; d=$(data_prefix "namd_r")
  local exe; exe=$(resolve_exe "namd_r" "508.namd_r" "namd_r")
  # namd reads its argument list from namd.in (test workload: 1 iteration)
  run_cmd "$work" "namd_r" "$exe" \
    --input "$d/apoa1.input" --iterations 1 --output "$d/apoa1.test.output"
}

run_leela() {
  info "=== 541.leela_r ==="
  local work="$WORK_BASE/leela_r"
  local d; d=$(data_prefix "leela_r")
  local exe; exe=$(resolve_exe "leela_r" "541.leela_r" "leela_r")
  run_cmd "$work" "leela_r" "$exe" "$d/test.sgf"
}

run_omnetpp() {
  info "=== 520.omnetpp_r ==="
  local work="$WORK_BASE/omnetpp_r"
  local d; d=$(data_prefix "omnetpp_r")
  local exe; exe=$(resolve_exe "omnetpp_r" "520.omnetpp_r" "omnetpp_r")
  local control="$work/control"
  [[ -f "$control" ]] || die "control file not found: $control"

  while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
    read -r configname runnumber <<< "$line"
    [[ -z "$configname" ]] && continue
    info "  config=$configname run=$runnumber"
    # omnetpp.ini lives next to the binary in the work dir
    pushd "$work" > /dev/null
    run_cmd "$work" "omnetpp.${configname}-${runnumber}" "$exe" \
      -c "$configname" -r "$runnumber"
    popd > /dev/null
  done < "$control"
}

# -------- Main ----------------------------------------------------------------

ALL_BENCHMARKS="lbm mcf nab gcc xz x264 imagick perlbench deepsjeng namd leela omnetpp"

usage() {
  cat <<EOF
Usage: $0 [OPTIONS] <benchmark|all> [benchmark...]

Options:
  --native    Run native Linux binaries (from native-spec/)
  -h, --help  Show this help

Benchmarks: $ALL_BENCHMARKS

Examples:
  $0 lbm              # run lbm in Lind
  $0 --native lbm     # run native lbm for comparison
  $0 all              # run all 8 C benchmarks in Lind
EOF
  exit 1
}

targets=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --native)  MODE="native"; shift ;;
    -h|--help) usage ;;
    all)       targets=($ALL_BENCHMARKS); shift ;;
    lbm|mcf|nab|gcc|xz|x264|imagick|perlbench|deepsjeng|namd|leela|omnetpp) targets+=("$1"); shift ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ ${#targets[@]} -eq 0 ]] && usage

# Set base directories based on mode
WASM_SPEC="$LINDFS/spec"
NATIVE_SPEC="${SPEC_DEPLOY:-$LIND_WASM_ROOT/native-spec}"

if [[ "$MODE" == "wasm" ]]; then
  [[ -x "$LIND_BOOT" ]] || die "lind-boot not found at $LIND_BOOT"
  WORK_BASE="$WASM_SPEC"
  info "mode: wasm (lind-boot)"
else
  WORK_BASE="$NATIVE_SPEC"
  info "mode: native ($NATIVE_SPEC)"
fi

for bench in "${targets[@]}"; do
  "run_${bench}"
done

info "all done"
