/* Reset stub for bare-metal tests on QEMU's amd-microblaze-v-generic.

   libgloss's RISC-V crt0 (_start) is written for a loader that has already
   set things up, as spike's pk and the gdb simulator do.  It sets gp and
   clears .bss but takes sp, argc and argv as it finds them.  QEMU's generic
   loader sets nothing except the PC, so this stub runs first and does three
   things:

     - sets sp to the top of RAM and leaves argc = 0, argv = envp = NULL there
       for crt0 to read;
     - turns on the FPU (mstatus.FS = Initial).  The hart resets with FS off,
       so the first F instruction, often inside printf, would trap;
     - points mtvec at a handler that prints mcause, mepc and mtval through
       semihosting and stops QEMU.  Without it a fault would spin until the
       timeout.  Since no "*** EXIT code" line has been printed, DejaGnu
       reports the test as failed.

   The board links this object first and makes _mbv_start the ELF entry
   point, which is where the generic loader starts the hart.

   MBV_STACK_TOP is set on the command line: RAM starts at 0x80000000 and
   the runner gives QEMU MBV_RAM_MB of it.  */

#ifndef MBV_STACK_TOP
#error "define MBV_STACK_TOP"
#endif

#if __riscv_xlen == 64
# define REG_S sd
# define REG_L ld
# define SZREG 8
#else
# define REG_S sw
# define REG_L lw
# define SZREG 4
#endif

#define SYS_WRITE0        0x04
#define SYS_EXIT_EXTENDED 0x20
#define ADP_Stopped_RunTimeErrorUnknown 0x20023

	.section .text.mbv_start, "ax"
	.globl _mbv_start
	.type _mbv_start, @function
_mbv_start:
	.option push
	.option norelax
	li	sp, MBV_STACK_TOP
	addi	sp, sp, -4 * SZREG
	REG_S	zero, 0(sp)		/* argc */
	REG_S	zero, SZREG(sp)		/* argv[0] */
	REG_S	zero, 2 * SZREG(sp)	/* envp[0] */
	li	t0, 0x2000		/* mstatus.FS = Initial */
	csrs	mstatus, t0
	la	t0, _mbv_trap
	csrw	mtvec, t0
	.option pop
	j	_start
	.size _mbv_start, . - _mbv_start

/* The semihosting call: a0 = operation, a1 = parameter.  The sequence must
   be uncompressed and must not cross a page.  */
	.balign 16
	.type _mbv_semihost, @function
_mbv_semihost:
	.option push
	.option norvc
	slli	zero, zero, 0x1f
	ebreak
	srai	zero, zero, 7
	.option pop
	ret
	.size _mbv_semihost, . - _mbv_semihost

/* print_hex: a1 = value, written as 0x... through SYS_WRITE0 from a buffer
   in .bss.  Clobbers t0-t3, a0, a1.  */
	.type _mbv_puthex, @function
_mbv_puthex:
	mv	t3, ra
	la	t0, _mbv_hexbuf
	li	t1, '0'
	sb	t1, 0(t0)
	li	t1, 'x'
	sb	t1, 1(t0)
	addi	t0, t0, 2
	li	t2, __riscv_xlen - 4
1:	srl	t1, a1, t2
	andi	t1, t1, 15
	addi	t1, t1, '0'
	li	a0, '9'
	ble	t1, a0, 2f
	addi	t1, t1, 'a' - '9' - 1
2:	sb	t1, 0(t0)
	addi	t0, t0, 1
	addi	t2, t2, -4
	bgez	t2, 1b
	sb	zero, 0(t0)
	li	a0, SYS_WRITE0
	la	a1, _mbv_hexbuf
	call	_mbv_semihost
	mv	ra, t3
	ret
	.size _mbv_puthex, . - _mbv_puthex

	.macro puts label
	li	a0, SYS_WRITE0
	la	a1, \label
	call	_mbv_semihost
	.endm

	.balign 4
	.globl _mbv_trap
	.type _mbv_trap, @function
_mbv_trap:
	puts	.Lmsg_trap
	csrr	a1, mcause
	call	_mbv_puthex
	puts	.Lmsg_mepc
	csrr	a1, mepc
	call	_mbv_puthex
	puts	.Lmsg_mtval
	csrr	a1, mtval
	call	_mbv_puthex
	puts	.Lmsg_nl
	/* SYS_EXIT_EXTENDED takes a block on both XLENs.  Any reason but
	   ApplicationExit makes QEMU exit with status 1.  */
	la	a1, _mbv_exitblk
	li	t0, ADP_Stopped_RunTimeErrorUnknown
	REG_S	t0, 0(a1)
	li	t0, 3
	REG_S	t0, SZREG(a1)
	li	a0, SYS_EXIT_EXTENDED
	call	_mbv_semihost
1:	j	1b
	.size _mbv_trap, . - _mbv_trap

	.section .rodata.mbv_start, "a"
.Lmsg_trap:	.string "\n*** MBV trap: mcause="
.Lmsg_mepc:	.string " mepc="
.Lmsg_mtval:	.string " mtval="
.Lmsg_nl:	.string "\n"

	.section .bss.mbv_start, "aw", @nobits
	.balign SZREG
_mbv_exitblk:	.space 2 * SZREG
_mbv_hexbuf:	.space 24
