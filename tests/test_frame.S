/*
 * test_frame — геометрия стека данных корутины:
 *   - на входе SP == sbr - BOOT_SIZE (вершина области данных);
 *   - кадр, выделенный штатным getsp -N, лежит внутри [area, area+data_sz);
 *   - большой кадр (0x800) тоже внутри области, запись в него не портит
 *     соседние структуры (ctx2 инициализируется после и сверяется).
 */
#include "test_common.inc"
#define DATA_SZ (STACK_SZ - CORO_PS_SIZE - CORO_PCS_SIZE)
	.text
	.globl	_start
_start:
	M_FRAME
	M_INIT	ctx1, stack1, worker, param1
	M_TRANSFER main_ctx, ctx1
	M_WRITE	msg_ok, 10
	M_EXIT	0
fail_top:
	M_WRITE	msg_fail_top, 14
	M_EXIT	1
fail_in:
	M_WRITE	msg_fail_in, 17
	M_EXIT	1
	M_INIT_FAILED_HANDLER

worker:
	M_FRAME
	ldd	[%r0 + 0x8], %r1	/* own_ctx */
	addd	0x0, stack1, %r9	/* area */
	addd	%r9, DATA_SZ, %r10	/* area + data_sz == sbr */
	getsp	0x0, %r6
	subd	%r10, BOOT_SIZE, %r7
	cmpedb	%r6, %r7, %pred0	/* SP == sbr - BOOT_SIZE ? */
	M_FAIL_IF ~%pred0, fail_top
	M_WRITE	msg_top, 10
	getsp	-0x800, %r6		/* большой кадр */
	cmpbdb	%r6, %r9, %pred0	/* frame < area ? */
	M_FAIL_IF %pred0, fail_in
	addd	%r6, 0x800, %r7
	cmpbdb	%r10, %r7, %pred0	/* frame_end > sbr ? */
	M_FAIL_IF %pred0, fail_in
	/* заполнить кадр целиком */
	addd	0x0, 0x0, %r8
1:	std	%r8, [%r6 + %r8]
	addd	%r8, 0x8, %r8
	cmpldb	%r8, 0x800, %pred0
	ibranch	1b ? %pred0
	nop
	getsp	0x800, %r6
	M_WRITE	msg_in, 13
	addd	%r1, 0x0, %b[0]
	addd	0x0, main_ctx, %b[1]
	M_CALL	coro_transfer
	M_RETURN

	.section .rodata
msg_ok:		.ascii	"frame: ok\n"
msg_top:	.ascii	"sp at top\n"
msg_in:		.ascii	"frame inside\n"
msg_fail_top:	.ascii	"FAIL: sp top\n\0"
msg_fail_in:	.ascii	"FAIL: frame out\n\0"
	.data
param1:		.quad	1, ctx1
	M_TEST_DATA
	.section .note.GNU-stack,"",%progbits
