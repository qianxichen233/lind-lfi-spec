#!/bin/bash
# spec.sh [-n reps] [-s SIZE-note] bench...: build, deploy and run SPEC CPU2017 benchmarks
# natively and as LFI cages, and print the ratio. Uses the Lind evaluation's own build
# flags, inputs and command lines (scripts/ are theirs, with a TARGET=lfi mode added).
#   LFI_GRATES="path/to/grate [args]"   grate chain in front of the benchmark
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
export PATH=/home/lind/lfi/.toolchain/x86_64-lfi-clang/lfi-bin:$PATH
RUNTIME=${RUN:-/home/lind/lfi/lfi-runtime/build/tools/lfi-3i-run/lfi-3i-run}
REPS=3; [ "${1:-}" = -n ] && { REPS=$2; shift 2; }
benches=("$@"); [ ${#benches[@]} -eq 0 ] && benches=(lbm mcf nab gcc xz x264 imagick perlbench deepsjeng namd leela omnetpp)
export LIND_WASM_ROOT=/home/lind/lind-wasm
declare -A num=( [lbm]=519.lbm_r [mcf]=505.mcf_r [nab]=544.nab_r [gcc]=502.gcc_r [xz]=557.xz_r [x264]=525.x264_r [imagick]=538.imagick_r [perlbench]=500.perlbench_r [deepsjeng]=531.deepsjeng_r [namd]=508.namd_r [leela]=541.leela_r [omnetpp]=520.omnetpp_r )
total_ms() { awk '/elapsed:/{gsub(/ms/,"",$NF); t+=$(NF-1)} END{print t+0}'; }
printf '%-11s %12s %12s %9s  %s\n' bench "native(ms)" "lfi(ms)" ratio status
for b in "${benches[@]}"; do
    n=${num[$b]}
    for t in native lfi; do TARGET=$t "$HERE/scripts/compile_$b.sh" > "$HERE/build/compile-$b-$t.log" 2>&1 || { echo "$b: $t build failed (see build/compile-$b-$t.log)"; continue 2; }; done
    best_n=; best_l=; exit_bad=; out_bad=
    for t in native lfi; do
        case $t in native) plat=native-linux; runner=;; lfi) plat=lfi; runner="$RUNTIME ${LFI_GRATES:-}";; esac
        dep=$HERE/work/$t; rm -rf "$dep/${b}_r"; mkdir -p "$dep"
        PLAT_DIR=$plat SPEC_DEPLOY=$dep "$HERE/scripts/deploy_spec.sh" --native "$b" > "$HERE/build/deploy-$b-$t.log" 2>&1 || { echo "$b: $t deploy failed"; continue 2; }
        times=()
        for ((r = 0; r < REPS; r++)); do
            out=$(SPEC_DEPLOY=$dep RUNNER="$runner" "$HERE/scripts/run_spec.sh" --native "$b" 2>&1)
            rc=$?
            # execution status is judged on its own and is never overridden by output agreement
            [ $rc -ne 0 ] && exit_bad="$exit_bad $t(run_spec rc=$rc)"
            echo "$out" | grep -q "EXIT [1-9]" && exit_bad="$exit_bad $t(EXIT!=0)"
            echo "$out" | grep -q "elapsed:" || exit_bad="$exit_bad $t(no run completed)"
            times+=("$(echo "$out" | total_ms)")
        done
        med=$(printf '%s\n' "${times[@]}" | sort -n | sed -n "$(( (REPS + 1) / 2 ))p")
        [ $t = native ] && best_n=$med || best_l=$med
    done
    # every file the benchmark produced must agree (stdout, images, encoded video, ...); only the
    # executables and stderr logs are skipped. *.out may differ in numbers within 1e-4, the rest
    # must be byte-identical.
    for f in "$HERE/work/native/${b}_r"/*; do
        [ -f "$f" ] || continue
        base=$(basename "$f")
        case $base in *.err|"${b}_r"|*_r_*.err) continue;; esac
        [ -x "$f" ] && continue
        g=$HERE/work/lfi/${b}_r/$base
        [ -f "$g" ] || { out_bad="$out_bad missing:$base"; continue; }
        cmp -s "$f" "$g" && continue
        case $base in
            *.out) python3 "$HERE/numdiff.py" "$f" "$g" || out_bad="$out_bad $base";;
            *) out_bad="$out_bad $base";;
        esac
    done
    status=ok
    [ -n "$exit_bad" ] && status="EXIT FAIL:$exit_bad"
    [ -n "$out_bad" ] && status="$status OUTPUT DIFFERS:$out_bad"
    [ "$status" = ok ] && status=ok
    printf '%-11s %12s %12s %8.2fx  %s\n' "$b" "$best_n" "$best_l" "$(awk -v a="${best_l:-0}" -v b="${best_n:-1}" 'BEGIN{printf "%.3f", a/b}')" "$status"
done
