/*
 * test_init_errors — coro_init отвергает некорректные аргументы (-1) и
 * принимает корректные (0): NULL ctx, NULL entry, невыровненная area,
 * невыровненный size, слишком малый size.
 */
#include "test_common.inc"
	.text
	.globl	_start
_start:
	M_FRAME
/* ожидаем -1 */
.macro EXPECT_BAD ctx, area, size, entry
	addd	0x0, \ctx, %b[0]
	addd	0x0, \area, %b[1]
	addd	0x0, \size, %b[2]
	addd	0x0, \entry, %b[3]
	addd	0x0, 0x0, %b[4]
	addd	0x0, main_ctx, %b[5]
	M_CALL	coro_init
	cmpedb	%b[0], -0x1, %pred0
	ibranch	fail ? ~%pred0
	nop
.endm
	EXPECT_BAD 0x0, stack1, STACK_SZ, entry
	EXPECT_BAD ctx1, stack1, STACK_SZ, 0x0
	EXPECT_BAD ctx1, stack1 + 0x10, STACK_SZ, entry
	EXPECT_BAD ctx1, stack1, STACK_SZ - 0x10, entry
	EXPECT_BAD ctx1, stack1, CORO_MIN_AREA - 0x1000, entry
	/* минимально допустимый размер — принимается и работает */
	addd	0x0, ctx1, %b[0]
	addd	0x0, stack1, %b[1]
	addd	0x0, CORO_MIN_AREA, %b[2]
	addd	0x0, entry, %b[3]
	addd	0x0, 0x0, %b[4]
	addd	0x0, main_ctx, %b[5]
	M_CALL	coro_init
	cmpedb	%b[0], 0x0, %pred0
	ibranch	fail ? ~%pred0
	nop
	M_TRANSFER main_ctx, ctx1
	M_WRITE	msg_ok, 16
	M_EXIT	0
fail:
	M_WRITE	msg_fail, 11
	M_EXIT	1
entry:
	M_FRAME
	M_WRITE	msg_entry, 10
	M_RETURN
	.section .rodata
msg_ok:		.ascii	"init errors: ok\n"
msg_fail:	.ascii	"FAIL: init\n"
msg_entry:	.ascii	"entry ran\n\0"
	.data
	M_TEST_DATA
	.section .note.GNU-stack,"",%progbits
