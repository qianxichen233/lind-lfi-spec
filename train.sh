#!/bin/bash
# train.sh [-n reps]: SPEC "train"-size runs (long enough that start-up cost is small)
# for gcc, mcf, imagick, omnetpp; native vs LFI, same protocol as spec.sh.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
: "${LFI_ROOT:?set LFI_ROOT to your lind-lfi checkout}"
: "${SPEC_ROOT:?set SPEC_ROOT to the directory that contains benchspec/}"
RUNTIME=${RUN:-$LFI_ROOT/lfi-runtime/build/tools/lfi-3i-run/lfi-3i-run}
REPS=3; [ "${1:-}" = -n ] && REPS=$2
B=$SPEC_ROOT/benchspec/CPU; BIN=$HERE/build/bin
ms() { echo $(( ($(date +%s%N) - $1) / 1000000 )); }
median() { sort -n | sed -n "$(( (REPS + 1) / 2 ))p"; }

# bench-name | exe | files to stage | commands (one per line; run in sequence)
stage_and_run() {
    local name=$1 exe=$2 plat=$3 runner=$4; shift 4
    local d=$HERE/work/train/$plat/$name; rm -rf "$d"; mkdir -p "$d"
    # Staging problems are recorded in status.txt (a "stage:" line) so the caller can fail the case.
    cp "$BIN/$exe" "$d/" || echo "stage: copy of $exe failed" >> "$d/status.txt"
    eval "stage_$name \"\$d\"" || echo "stage: staging inputs failed" >> "$d/status.txt"
    local times=() r
    for ((r = 0; r < REPS; r++)); do
        local t0=$(date +%s%N)
        ( cd "$d" && eval "cmds_$name \"\$runner\" \"\$d\"" ) >/dev/null 2>"$d/err.txt"
        rc=$?
        [ $rc -ne 0 ] && echo "rep$r: exit $rc" >> "$d/status.txt"
        times+=("$(ms $t0)")
    done
    printf '%s\n' "${times[@]}" | median
}
stage_gcc()     { cp $B/502.gcc_r/data/train/input/{200.c,scilab.c,train01.c} "$1/"; }
cmds_gcc()      { for f in 200 scilab train01; do $1 ./cpugcc_r $f.c -O3 -finline-limit=50000 -o $f.s || return 1; done; }
stage_mcf()     { cp $B/505.mcf_r/data/train/input/inp.in "$1/"; }
cmds_mcf()      { $1 ./mcf_r inp.in > stdout.txt; }
stage_imagick() { cp $B/538.imagick_r/data/train/input/train_input.tga "$1/"; }
cmds_imagick()  { $1 ./imagick_r -limit disk 0 train_input.tga -resize 320x240 -shear 31 -edge 140 -negate -flop -resize 900x900 -edge 10 train_output.tga; }
stage_omnetpp() { cp $B/520.omnetpp_r/data/train/input/omnetpp.ini "$1/"; cp -r $B/520.omnetpp_r/data/all/input/ned "$1/"; }
cmds_omnetpp()  { $1 ./omnetpp_r -c General -r 0 > stdout.txt; }

declare -A EXE=( [gcc]=502.gcc_r/@PLAT@/cpugcc_r [mcf]=505.mcf_r/@PLAT@/mcf_r [imagick]=538.imagick_r/@PLAT@/imagick_r [omnetpp]=520.omnetpp_r/@PLAT@/omnetpp_r )
declare -A REQ=( [gcc]="200.s scilab.s train01.s" [mcf]="mcf.out stdout.txt" [imagick]="train_output.tga" [omnetpp]="stdout.txt General-0.sca" )
FAIL=0   # any problem in any requested case makes the script exit non-zero
printf '%-10s %12s %12s %9s  %s\n' "bench(train)" "native(ms)" "lfi(ms)" ratio status
for b in ${BENCHES:-gcc mcf imagick omnetpp}; do
    res=()
    for plat in native-linux lfi; do
        runner=; [ $plat = lfi ] && runner="$RUNTIME ${LFI_GRATES:-}"
        e=${EXE[$b]//@PLAT@/$plat}
        # the stage function copies "$BIN/$exe"; give it the right path under the bench's own name
        BINPATH=$e
        res+=("$(stage_and_run $b "$e" $plat "$runner")")
        # keep outputs for comparison
    done
    # execution status and output agreement are separate conditions; both are required
    status=ok
    a=$HERE/work/train/native-linux/$b; l=$HERE/work/train/lfi/$b
    for p in native-linux lfi; do
        [ -s $HERE/work/train/$p/$b/status.txt ] && status="EXIT FAIL($p): $(tr '\n' ' ' < $HERE/work/train/$p/$b/status.txt)"
    done
    for v in "${res[0]}" "${res[1]}"; do
        [[ "$v" =~ ^[0-9]+$ ]] && [ "$v" -gt 0 ] || status="$status; no timing sample"
    done
    out_bad=
    for f in ${REQ[$b]}; do
        for p in native-linux lfi; do
            [ -s $HERE/work/train/$p/$b/$f ] || out_bad="$out_bad required-missing-or-empty($p):$f"
        done
    done
    # every file either side produced (recursively; inputs, executables and stderr excepted) must
    # be present on both sides and agree
    lst() { (cd $HERE/work/train/$1/$b && find . -type f ! -name err.txt ! -name status.txt ! -perm -u+x ! -name train_input.tga ! -name omnetpp.ini ! -name inp.in ! -name '*.c' ! -path './ned/*' | sort); }
    for f in $( (lst native-linux; lst lfi) | sort -u ); do
        [ -e $a/$f ] && [ -e $l/$f ] || { out_bad="$out_bad only-one-side:$f"; continue; }
        cmp -s $a/$f $l/$f && continue
        case $f in *.txt|*.s|*.out) python3 $HERE/numdiff.py $a/$f $l/$f || out_bad="$out_bad $f";; *) out_bad="$out_bad $f";; esac
    done
    [ -n "$out_bad" ] && status="$status; OUTPUT DIFFERS:$out_bad"
    [ -s $l/err.txt ] && grep -q "rror\|illegal" $l/err.txt && status="$status; stderr: $(head -c 100 $l/err.txt)"
    status=${status#; }
    if [ "$status" = ok ]; then
        printf '%-10s %12s %12s %8.2fx  %s\n' "$b" "${res[0]}" "${res[1]}" "$(awk -v a="${res[1]}" -v b="${res[0]}" 'BEGIN{printf "%.3f", a/b}')" "$status"
    else
        FAIL=1
        printf '%-10s %12s %12s %9s  %s\n' "$b" "${res[0]:--}" "${res[1]:--}" "n/a" "$status"
    fi
done
[ $FAIL -eq 0 ] || { echo "TRAIN: SOME CASES FAILED; ratios are shown only for valid runs" >&2; exit 1; }
exit 0
