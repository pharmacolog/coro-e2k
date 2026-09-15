/*
 * test_attrs — coro_init_ex: параметризуемые размеры стеков, guard-страницы,
 * coro_destroy.
 *   - геометрия с attr {ps=0xC000, pcs=0x2000, GUARD}: sbr и SP на месте;
 *   - рекурсия глубиной 200 (6400 байт PCS — больше умолчания 4 КиБ);
 *   - после coro_destroy guard-страница снова доступна на запись;
 *   - отказы: невыровненный ps_size; size, недостаточный с учётом guard.
 */
#include "test_common.inc"
#define PS	0xC000
#define PCS	0x2000
#define G	CORO_GUARD_SIZE
#define DEPTH	200
	.text
	.globl	_start
_start:
	M_FRAME
	/* ошибки атрибутов */
	addd	0x0, ctx1, %b[0]
	addd	0x0, stack1, %b[1]
	addd	0x0, STACK_SZ, %b[2]
	addd	0x0, worker, %b[3]
	addd	0x0, param1, %b[4]
	addd	0x0, main_ctx, %b[5]
	addd	0x0, attr_bad_align, %b[6]
	M_CALL	coro_init_ex
	cmpedb	%b[0], -0x1, %pred0
	M_FAIL_IF ~%pred0, fail_init
	addd	0x0, ctx1, %b[0]
	addd	0x0, stack1, %b[1]
	addd	0x0, PS + PCS + 3 * G, %b[2]	/* под данные не остаётся места */
	addd	0x0, worker, %b[3]
	addd	0x0, param1, %b[4]
	addd	0x0, main_ctx, %b[5]
	addd	0x0, attr_ok, %b[6]
	M_CALL	coro_init_ex
	cmpedb	%b[0], -0x1, %pred0
	M_FAIL_IF ~%pred0, fail_init
	/* корректная инициализация с guard */
	addd	0x0, ctx1, %b[0]
	addd	0x0, stack1, %b[1]
	addd	0x0, STACK_SZ, %b[2]
	addd	0x0, worker, %b[3]
	addd	0x0, param1, %b[4]
	addd	0x0, main_ctx, %b[5]
	addd	0x0, attr_ok, %b[6]
	M_CALL	coro_init_ex
	cmpedb	%b[0], 0x0, %pred0
	M_FAIL_IF ~%pred0, fail_init
	M_TRANSFER main_ctx, ctx1
	addd	0x0, ctx1, %b[0]
	M_CALL	coro_finished
	cmpedb	%b[0], 0x1, %pred0
	M_FAIL_IF ~%pred0, fail_init
	/* destroy: guard снят, запись в бывшую guard-страницу проходит */
	addd	0x0, ctx1, %b[0]
	M_CALL	coro_destroy
	addd	0x0, stack1, %r6
	addd	0x0, 0x77, %r7
	std	%r7, [%r6 + 0x0]
	ldd	[%r6 + 0x0], %r8
	cmpedb	%r7, %r8, %pred0
	M_FAIL_IF ~%pred0, fail_destroy
	M_WRITE	msg_destroy, 12
	M_WRITE	msg_ok, 10
	M_EXIT	0
fail_init:
	M_WRITE	msg_fail_init, 11
	M_EXIT	1
fail_destroy:
	M_WRITE	msg_fail_destroy, 14
	M_EXIT	1
fail_geom:
	M_WRITE	msg_fail_geom, 11
	M_EXIT	1
fail_depth:
	M_WRITE	msg_fail_depth, 12
	M_EXIT	1

worker:
	M_FRAME
	ldd	[%r0 + 0x8], %r1	/* own_ctx */
	addd	0x0, stack1, %r9
	addd	%r9, STACK_SZ - G - PCS - G - PS, %r10	/* ожидаемый sbr */
	ldd	[%r1 + CTX_SBR], %r11
	cmpedb	%r10, %r11, %pred0
	M_FAIL_IF ~%pred0, fail_geom
	getsp	0x0, %r6
	subd	%r10, BOOT_SIZE, %r7
	cmpedb	%r6, %r7, %pred0
	M_FAIL_IF ~%pred0, fail_geom
	M_WRITE	msg_geom, 9
	addd	0x0, DEPTH, %b[0]
	disp	%ctpr1, recurse
	call	%ctpr1, wbs = 0x8
	nop
	cmpedb	%b[0], DEPTH * (DEPTH + 1) / 2, %pred0	/* сумма 1..DEPTH */
	M_FAIL_IF ~%pred0, fail_depth
	M_WRITE	msg_depth, 10
	M_RETURN

/* recurse(n) = n + recurse(n-1); recurse(0) = 0 — маленькое окно, чтобы PS
 * не переполнился раньше PCS */
recurse:
	setwd	wsz = 0x8, nfx = 0x1
	setbn	rbs = 0x4, rsz = 0x3, rcur = 0x0
	addd	%r0, 0x0, %r1
	cmpedb	%r1, 0x0, %pred0
	ibranch	1f ? %pred0
	nop
	subd	%r1, 0x1, %b[0]
	disp	%ctpr1, recurse
	call	%ctpr1, wbs = 0x4
	nop
	addd	%b[0], %r1, %r0
	M_RETURN
1:	addd	0x0, 0x0, %r0
	M_RETURN

	.section .rodata
msg_geom:	.ascii	"geom: ok\n"
msg_depth:	.ascii	"depth: ok\n"
msg_destroy:	.ascii	"destroy: ok\n"
msg_ok:		.ascii	"attrs: ok\n"
msg_fail_init:	.ascii	"FAIL: init\n"
msg_fail_destroy: .ascii "FAIL: destroy\n"
msg_fail_geom:	.ascii	"FAIL: geom\n"
msg_fail_depth:	.ascii	"FAIL: depth\n"
	.data
	.balign	8
param1:		.quad	1, ctx1
attr_ok:	.quad	PS, PCS, CORO_ATTR_GUARD
attr_bad_align:	.quad	PS + 0x10, PCS, 0
	M_TEST_DATA
	.section .note.GNU-stack,"",%progbits
