/*
 * test_guard_fault — guard-страница под стеком данных действительно
 * защищена: запись в неё из корутины завершает процесс SIGSEGV (exit 139).
 * Ожидаемый вывод — только строка до обращения.
 */
#include "test_common.inc"
	.text
	.globl	_start
_start:
	M_FRAME
	addd	0x0, ctx1, %b[0]
	addd	0x0, stack1, %b[1]
	addd	0x0, STACK_SZ, %b[2]
	addd	0x0, worker, %b[3]
	addd	0x0, 0x0, %b[4]
	addd	0x0, main_ctx, %b[5]
	addd	0x0, attr_guard, %b[6]
	M_CALL	coro_init_ex
	cmpedb	%b[0], 0x0, %pred0
	ibranch	fail ? ~%pred0
	nop
	M_TRANSFER main_ctx, ctx1
	M_WRITE	msg_survived, 15		/* сюда попасть не должны */
	M_EXIT	1
fail:
	M_WRITE	msg_fail, 11
	M_EXIT	1
worker:
	M_FRAME
	M_WRITE	msg_before, 13
	addd	0x0, stack1, %r6
	addd	0x0, 0x1, %r7
	std	%r7, [%r6 + 0x0]		/* guard-страница -> SIGSEGV */
	M_WRITE	msg_survived, 15
	M_RETURN
	.section .rodata
msg_before:	.ascii	"before fault\n"
msg_survived:	.ascii	"FAIL: no fault\n"
msg_fail:	.ascii	"FAIL: init\n"
	.data
	.balign	8
attr_guard:	.quad	0, 0, CORO_ATTR_GUARD
	M_TEST_DATA
	.section .note.GNU-stack,"",%progbits
