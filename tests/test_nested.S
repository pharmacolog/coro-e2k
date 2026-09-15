/*
 * test_nested — yield из вложенной процедуры: worker -> level1 -> level2,
 * каждая держит живое значение в своём окне и в своём кадре на стеке данных;
 * level2 делает yield. После возобновления все три уровня сверяют значения
 * при раскрутке. Проверяет, что PS/PCS/USD корутины переключаются целиком.
 */
#include "test_common.inc"
	.text
	.globl	_start
_start:
	M_FRAME
	M_INIT	ctx1, stack1, worker, param1
	addd	0x0, 0x0, %r4
1:
	M_TRANSFER main_ctx, ctx1
	M_WRITE	msg_main, 10
	addd	%r4, 0x1, %r4
	cmpldb	%r4, 0x3, %pred0
	ibranch	1b ? %pred0
	nop
	addd	0x0, ctx1, %b[0]
	M_CALL	coro_finished
	cmpedb	%b[0], 0x1, %pred0
	M_FAIL_IF ~%pred0, fail
	M_WRITE	msg_ok, 11
	M_EXIT	0
fail:
	M_WRITE	msg_fail, 13
	M_EXIT	1
	M_INIT_FAILED_HANDLER

worker:
	M_FRAME
	ldd	[%r0 + 0x8], %r1	/* own_ctx */
	addd	0x0, 0x1111, %r4	/* живое значение уровня 0 */
	getsp	-0x10, %r6
	std	%r4, [%r6 + 0x0]
	addd	%r1, 0x0, %b[0]
	addd	0x0, 0x2222, %b[1]
	M_CALL	level1
	cmpedb	%b[0], 0x2223, %pred0	/* level1 возвращает arg+1 */
	M_FAIL_IF ~%pred0, w_fail
	ldd	[%r6 + 0x0], %r7
	cmpedb	%r7, %r4, %pred0
	M_FAIL_IF ~%pred0, w_fail
	getsp	0x10, %r6
	M_WRITE	msg_w0, 10
	/* второй раунд: то же самое ещё раз, затем завершение */
	addd	%r1, 0x0, %b[0]
	addd	0x0, 0x2222, %b[1]
	M_CALL	level1
	cmpedb	%b[0], 0x2223, %pred0
	M_FAIL_IF ~%pred0, w_fail
	M_WRITE	msg_w0, 10
	M_RETURN
w_fail:
	M_WRITE	msg_fail0, 14
	M_EXIT	1

level1:					/* (own_ctx, v) */
	M_FRAME
	addd	%r1, 0x0, %r4
	getsp	-0x10, %r6
	std	%r4, [%r6 + 0x0]
	addd	%r0, 0x0, %b[0]
	addd	0x0, 0x3333, %b[1]
	M_CALL	level2
	cmpedb	%b[0], 0x3334, %pred0
	M_FAIL_IF ~%pred0, l1_fail
	ldd	[%r6 + 0x0], %r7
	cmpedb	%r7, %r4, %pred0
	M_FAIL_IF ~%pred0, l1_fail
	getsp	0x10, %r6
	M_WRITE	msg_w1, 10
	addd	%r4, 0x1, %r0
	M_RETURN
l1_fail:
	M_WRITE	msg_fail1, 14
	M_EXIT	1

level2:					/* (own_ctx, v): yield отсюда */
	M_FRAME
	addd	%r1, 0x0, %r4
	getsp	-0x10, %r6
	std	%r4, [%r6 + 0x0]
	M_WRITE	msg_w2, 10
	addd	%r0, 0x0, %b[0]
	addd	0x0, main_ctx, %b[1]
	M_CALL	coro_transfer		/* yield из глубины 3 */
	ldd	[%r6 + 0x0], %r7
	cmpedb	%r7, %r4, %pred0
	M_FAIL_IF ~%pred0, l2_fail
	cmpedb	%r4, 0x3333, %pred0
	M_FAIL_IF ~%pred0, l2_fail
	getsp	0x10, %r6
	M_WRITE	msg_w2r, 12
	addd	%r4, 0x1, %r0
	M_RETURN
l2_fail:
	M_WRITE	msg_fail2, 14
	M_EXIT	1

	.section .rodata
msg_main:	.ascii	"main: got\n"
msg_ok:		.ascii	"nested: ok\n"
msg_fail:	.ascii	"FAIL: nested\n"
msg_w0:		.ascii	"level0 ok\n"
msg_w1:		.ascii	"level1 ok\n"
msg_w2:		.ascii	"level2 in\n"
msg_w2r:	.ascii	"level2 back\n"
msg_fail0:	.ascii	"FAIL: level0 \n"
msg_fail1:	.ascii	"FAIL: level1 \n"
msg_fail2:	.ascii	"FAIL: level2 \n"
	.data
param1:		.quad	1, ctx1
	M_TEST_DATA
	.section .note.GNU-stack,"",%progbits
