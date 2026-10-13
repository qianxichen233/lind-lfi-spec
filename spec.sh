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
# Artifacts each benchmark must produce on BOTH sides (non-empty); anything else either side
# produced must also match, and files present on only one side are a failure.
declare -A REQ=(
    [lbm]="lbm_r.out" [mcf]="mcf_r.out mcf.out" [nab]="nab_r.out"
    [gcc]="cpugcc_r.out t1.opts-O3_-finline-limit_50000.s"
    [xz]="cpu2006docs.tar-1-0.out cpu2006docs.tar-4-0.out"
    [x264]="run_000-156_x264_r_x264.out frame_0.yuv frame_50.yuv frame_100.yuv frame_150.yuv frame_155.yuv"
    [imagick]="test_output.tga" [perlbench]="makerand.out test.out"
    [deepsjeng]="deepsjeng_r.out" [namd]="namd_r.out apoa1.test.output" [leela]="leela_r.out"
    [omnetpp]="omnetpp.General-0.out General-0.sca" )
declare -A NONEMPTY=(
    [lbm]="lbm_r.out" [mcf]="mcf_r.out" [nab]="nab_r.out" [gcc]="t1.opts-O3_-finline-limit_50000.s"
    [x264]="frame_0.yuv frame_155.yuv" [imagick]="test_output.tga" [deepsjeng]="deepsjeng_r.out"
    [namd]="namd_r.out apoa1.test.output" [leela]="leela_r.out" [omnetpp]="omnetpp.General-0.out" )
FAIL=0   # set by any problem in any requested case; the script exits non-zero if it is set
printf '%-11s %12s %12s %9s  %s\n' bench "native(ms)" "lfi(ms)" ratio status
for b in "${benches[@]}"; do
    n=${num[$b]:-}
    [ -n "$n" ] || { echo "$b: unknown benchmark"; FAIL=1; continue; }
    for t in native lfi; do TARGET=$t "$HERE/scripts/compile_$b.sh" > "$HERE/build/compile-$b-$t.log" 2>&1 || { echo "$b: $t build failed (see build/compile-$b-$t.log)"; FAIL=1; continue 2; }; done
    best_n=; best_l=; exit_bad=; out_bad=
    for t in native lfi; do
        case $t in native) plat=native-linux; runner=;; lfi) plat=lfi; runner="$RUNTIME ${LFI_GRATES:-}";; esac
        dep=$HERE/work/$t; rm -rf "$dep/${b}_r"; mkdir -p "$dep"
        PLAT_DIR=$plat SPEC_DEPLOY=$dep "$HERE/scripts/deploy_spec.sh" --native "$b" > "$HERE/build/deploy-$b-$t.log" 2>&1 || { echo "$b: $t deploy failed"; FAIL=1; continue 2; }
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
    [ -n "$best_n" ] && [ "$best_n" != 0 ] && [ -n "$best_l" ] && [ "$best_l" != 0 ] || exit_bad="$exit_bad (no timing sample)"
    # Required artifacts must exist and be non-empty on both sides ...
    for f in ${REQ[$b]}; do
        for t in native lfi; do
            [ -f "$HERE/work/$t/${b}_r/$f" ] || out_bad="$out_bad required-missing($t):$f"
        done
    done
    for f in ${NONEMPTY[$b]:-}; do   # artifacts that carry the result and are never empty
        for t in native lfi; do
            [ -s "$HERE/work/$t/${b}_r/$f" ] || out_bad="$out_bad required-empty($t):$f"
        done
    done
    # ... and every other file either side produced (recursively; executables and stderr logs
    # excepted) must be present on both and agree. *.out / *.output may differ in numbers within
    # 1e-4, everything else must be byte-identical.
    lst() { (cd "$HERE/work/$1/${b}_r" && find . -type f ! -name '*.err' ! -perm -u+x | sort); }
    for f in $( (lst native; lst lfi) | sort -u ); do
        base=$(basename "$f")
        [ "$base" = log.dec ] && continue   # x264's decoder log embeds the wall-clock time
        n=$HERE/work/native/${b}_r/$f; g=$HERE/work/lfi/${b}_r/$f
        if [ ! -e "$n" ] || [ ! -e "$g" ]; then out_bad="$out_bad only-one-side:$f"; continue; fi
        cmp -s "$n" "$g" && continue
        case $base in
            *.out|*.output) python3 "$HERE/numdiff.py" "$n" "$g" || out_bad="$out_bad $f";;
            *) out_bad="$out_bad $f";;
        esac
    done
    status=ok
    [ -n "$exit_bad" ] && status="EXIT FAIL:$exit_bad"
    if [ -n "$out_bad" ]; then
        [ "$status" = ok ] && status="OUTPUT DIFFERS:$out_bad" || status="$status; OUTPUT DIFFERS:$out_bad"
    fi
    if [ "$status" = ok ]; then
        printf '%-11s %12s %12s %8.2fx  %s\n' "$b" "$best_n" "$best_l" "$(awk -v a="$best_l" -v b="$best_n" 'BEGIN{printf "%.3f", a/b}')" "$status"
    else
        FAIL=1
        printf '%-11s %12s %12s %9s  %s\n' "$b" "${best_n:--}" "${best_l:--}" "n/a" "$status"   # no ratio for an invalid run
    fi
done
[ $FAIL -eq 0 ] || { echo "SPEC: SOME CASES FAILED; ratios are shown only for valid runs" >&2; exit 1; }
exit 0
