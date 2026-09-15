/*
 * test_common.inc — общие макросы тестов (статические бинарники без libc).
 * Соглашение тестов: окно wsz = 0x10 (32 регистра), setbn rbs = 0x8 ->
 * %b[0] = %r16, вызовы с wbs = 0x8. Библиотечные функции ставят окно
 * сами и совместимы с любым окном вызывающего.
 */
#include "coro_layout.h"

#define SYS_write	0x4
#define SYS_exit_group	0x12c
#define STACK_SZ	0x12000

.macro M_FRAME
	setwd	wsz = 0x10, nfx = 0x1
	setbn	rbs = 0x8, rsz = 0x7, rcur = 0x0
.endm

.macro M_WRITE msg, len
	addd	0x0, 0x1, %b[1]
	addd	0x0, \msg, %b[2]
	addd	0x0, \len, %b[3]
	addd	0x0, SYS_write, %b[0]
	sdisp	%ctpr1, 0x3
	call	%ctpr1, wbs = 0x8
	nop
.endm

.macro M_WRITE_BUF reg, len
	addd	0x0, 0x1, %b[1]
	addd	\reg, 0x0, %b[2]
	addd	0x0, \len, %b[3]
	addd	0x0, SYS_write, %b[0]
	sdisp	%ctpr1, 0x3
	call	%ctpr1, wbs = 0x8
	nop
.endm

.macro M_EXIT code
	addd	0x0, \code, %b[1]
	addd	0x0, SYS_exit_group, %b[0]
	sdisp	%ctpr1, 0x3
	call	%ctpr1, wbs = 0x8
	nop
.endm

/* M_CALL fn — аргументы уже разложены по %b[...] вызывающим */
.macro M_CALL fn
	disp	%ctpr1, \fn
	call	%ctpr1, wbs = 0x8
	nop
.endm

.macro M_TRANSFER from, to
	addd	0x0, \from, %b[0]
	addd	0x0, \to, %b[1]
	M_CALL	coro_transfer
.endm

.macro M_RETURN
	return	%ctpr3
	ct	%ctpr3
	nop
.endm

/* M_FAIL_IF pred, msg, len — печать сообщения и exit(1), если предикат истинен */
.macro M_FAIL_IF pred, label
	ibranch	\label ? \pred
	nop
.endm

/* ctx1/ctx2/main_ctx и области стеков, общие для всех тестов */
.macro M_TEST_DATA
	.data
	.balign	16
main_ctx:	.skip	CORO_CTX_SIZE
ctx1:		.skip	CORO_CTX_SIZE
ctx2:		.skip	CORO_CTX_SIZE
	.balign	CORO_AREA_ALIGN
stack1:		.skip	STACK_SZ
	.balign	CORO_AREA_ALIGN
stack2:		.skip	STACK_SZ
.endm

/* M_INIT ctxN, stackN, entry, arg — coro_init(ctx, area, STACK_SZ, entry, arg, main_ctx) */
.macro M_INIT ctx, area, entry, arg
	addd	0x0, \ctx, %b[0]
	addd	0x0, \area, %b[1]
	addd	0x0, STACK_SZ, %b[2]
	addd	0x0, \entry, %b[3]
	addd	0x0, \arg, %b[4]
	addd	0x0, main_ctx, %b[5]
	M_CALL	coro_init
	cmpedb	%b[0], 0x0, %pred0
	ibranch	init_failed ? ~%pred0
	nop
.endm

.macro M_INIT_FAILED_HANDLER
init_failed:
	M_WRITE	msg_init_failed, 18
	M_EXIT	1
	.section .rodata
msg_init_failed: .ascii	"FAIL: coro_init\n\0\0"
	.text
.endm
