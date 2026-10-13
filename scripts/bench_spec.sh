#!/usr/bin/env bash
# bench_spec.sh — Run all SPEC C benchmarks in wasm + native, produce comparison report
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_SPEC="$SCRIPT_DIR/run_spec.sh"

LIND_WASM_ROOT="${LIND_WASM_ROOT:-$HOME/lind-wasm}"

ALL_BENCHMARKS="lbm mcf nab gcc xz x264 imagick perlbench deepsjeng namd leela omnetpp"

die()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "[bench] $*"; }

usage() {
  cat <<EOF
Usage: $0 [OPTIONS] [benchmark ...] | all

Runs benchmarks in both wasm (Lind) and native modes, then prints a
comparison table with elapsed times and overhead ratio.

Options:
  --wasm-only    Only run wasm
  --native-only  Only run native
  -h, --help     Show this help

Benchmarks: $ALL_BENCHMARKS
EOF
  exit 1
}

# Parse elapsed times from run_spec.sh output.
# Groups times by benchmark (=== header), sums multiple invocations.
# Output: one line per benchmark: "<bench_name> <total_ms>"
parse_times() {
  local input="$1"
  awk '
    /^.*=== [0-9]+\..* ===/ {
      if (bench != "" && total > 0) print bench, total
      # extract short name: "519.lbm_r" → "lbm"
      match($0, /[0-9]+\.([a-z0-9]+)_r/, m)
      bench = m[1]
      total = 0
      next
    }
    /elapsed:/ {
      match($0, /elapsed: ([0-9]+) ms/, m)
      if (m[1] != "") total += m[1]
    }
    END {
      if (bench != "" && total > 0) print bench, total
    }
  ' "$input"
}

# -------- Main ----------------------------------------------------------------

run_wasm=true
run_native=true
targets=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --wasm-only)   run_native=false; shift ;;
    --native-only) run_wasm=false; shift ;;
    -h|--help)     usage ;;
    all)           targets=($ALL_BENCHMARKS); shift ;;
    lbm|mcf|nab|gcc|xz|x264|imagick|perlbench|deepsjeng|namd|leela|omnetpp) targets+=("$1"); shift ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ ${#targets[@]} -eq 0 ]] && targets=($ALL_BENCHMARKS)

bench_args="${targets[*]}"

TMPDIR_BENCH=$(mktemp -d)
trap "rm -rf $TMPDIR_BENCH" EXIT

wasm_log="$TMPDIR_BENCH/wasm.log"
native_log="$TMPDIR_BENCH/native.log"

# Run benchmarks
if $run_wasm; then
  info "running wasm benchmarks..."
  "$RUN_SPEC" $bench_args 2>&1 | tee "$wasm_log"
  echo ""
fi

if $run_native; then
  info "running native benchmarks..."
  "$RUN_SPEC" --native $bench_args 2>&1 | tee "$native_log"
  echo ""
fi

# Collect times into associative arrays
declare -A wasm_times native_times

if $run_wasm && [[ -f "$wasm_log" ]]; then
  while read -r bench ms; do
    wasm_times[$bench]=$ms
  done < <(parse_times "$wasm_log")
fi

if $run_native && [[ -f "$native_log" ]]; then
  while read -r bench ms; do
    native_times[$bench]=$ms
  done < <(parse_times "$native_log")
fi

# Print report
info "=== Results ==="
echo ""
printf "%-12s %10s %10s %10s\n" "Benchmark" "Wasm (ms)" "Native (ms)" "Overhead"
printf "%-12s %10s %10s %10s\n" "---------" "---------" "-----------" "--------"

for bench in "${targets[@]}"; do
  wasm_ms="${wasm_times[$bench]:-—}"
  native_ms="${native_times[$bench]:-—}"

  if [[ "$wasm_ms" != "—" && "$native_ms" != "—" && "$native_ms" -gt 0 ]]; then
    ratio=$(awk "BEGIN { printf \"%.2fx\", $wasm_ms / $native_ms }")
  else
    ratio="—"
  fi

  printf "%-12s %10s %10s %10s\n" "$bench" "$wasm_ms" "$native_ms" "$ratio"
done

echo ""

# Print totals if both modes ran
if $run_wasm && $run_native; then
  total_wasm=0
  total_native=0
  for bench in "${targets[@]}"; do
    [[ "${wasm_times[$bench]:-}" ]] && total_wasm=$((total_wasm + wasm_times[$bench]))
    [[ "${native_times[$bench]:-}" ]] && total_native=$((total_native + native_times[$bench]))
  done
  if [[ $total_native -gt 0 ]]; then
    total_ratio=$(awk "BEGIN { printf \"%.2fx\", $total_wasm / $total_native }")
  else
    total_ratio="—"
  fi
  printf "%-12s %10s %10s %10s\n" "TOTAL" "$total_wasm" "$total_native" "$total_ratio"
  echo ""
fi
