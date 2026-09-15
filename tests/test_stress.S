/*
 * test_stress — 100 000 раундов по две корутины (200 000 переключений туда
 * и 200 000 обратно). Каждый шаг корутина выделяет кадр на стеке данных,
 * пишет туда маркер, делает yield и проверяет маркер после возобновления;
 * счётчик в регистровом окне сверяется с main.
 */
#include "test_common.inc"
#define ROUNDS 100000
	.text
	.globl	_start
_start:
	M_FRAME
	M_INIT	ctx1, stack1, worker, param1
	M_INIT	ctx2, stack2, worker, param2
	addd	0x0, 0x0, %r4
1:
	M_TRANSFER main_ctx, ctx1
	M_TRANSFER main_ctx, ctx2
	addd	%r4, 0x1, %r4
	cmpldb	%r4, ROUNDS, %pred0
	ibranch	1b ? %pred0
	nop
	/* обе корутины должны были досчитать до ROUNDS и завершиться */
	addd	0x0, ctx1, %b[0]
	M_CALL	coro_finished
	cmpedb	%b[0], 0x1, %pred0
	M_FAIL_IF ~%pred0, fail_count
	addd	0x0, ctx2, %b[0]
	M_CALL	coro_finished
	cmpedb	%b[0], 0x1, %pred0
	M_FAIL_IF ~%pred0, fail_count
	M_WRITE	msg_ok, 11
	M_EXIT	0
fail_count:
	M_WRITE	msg_fail_count, 12
	M_EXIT	1
fail_stack:
	M_WRITE	msg_fail_stack, 12
	M_EXIT	1
	M_INIT_FAILED_HANDLER

worker:
	M_FRAME
	ldd	[%r0 + 0x8], %r1	/* own_ctx */
	addd	0x0, 0x0, %r4
1:
	getsp	-0x20, %r6
	xord	%r4, 0x5a5a, %r7	/* маркер, зависящий от счётчика */
	std	%r7, [%r6 + 0x8]
	addd	%r1, 0x0, %b[0]
	addd	0x0, main_ctx, %b[1]
	M_CALL	coro_transfer
	ldd	[%r6 + 0x8], %r8
	cmpedb	%r7, %r8, %pred0
	M_FAIL_IF ~%pred0, fail_stack
	getsp	0x20, %r6
	addd	%r4, 0x1, %r4
	cmpldb	%r4, ROUNDS - 1, %pred0
	ibranch	1b ? %pred0
	nop
	M_RETURN

	.section .rodata
msg_ok:		.ascii	"stress: ok\n"
msg_fail_count:	.ascii	"FAIL: count\n"
msg_fail_stack:	.ascii	"FAIL: stack\n"
	.data
param1:		.quad	1, ctx1
param2:		.quad	2, ctx2
	M_TEST_DATA
	.section .note.GNU-stack,"",%progbits
