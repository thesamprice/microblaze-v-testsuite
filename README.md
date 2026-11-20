# MicroBlaze V toolchain testsuite

The MicroBlaze V version of
[microblaze-testsuite](https://github.com/thesamprice/microblaze-testsuite). It builds a RISC-V
`riscv32-unknown-elf` cross toolchain for the AMD MicroBlaze V, and QEMU,
from upstream sources. It runs the binutils, GCC and newlib DejaGnu
testsuites against them, with the execute tests running on QEMU's
`amd-microblaze-v-generic` machine, and measures with
[tcgcov](https://github.com/thesamprice/tcgcov) what target code those runs
cover.

```sh
make                     # fetch and build binutils, gcc+newlib+libgloss, DejaGnu, QEMU
make check-gcc-smoke     # eight execute tests across all torture levels
make check-binutils      # binutils, gas and ld testsuites
make check-gcc           # gcc.c-torture/execute, all of it
make check-newlib        # newlib/testsuite
make check               # all of the above
make coverage            # check-gcc + check-newlib under tcgcov, then the report
make coverage-smoke      # the same over GCC_SMOKE and newlib's string.exp
make summary             # the summaries of the last runs, and the source revisions
```

`make TARGET=riscv64-unknown-elf WORK=$PWD/work64` does the same for the
64-bit core.

## What it builds

Everything goes under `work/` (set `WORK=` to move it):

| | source | |
|---|---|---|
| binutils | `binutils-gdb.git` `master` | `--disable-gdb --disable-sim` |
| gcc | `gcc.git` `master` | C only, `--with-newlib --disable-multilib`, one multilib for `MBV_ARCH`/`MBV_ABI` |
| newlib, libgloss | `newlib-cygwin.git` `main` | symlinked into the gcc tree, so gcc builds them |
| DejaGnu | `dejagnu.git` `master` | stock, run from its source tree; the board lives in `board/` here |
| QEMU | release tarball, 10.2.4 | `riscv32-softmmu`, `riscv64-softmmu`, plugins on, no patches |

The MicroBlaze V configuration follows RTEMS's `riscv/mbv` and
`riscv/mbv64` BSPs:

| `TARGET` | `MBV_ARCH` | `MBV_ABI` | `MBV_CMODEL` | QEMU |
|---|---|---|---|---|
| `riscv32-unknown-elf` (default) | `rv32imafc_zicsr_zifencei` | `ilp32f` | `medlow` | `qemu-system-riscv32` |
| `riscv64-unknown-elf` | `rv64imac_zicsr_zifencei` | `lp64` | `medany` | `qemu-system-riscv64` |

QEMU's `amd-microblaze-v-generic` turns off the D extension, so there is
no double-precision FPU to target. RV64 uses `medany` because RAM is at
`0x80000000`. All three variables can be set on the command line.
`QEMU_TARBALL=path` uses a local copy of the QEMU tarball. When
git.savannah.gnu.org is down (it returned 502 during the first build),
`DEJAGNU_GIT=file:///path/to/a/dejagnu/clone` clones DejaGnu from a local
copy.

`patches/<component>/*.patch` is applied the same way as in
microblaze-testsuite: adding, changing or deleting a patch resets the
clone and applies the set again. The "own trees" variables (`BINUTILS_SRC`,
`BINUTILS_BUILD`, `GCC_SRC`, `GCC_BUILD`, `TOOLBIN`, `NEWLIB_SRC`,
`DEJAGNU_SRC`, `QEMU`) work the same way too.

## How the board works

`board/microblaze-v-qemu.exp` is a `*-sim`-style board, like
`riscv-sim.exp`. The site file the Makefile writes adds `board/` to
DejaGnu's `boards_dir`, so DejaGnu needs no patch. Compared with the
MicroBlaze board:

- **Semihosting replaces the UART and `libxil`.** The board links
  libgloss's `--specs=semihost.specs`, so `write()` and `exit()` go to
  QEMU, run with `-semihosting-config enable=on,target=native`. QEMU exits
  when the program does, so the runner does not have to watch the output
  for the status line and kill QEMU.
- **The status wrapper is still needed.** On RV32, libgloss's semihosting
  `_exit` passes only `ADP_Stopped_ApplicationExit`, not the status, so
  QEMU exits 0 whatever the program returned. The board sets
  `needs_status_wrapper`, and the status comes from `testglue.c`'s
  `*** EXIT code N`, as on MicroBlaze.
- **A reset stub, `board/mbv-start.S`.** The machine does not load
  `-kernel`, so the runner uses `-device loader,file=…,cpu-num=0`, which
  sets only the PC. libgloss's `_start` expects a loader that has already
  set `sp`, `argc` and `argv`. The stub is the ELF entry
  (`-Wl,-e,_mbv_start`). It sets `sp` to the top of RAM and turns on the
  FPU (`mstatus.FS`), because the hart resets with it off and the first
  `flw` in printf would trap. It also points `mtvec` at a handler that
  prints `mcause`/`mepc`/`mtval` and exits, so a fault fails the test at
  once instead of spinning until the timeout.
- **Text at `0x80000000`** (`-Wl,-Ttext-segment=0x80000000`). The default
  `0x10000` is inside the machine's 128 KiB of LMB BRAM.
- **`MBV_LIBGLOSS`.** GCC's testsuite finds `semihost.specs` and
  `libsemihost.a` in the build tree through `libgloss_link_flags`.
  newlib's testsuite points the compiler only at newlib's build directory,
  so without help every newlib test failed to compile ("cannot read spec
  file 'semihost.specs'"). The Makefile exports the installed libgloss
  directory, and the board adds it with `-B`/`-L` after the others.
- **`--no-relax` is not needed.** RISC-V relaxation handles `__wrap_*`,
  so the suite runs with relaxation, as a user's build would.

`MBV_RAM_MB` (default 128) sets QEMU's `-m` and the stack top. `MBV_CPU`
passes a `-cpu` to QEMU. `MBV_TIMEOUT` (default 90 s) limits each test,
and `check-newlib` uses `NEWLIB_TIMEOUT` (300 s) instead.

`make env` prints the environment for running a testsuite by hand:

```sh
eval "$(make -s env)"
cd work/build/gcc
make check-gcc RUNTESTFLAGS="--target_board=microblaze-v-qemu execute.exp=pr50865.c"
```

## Coverage

`make coverage` builds the tcgcov plugin against the QEMU here and runs
`check-gcc` and `check-newlib` with `coverage/qemu-cov` in place of QEMU.
The wrapper adds the plugin to every run and keeps each test's ELF beside
its `.cov`, because DejaGnu deletes the binaries. `tcgcov report` then
symbolizes every run and merges them by source line into one LCOV file.
genhtml then renders the HTML report. It is run with `--ignore-errors
inconsistent`, because lcov 2 rejects a line that ran while the branch on
it did not, and tcgcov reports exactly that: when the optimizer duplicates
a line, the copy that ran may hold no branch (newlib's `vfprintf.c:1428`).
tcgcov's own `report --html` does the same from
[tcgcov#28](https://github.com/thesamprice/tcgcov/pull/28) on. The denominator is the
library code linked into at least one test binary, not all of newlib. Paths are relative to `work/src`, and the test programs
themselves are left out. What is measured is the target code the tests run:
libgcc, newlib and libgloss.

| | |
|---|---|
| `work/coverage/raw/` | one `.cov` and `.elf` per run |
| `work/coverage/report/lcov/aggregate-riscv.info` | the merged LCOV |
| `work/coverage/report/html/index.html` | genhtml's report |
| `work/coverage/report/summary.txt` | `coverage/summary.py`: lines, functions and branches per directory |
| `work/coverage/results/` | the `.sum`/`.log` of the instrumented runs |

`TCGCOV` names a tcgcov checkout (default `~/src/tcgcov`).
`COV_GCC_TESTS`/`COV_NEWLIB_TESTS` narrow the runs, and
`make coverage-report` redoes only the report.

## Results

binutils `f50db130cf4`, gcc `4582d80bb1e`, newlib `51fc50b5109`, DejaGnu
`04e420155f7`, QEMU 10.2.4. The gcc and newlib rows for the full suites
will come from `make coverage`, which is still running.

| | pass | fail | xfail | untested | unsupported |
|---|---|---|---|---|---|
| riscv32 binutils | 279 | 0 | 0 | 0 | 14 |
| riscv32 gas | 671 | 0 | 23 | 0 | 15 |
| riscv32 ld | 958 | 221 | 8 | 9 | 304 |
| riscv64 binutils | 280 | 0 | 0 | 0 | 13 |
| riscv64 gas | 671 | 0 | 23 | 0 | 19 |
| riscv64 ld | 1109 | 64 | 10 | 9 | 379 |
| riscv32, gcc `check-gcc-smoke` | 122 | 0 | 0 | 0 | 0 |
| riscv64, gcc `check-gcc-smoke` (before the 4 MiB stack declaration) | 106 | 0 | 0 | 0 | 8 |
| riscv32, newlib `string.exp` | 8 | 0 | 0 | 0 | 0 |

The ld rows are with the board leaving its link flags out of the binutils
tools' links. Before that change, ld's shared-library, audit and
compression tests linked with `mbv-start.o`, the entry point and the text
address, and riscv64 had 263 failures.

**ld crashed on riscv32.** 181 of the 221 riscv32 ld failures were ld
dying with SIGSEGV, mostly in `ld-elf/shared.exp`, which links `-shared`
against bare-metal (non-PIC) newlib. `riscv_elf_check_relocs` stops at the
first `R_RISCV_HI20` it rejects, so a later `R_RISCV_32` in the same
section gets no dynamic reloc section. ld still relocates the section in
order to report every error, and `riscv_elf_relocate_section` appends
through the NULL pointer. riscv64 newlib (medany) has no `HI20`, but a
`.dword` after an `HI20` crashes rv64 the same way.
[`patches/series/binutils-riscv-shared-nopic-crash`](patches/series/binutils-riscv-shared-nopic-crash)
has the fix, two tests, and a guard for a `shared.exp` procedure that
aborted once the crash was gone. With it, riscv32 ld has no SIGSEGV and 220
failures; the numbers and every test that changed are in its `NOTES.md`.
It is not in `patches/binutils` yet, so the build does not apply it. The
remaining failures on both variants are shared-library tests that a
non-PIC newlib cannot pass, and have not been triaged one by one.
