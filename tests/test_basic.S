/*
 * test_basic — два worker'а по очереди, состояние в регистровом окне,
 * сообщение строится в кадре на собственном стеке данных корутины.
 * worker(arg): arg -> { id, own_ctx } (по ABI, в %r0)
 */
#include "test_common.inc"
	.text
	.globl	_start
_start:
	M_FRAME
	M_WRITE	msg_start, 12
	M_INIT	ctx1, stack1, worker, param1
	M_INIT	ctx2, stack2, worker, param2
	addd	0x0, 0x0, %r4
1:
	M_TRANSFER main_ctx, ctx1
	M_TRANSFER main_ctx, ctx2
	addd	%r4, 0x1, %r4
	cmpldb	%r4, 0x3, %pred0
	ibranch	1b ? %pred0
	nop
	M_WRITE	msg_done, 11
	M_EXIT	0
	M_INIT_FAILED_HANDLER

	.globl	worker
worker:
	M_FRAME
	ldd	[%r0 + 0x0], %r5	/* id */
	ldd	[%r0 + 0x8], %r1	/* own_ctx */
	addd	0x0, 0x0, %r4		/* counter — живёт в окне, переживает yield */
1:
	getsp	-0x20, %r6		/* кадр 32 байта: SP вниз, %r6 = новый SP */
	addd	0x0, wmsg, %r7
	ldd	[%r7 + 0x0], %r8
	std	%r8, [%r6 + 0x0]
	ldd	[%r7 + 0x8], %r8
	std	%r8, [%r6 + 0x8]
	ldd	[%r7 + 0x10], %r8
	std	%r8, [%r6 + 0x10]
	adds	%r5, 0x30, %r8
	stb	%r8, [%r6 + 0x7]	/* 'worker X' */
	adds	%r4, 0x30, %r8
	stb	%r8, [%r6 + 0xf]	/* 'step Y' */
	M_WRITE_BUF %r6, 17
	getsp	0x20, %r6		/* освободить кадр */
	addd	%r1, 0x0, %b[0]
	addd	0x0, main_ctx, %b[1]
	M_CALL	coro_transfer		/* yield */
	addd	%r4, 0x1, %r4
	cmpldb	%r4, 0x3, %pred0
	ibranch	1b ? %pred0
	nop
	M_RETURN

	.section .rodata
msg_start:	.ascii	"main: start\n"
msg_done:	.ascii	"main: done\n"
	.balign 8
wmsg:		.ascii	"worker 0: step 0\n"
		.skip	7
	.data
param1:		.quad	1, ctx1
param2:		.quad	2, ctx2
	M_TEST_DATA
	.section .note.GNU-stack,"",%progbits
