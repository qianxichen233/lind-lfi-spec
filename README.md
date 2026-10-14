# lind-lfi-spec — SPEC CPU2017 on LFI cages vs native

Scripts that build and run SPEC CPU2017 benchmarks natively and as cages of the
[`lind-lfi`](../lind-lfi) runtime (LFI sandboxes with Lind's 3i layer), check that both produce the
same results, and report the runtime ratio. Companion to `lind-lfi` `v0.1.0-experimental`.
**The measurements are exploratory**, see "Limitations".

**SPEC CPU2017 is licensed software and is not part of this repository.** You supply it (below).
The build scripts and command lines derive from the evaluation scripts of
[`Lind-Project/lind-wasm-spec`](https://github.com/Lind-Project/lind-wasm-spec) (tested against commit
`8bb30b8`), with a `TARGET=lfi` mode added; keep their license terms with any copy.

## Prerequisites

* A built `lind-lfi` checkout (its README: `scripts/bootstrap.sh`, `meson setup build && ninja -C build`
  in `lfi-runtime`). `export LFI_ROOT=/path/to/lind-lfi`.
* Your SPEC CPU2017 installation or extracted tree, containing `benchspec/CPU/...` (with the
  benchmark sources and their `data/test`, `data/train`, `data/all` inputs). `export SPEC_ROOT=` the
  directory that contains `benchspec/`. Nothing is copied back into this repository (`/benchspec` is
  ignored; do not commit SPEC content).
* An ordinary clang for the native baseline: `export NATIVE_CLANG_DIR=` an LLVM install (default: the
  first `clang` on `PATH`). The reported numbers used LLVM 18.1.8; the LFI side uses the LFI clang 23 /
  musl from the `lind-lfi` bundle, so the two sides differ in compiler and libc (see below).
* `python3` (output comparison), `taskset` is not required.

## Usage

    export LFI_ROOT=...  SPEC_ROOT=...
    ./spec.sh                       # all 12 benchmarks, SPEC "test" inputs, median of 3
    ./spec.sh -n 5 mcf xz           # chosen benchmarks, 5 repetitions
    ./train.sh                      # "train" inputs for gcc mcf imagick omnetpp (run ./spec.sh gcc mcf imagick omnetpp first: it builds the binaries)
    LFI_GRATES="path/to/grate" ./spec.sh lbm    # a grate chain in front of the benchmark

Benchmarks: `lbm mcf nab gcc xz x264 imagick perlbench deepsjeng namd leela omnetpp`.

Per benchmark `spec.sh` builds the native and LFI binaries (`scripts/compile_<bench>.sh`, Lind's
flags and commands), deploys each into `work/{native,lfi}/`, runs it `-n` times, and prints the
medians and the ratio. A row is **valid only if** every run exited 0 **and** the outputs agree:
required artifacts must exist on both sides (non-empty for result-carrying files), every other file
either side produced must exist on both and match (recursively; `*.out`/`*.output` may differ in
numbers within 1e-4 via `numdiff.py`; everything else byte for byte; x264's decoder log is skipped
because it embeds the time). Invalid rows print `n/a` instead of a ratio and the script exits non-zero
— a later good benchmark does not clear an earlier failure.

`gcc_r` for LFI is built from a private copy of the source with `set_cfg_hooks` changed to take a
pointer (the LFI v0.12 compiler passes the ~300-byte struct by value with an instruction the verifier
rejects); the edit is made by `scripts/compile_gcc.sh` at build time. A few musl compatibility
`-include`/`-D` flags are in the `LFI_COMPAT` variable of each `compile_*.sh`. `omnetpp` needs its `ned/`
directory, which `deploy_spec.sh` copies.

## Results (one machine, one run set)

Intel Core i9-12900K, Linux 6.8.0-138 (Ubuntu 22.04), median of 3, scripts at commit `f3e206c`
(this release adds path configuration only), runtime = `lind-lfi` `threei-fixpass` `a4a8d9f` (the release
tree contains the same code), LFI clang 23.0.0git (`b06a60e9`) / musl, native LLVM 18.1.8 `-O2`, verification on.
Ratios are LFI time / native time; raw rows in `results/`.

| benchmark | test: native ms | test: LFI ms | ratio | | train: native ms | train: LFI ms | ratio |
|---|---:|---:|---:|---|---:|---:|---:|
| lbm | 757 | 785 | 1.04 | | | | |
| mcf | 5262 | 5871 | 1.12 | | 30361 | 33880 | 1.12 |
| nab | 532 | 869 | 1.63 | | | | |
| xz | 4782 | 5464 | 1.14 | | | | |
| x264 | 12429 | 13945 | 1.12 | | | | |
| deepsjeng | 3630 | 4377 | 1.21 | | | | |
| namd | 1689 | 2075 | 1.23 | | | | |
| leela | 2706 | 3347 | 1.24 | | | | |
| perlbench | 135 | 273 | 2.02 | | | | |
| omnetpp | 1442 | 6167 | 4.28 | | 27632 | 45685 | 1.65 |
| gcc | 14 | 259 | 18.5 | | 18192 | 30013 | 1.65 |
| imagick | 15 | 70 | 4.67 | | 14092 | 15517 | 1.10 |

The very short `test` runs (gcc, imagick, perlbench) are dominated by loading and verifying the
binary (about 10 ms plus 12 ms per MB; there is no verification cache): read those from the train
column. The allocation-heavy benchmarks (omnetpp, gcc) are slower mostly because of musl's `malloc`
(5.3× glibc's in a micro-benchmark; not confirmed on the SPEC binaries themselves). `nab` (1.63) is
unexplained.

## Limitations

* **Different compilers and libcs.** Native: clang 18 + glibc. LFI: clang 23 + musl. Part of every
  ratio is that difference, not the sandbox.
* **Not a reproduction of the Lind paper's evaluation.** The paper compares Wasm-based Lind on other
  hardware; its input size is not stated. Do not read ratios here against its figures as an
  equivalent-policy comparison.
* One machine, medians of three, no confidence intervals; `refrate` inputs and the other SPEC
  benchmarks (C++ ones needing exceptions, Fortran) are not covered.
* The scripts validate exit status and outputs as described above; passing is evidence the runs were
  correct, not that LFI matches native semantics in general.
* Nothing here measures grate overhead on SPEC (`LFI_GRATES` is supported but was not run for results).
