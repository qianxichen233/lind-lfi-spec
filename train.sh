#!/bin/bash
# train.sh [-n reps]: SPEC "train"-size runs (long enough that start-up cost is small)
# for gcc, mcf, imagick, omnetpp; native vs LFI, same protocol as spec.sh.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
RUNTIME=${RUN:-/home/lind/lfi/lfi-runtime/build/tools/lfi-3i-run/lfi-3i-run}
REPS=3; [ "${1:-}" = -n ] && REPS=$2
B=$HERE/benchspec/CPU; BIN=$HERE/build/bin
ms() { echo $(( ($(date +%s%N) - $1) / 1000000 )); }
median() { sort -n | sed -n "$(( (REPS + 1) / 2 ))p"; }

# bench-name | exe | files to stage | commands (one per line; run in sequence)
stage_and_run() {
    local name=$1 exe=$2 plat=$3 runner=$4; shift 4
    local d=$HERE/work/train/$plat/$name; rm -rf "$d"; mkdir -p "$d"
    cp "$BIN/$exe" "$d/"
    eval "stage_$name \"\$d\""
    local times=() r
    for ((r = 0; r < REPS; r++)); do
        local t0=$(date +%s%N)
        ( cd "$d" && eval "cmds_$name \"\$runner\" \"\$d\"" ) >/dev/null 2>"$d/err.txt"
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
    status=ok
    a=$HERE/work/train/native-linux/$b; l=$HERE/work/train/lfi/$b
    for f in $(cd $a && ls | grep -v -E "^(err.txt|cpugcc_r|mcf_r|imagick_r|omnetpp_r|ned|.*\.(c|tga|ini|in))$|^train_input"); do
        cmp -s $a/$f $l/$f || python3 $HERE/numdiff.py $a/$f $l/$f || status="OUTPUT DIFFERS ($f)"
    done
    [ -s $l/err.txt ] && grep -q "rror\|illegal" $l/err.txt && status="errors: $(head -c 100 $l/err.txt)"
    printf '%-10s %12s %12s %8.2fx  %s\n' "$b" "${res[0]}" "${res[1]}" "$(awk -v a="${res[1]}" -v b="${res[0]}" 'BEGIN{printf "%.3f", a/b}')" "$status"
done
