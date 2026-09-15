/*
 * coro_e2k.S — стековые корутины для e2k («Эльбрус»), бэкенд DIRECT.
 *
 * Переключение контекста выполняется прямой записью в регистры аппаратных
 * стеков (PSP, PCSP, USD, USBR). Эти регистры привилегированы, поэтому бэкенд
 * пригоден:
 *   - в эмуляторе qemu-e2k (linux-user) с патчем tools/qemu-e2k-user-hwstacks.patch;
 *   - на железе — только в привилегированном коде (ядро, гипервизор, bare-metal).
 * Для пользовательского кода на железе используйте бэкенд UCONTEXT
 * (src/coro_ucontext.c), где стеки переключает ядро ОС.
 *
 * Блок контекста coro_ctx_t (CORO_CTX_SIZE = 0x60 байт, выравнивание 16):
 *   0x00 psp.hi    0x08 psp.lo    стек процедур (PS)
 *   0x10 pcsp.hi   0x18 pcsp.lo   стек цепочек вызовов (PCS)
 *   0x20 usd.hi    0x28 usd.lo    стек данных
 *   0x30 sbr                      база стека данных
 *   0x38 arg       0x40 ret_ctx   0x48 entry     (coro_init)
 *   0x50 flags     0x58 резерв    flags bit0 = корутина завершилась
 *
 * Раскладка области area (выравнивание и размер кратны 0x1000):
 *   [area, area+data_sz)                 стек данных, растёт ВНИЗ от sbr;
 *                                        верхние 0x20 байт — указатель own_ctx
 *   [area+data_sz, +CORO_PS_SIZE)        стек процедур
 *   [area+data_sz+CORO_PS_SIZE, +CORO_PCS_SIZE)  стек цепочек
 *   data_sz = size - CORO_PS_SIZE - CORO_PCS_SIZE  (не меньше 0x1000)
 *
 * Соглашение о вызове — штатное ABI e2k: аргументы в %r0..%r5 окна вызываемой
 * процедуры (call ... wbs), результат в %r0. Каждая процедура сама
 * устанавливает своё окно (setwd), поэтому библиотека вызываема из кода lcc.
 */

#include "coro_layout.h"

	.text

/*
 * void coro_transfer(coro_ctx_t *from, coro_ctx_t *to)
 *
 * Сохраняет в [from] состояние на момент входа (после flushr/flushc всё, что
 * ниже текущего окна, лежит в PS/PCS), загружает регистры стеков из [to] и
 * делает return: верхняя chain-запись снимается уже с ЧУЖОГО стека цепочек,
 * окно вызывающего восстанавливается из ЧУЖОГО стека процедур, управление
 * уходит в точку, где корутина `to` в прошлый раз вошла в coro_transfer
 * (или на трамплин — при первом запуске).
 *
 * Окно расширяется до архитектурного максимума: setwd не может уменьшать
 * окно ниже размера на входе, а размер окна вызывающего неизвестен.
 * Регистры окна самой coro_transfer сохранять не нужно — сюда не возвращаются.
 */
	.globl	coro_transfer
	.type	coro_transfer, @function
coro_transfer:
	setwd	wsz = 0x70, nfx = 0x1
	flushr				/* регистровый файл -> PS   (qemu: no-op) */
	flushc				/* кэш chain-записей -> PCS (qemu: no-op) */

	rrd	%psp.hi, %r2
	std	%r2, [%r0 + CTX_PSP_HI]
	rrd	%psp.lo, %r2
	std	%r2, [%r0 + CTX_PSP_LO]
	rrd	%pcsp.hi, %r2
	std	%r2, [%r0 + CTX_PCSP_HI]
	rrd	%pcsp.lo, %r2
	std	%r2, [%r0 + CTX_PCSP_LO]
	rrd	%usd.hi, %r2
	std	%r2, [%r0 + CTX_USD_HI]
	rrd	%usd.lo, %r2
	std	%r2, [%r0 + CTX_USD_LO]
	rrd	%usbr, %r2
	std	%r2, [%r0 + CTX_SBR]

	/* USD восстанавливается и самим return (usd = sbr - cr1.ussz*16);
	 * явная запись делает контекст самодостаточным и не вредит. */
	ldd	[%r1 + CTX_SBR], %r2
	rwd	%r2, %usbr
	ldd	[%r1 + CTX_USD_HI], %r2
	rwd	%r2, %usd.hi
	ldd	[%r1 + CTX_USD_LO], %r2
	rwd	%r2, %usd.lo
	ldd	[%r1 + CTX_PSP_HI], %r2
	rwd	%r2, %psp.hi
	ldd	[%r1 + CTX_PSP_LO], %r2
	rwd	%r2, %psp.lo
	ldd	[%r1 + CTX_PCSP_HI], %r2
	rwd	%r2, %pcsp.hi
	ldd	[%r1 + CTX_PCSP_LO], %r2
	rwd	%r2, %pcsp.lo

	return	%ctpr3			/* подготовка возврата по chain-записи `to` */
	ct	%ctpr3			/* собственно передача управления */
	nop
	.size	coro_transfer, .-coro_transfer

/*
 * __coro_trampoline — первая точка входа новой корутины.
 * Сюда «возвращается» первый coro_transfer(…, ctx) по фабрикованной
 * chain-записи. Читает own_ctx из вершины своего стека данных, вызывает
 * entry(arg) штатным call, по возврате помечает корутину завершённой и
 * передаёт управление ret_ctx. Если завершённую корутину возобновят снова —
 * немедленно возвращает управление обратно (без выхода из процесса).
 */
	.type	__coro_trampoline, @function
__coro_trampoline:
	setwd	wsz = 0x8, nfx = 0x1
	setbn	rbs = 0x4, rsz = 0x3, rcur = 0x0
	getsp	0x0, %r0		/* SP = sbr - BOOT_SIZE */
	ldd	[%r0 + 0x0], %r1	/* own_ctx */
	ldd	[%r1 + CTX_ENTRY], %r2
	addd	0x0, CTPR_TAG_DISP, %r3
	shld	%r3, CTPR_TAG_OFF, %r3
	ord	%r2, %r3, %r2		/* ctpr = entry | tag DISP */
	movtd	%r2, %ctpr1
	ldd	[%r1 + CTX_ARG], %b[0]
	call	%ctpr1, wbs = 0x4	/* entry(arg) */
	nop
	addd	0x0, CORO_FLAG_FINISHED, %r2
	std	%r2, [%r1 + CTX_FLAGS]
1:
	addd	%r1, 0x0, %b[0]
	ldd	[%r1 + CTX_RET], %b[1]
	disp	%ctpr1, coro_transfer
	call	%ctpr1, wbs = 0x4	/* coro_transfer(own, ret) */
	nop
	ibranch	1b
	nop
	.size	__coro_trampoline, .-__coro_trampoline

/*
 * int coro_init(coro_ctx_t *ctx, void *area, size_t size,
 *               void (*entry)(void *), void *arg, coro_ctx_t *ret_ctx)
 * Возвращает 0 или -1 (ctx/area/entry == NULL, area или size не кратны
 * 0x1000, size < CORO_MIN_AREA).
 */
	.globl	coro_init
	.type	coro_init, @function
coro_init:
	setwd	wsz = 0x70, nfx = 0x1	/* окно вызывающего неизвестно: не ниже области параметров */
	/* %r0=ctx %r1=area %r2=size %r3=entry %r4=arg %r5=ret_ctx */
	addd	0x0, -0x1, %r15		/* результат по умолчанию: -1 */
	cmpedb	%r0, 0x0, %pred0
	ibranch	9f ? %pred0
	nop
	cmpedb	%r1, 0x0, %pred0
	ibranch	9f ? %pred0
	nop
	cmpedb	%r3, 0x0, %pred0
	ibranch	9f ? %pred0
	nop
	andd	%r1, CORO_AREA_ALIGN - 1, %r6
	andd	%r2, CORO_AREA_ALIGN - 1, %r7
	ord	%r6, %r7, %r6
	cmpedb	%r6, 0x0, %pred0	/* pred0 = area и size выровнены */
	ibranch	9f ? ~%pred0
	nop
	cmpbdb	%r2, CORO_MIN_AREA, %pred0	/* pred0 = size слишком мал */
	ibranch	9f ? %pred0
	nop

	subd	%r2, CORO_PS_SIZE + CORO_PCS_SIZE, %r6	/* data_sz */
	addd	%r1, %r6, %r7		/* sbr = area + data_sz (вершина стека данных) */

	/* параметры и флаги */
	std	%r4, [%r0 + CTX_ARG]
	std	%r5, [%r0 + CTX_RET]
	std	%r3, [%r0 + CTX_ENTRY]
	addd	0x0, 0x0, %r8
	std	%r8, [%r0 + CTX_FLAGS]
	std	%r8, [%r0 + CTX_RESERVED]

	/* стек данных: SP = sbr - BOOT_SIZE, доступная область [SP, sbr) */
	std	%r7, [%r0 + CTX_SBR]
	subd	%r7, BOOT_SIZE, %r8
	std	%r8, [%r0 + CTX_USD_LO]	/* usd.lo = base = SP */
	addd	0x0, BOOT_SIZE, %r9
	shld	%r9, 0x20, %r9
	std	%r9, [%r0 + CTX_USD_HI]	/* usd.hi = size << 32 */
	std	%r0, [%r8 + 0x0]	/* own_ctx на вершине стека данных */

	/* стек процедур: base = area + data_sz, index = 0 */
	std	%r7, [%r0 + CTX_PSP_LO]
	addd	0x0, CORO_PS_SIZE, %r9
	shld	%r9, 0x20, %r9
	std	%r9, [%r0 + CTX_PSP_HI]

	/* стек цепочек: одна фабрикованная запись, index = CR_SIZE */
	addd	%r7, CORO_PS_SIZE, %r10	/* pcs_base */
	std	%r10, [%r0 + CTX_PCSP_LO]
	addd	0x0, CORO_PCS_SIZE, %r9
	shld	%r9, 0x20, %r9
	addd	%r9, CR_SIZE, %r9
	std	%r9, [%r0 + CTX_PCSP_HI]

	/* chain-запись по pcs_base + CR_SIZE: return в __coro_trampoline */
	addd	0x0, 0x0, %r8
	std	%r8, [%r10 + CR_SIZE + CR0_LO]		/* pregs = 0 */
	addd	0x0, __coro_trampoline, %r8
	std	%r8, [%r10 + CR_SIZE + CR0_HI]		/* адрес возврата */
	rrd	%psr, %r8
	andd	%r8, CR1_LO_PSR_MASK, %r8
	shld	%r8, CR1_LO_PSR_OFF, %r8		/* psr наследуется от создателя */
	rrd	%cuir, %r9
	andd	%r9, CR1_LO_CUIR_MASK, %r9
	shld	%r9, CR1_LO_CUIR_OFF, %r9
	ord	%r8, %r9, %r8
	ord	%r8, CR1_LO_WFX_BIT, %r8		/* wbs = wpsz = 0, wfx = 1 */
	std	%r8, [%r10 + CR_SIZE + CR1_LO]
	addd	0x0, BOOT_SIZE >> 4, %r8
	shld	%r8, CR1_HI_USSZ_OFF, %r8		/* ussz = BOOT_SIZE / 16 */
	std	%r8, [%r10 + CR_SIZE + CR1_HI]

	addd	0x0, 0x0, %r15
9:
	addd	%r15, 0x0, %r0
	return	%ctpr3
	ct	%ctpr3
	nop
	.size	coro_init, .-coro_init

/*
 * int coro_finished(const coro_ctx_t *ctx) — 1, если entry вернулась.
 */
	.globl	coro_finished
	.type	coro_finished, @function
coro_finished:
	setwd	wsz = 0x70, nfx = 0x1
	ldd	[%r0 + CTX_FLAGS], %r0
	andd	%r0, CORO_FLAG_FINISHED, %r0
	return	%ctpr3
	ct	%ctpr3
	nop
	.size	coro_finished, .-coro_finished

	.section .note.GNU-stack,"",%progbits
