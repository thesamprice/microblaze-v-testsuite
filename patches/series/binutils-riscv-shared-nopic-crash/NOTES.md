# binutils-riscv-shared-nopic-crash

Not sent. Base: binutils `f50db130cf4` (master, 2026-11-20). Branch
`riscv-shared-nopic-crash` in `work/src/binutils`.

| | |
|---|---|
| 0001 | riscv: check sreloc before appending a dynamic reloc (bfd fix + `shared-lib-nopic-05`/`-06`) |
| 0002 | ld: testsuite: skip pr19719 runs without the libraries (`ld-elf/shared.exp`) |

Before sending: `Signed-off-by:` is not added (the sender adds it), and
binutils/MAINTAINERS says it does not accept legally significant
LLM-generated content; `tools/review-commit-msg.py` flags 0001 for that.

## The crash

ld segfaults at `elfnn-riscv.c:3879` (`riscv_elf_append_rela` with a NULL
`sreloc`; the AddressSanitizer build reads address 0x98) when making a
shared object from a section in which an `R_RISCV_HI20` comes before an
`R_RISCV_32` or `R_RISCV_64`.  `riscv_elf_check_relocs` returns at the
`HI20` (`bad_static_reloc`), so it never creates `sreloc` for the later
data reloc, and `lang_check_relocs` keeps the link going to report more
errors.  riscv32 newlib built medlow uses `HI20`, so `-shared` against it
crashed; riscv64 newlib built medany does not, but `shared-lib-nopic-06`
shows that rv64 crashes the same way with a `.dword`.

Smallest reproducer (6 lines): `ld/testsuite/ld-riscv-elf/shared-lib-nopic-05.s`.

## Results

`check-ld`, board `microblaze-v-qemu` (binutils tools get no board link
flags), binutils `f50db130cf4` with and without the series:

| | pass | fail | xfail | unresolved | untested | unsupported | SIGSEGV in log |
|---|---|---|---|---|---|---|---|
| riscv32, before | 958 | 221 | 8 | 0 | 9 | 304 | 181 |
| riscv32, after  | 959 | 220 | 8 | 4 | 9 | 302 | 0 |
| riscv64, before | 1109 | 64 | 10 | 0 | 9 | 379 | 0 |
| riscv64, after  | 1111 | 64 | 10 | 0 | 9 | 379 | 0 |

The riscv32 differences, test by test, are all of the lines that differ
between the two `.sum` files:

- `shared-lib-nopic-05`, `-06`: new, PASS.
- `Run pr19719{,pie} fun {defined,undefined}`: FAIL/UNSUPPORTED before,
  UNRESOLVED after (0002), since `Build libpr19719{a,b}.so` fail (still
  FAIL, as before).
- `Link with zlib-gabi compressed debug input`: PASS before, FAIL after.
  The PASS compared output left behind by crashed links (`Build libfoo.so
  with compressed debug sections` crashed with SIGSEGV before); with the
  crash gone ld removes its failed output, and the comparison fails as it
  should.

Without 0002, 0001 alone makes `shared.exp` abort at
`exec cp tmpdir/libpr19719b.so ...` (the crashed link used to leave a
partial file there), dropping the tests after it.

`ld-riscv-elf.exp` alone: 172 passes on riscv32-unknown-elf ld and 203 on
riscv64-unknown-elf ld with the series; without 0001, `shared-lib-nopic-05`
and `-06` FAIL (the captured output ends in `Segmentation fault: 11`).
