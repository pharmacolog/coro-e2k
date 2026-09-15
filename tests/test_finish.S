/*
 * test_finish — завершение корутин: entry возвращается -> управление уходит в
 * ret_ctx; coro_finished == 1; повторное возобновление завершённой корутины
 * немедленно возвращает управление.
 */
#include "test_common.inc"
	.text
	.globl	_start
_start:
	M_FRAME
	M_INIT	ctx1, stack1, worker, param1
	M_INIT	ctx2, stack2, worker, param2
	/* до завершения coro_finished == 0 */
	addd	0x0, ctx1, %b[0]
	M_CALL	coro_finished
	cmpedb	%b[0], 0x0, %pred0
	M_FAIL_IF ~%pred0, fail_early
	addd	0x0, 0x0, %r4
1:	/* 3 шага печатают, 4-й раунд возвращает обе корутины через return */
	M_TRANSFER main_ctx, ctx1
	M_TRANSFER main_ctx, ctx2
	addd	%r4, 0x1, %r4
	cmpldb	%r4, 0x4, %pred0
	ibranch	1b ? %pred0
	nop
	addd	0x0, ctx1, %b[0]
	M_CALL	coro_finished
	cmpedb	%b[0], 0x1, %pred0
	M_FAIL_IF ~%pred0, fail_flag
	addd	0x0, ctx2, %b[0]
	M_CALL	coro_finished
	cmpedb	%b[0], 0x1, %pred0
	M_FAIL_IF ~%pred0, fail_flag
	M_WRITE	msg_finished, 14
	/* возобновление завершённой корутины: должны сразу вернуться сюда */
	M_TRANSFER main_ctx, ctx1
	M_TRANSFER main_ctx, ctx2
	M_TRANSFER main_ctx, ctx1
	M_WRITE	msg_resume, 19
	M_EXIT	0
fail_early:
	M_WRITE	msg_fail_early, 17
	M_EXIT	1
fail_flag:
	M_WRITE	msg_fail_flag, 16
	M_EXIT	1
	M_INIT_FAILED_HANDLER

worker:
	M_FRAME
	ldd	[%r0 + 0x0], %r5
	ldd	[%r0 + 0x8], %r1
	addd	0x0, 0x0, %r4
1:
	getsp	-0x20, %r6
	addd	0x0, wmsg, %r7
	ldd	[%r7 + 0x0], %r8
	std	%r8, [%r6 + 0x0]
	ldd	[%r7 + 0x8], %r8
	std	%r8, [%r6 + 0x8]
	ldd	[%r7 + 0x10], %r8
	std	%r8, [%r6 + 0x10]
	adds	%r5, 0x30, %r8
	stb	%r8, [%r6 + 0x7]
	adds	%r4, 0x30, %r8
	stb	%r8, [%r6 + 0xf]
	M_WRITE_BUF %r6, 17
	getsp	0x20, %r6
	addd	%r1, 0x0, %b[0]
	addd	0x0, main_ctx, %b[1]
	M_CALL	coro_transfer
	addd	%r4, 0x1, %r4
	cmpldb	%r4, 0x3, %pred0
	ibranch	1b ? %pred0
	nop
	M_RETURN			/* entry вернулась -> трамплин -> ret_ctx */

	.section .rodata
msg_finished:	.ascii	"both finished\n"
msg_resume:	.ascii	"resume finished ok\n"
msg_fail_early:	.ascii	"FAIL: early flag\n"
msg_fail_flag:	.ascii	"FAIL: not done\n\0"
	.balign 8
wmsg:		.ascii	"worker 0: step 0\n"
		.skip	7
	.data
param1:		.quad	1, ctx1
param2:		.quad	2, ctx2
	M_TEST_DATA
	.section .note.GNU-stack,"",%progbits
