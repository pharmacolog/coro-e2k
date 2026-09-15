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
 *   0x50 flags                    bit0 = корутина завершилась
 *   0x58 area      0x60 size      0x68 attr_flags
 *   0x70 ps_size   0x78 pcs_size  (описание области — для coro_destroy)
 *
 * Раскладка области area (выравнивание и размер кратны 0x1000), снизу вверх:
 *   [guard G]                            только с CORO_ATTR_GUARD
 *   стек данных data_sz                  растёт ВНИЗ от sbr; верхние 0x20 байт — own_ctx
 *   стек процедур ps_size   (= sbr)      растёт вверх
 *   [guard G]
 *   стек цепочек pcs_size                растёт вверх
 *   [guard G]
 *   data_sz = size - ps_size - pcs_size - 3G  (не меньше 0x1000)
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
 * MPROTECT addr, len, prot — syscall mprotect; результат в %b[0].
 * Окно 0x70, setbn rbs = 0x20 -> %b[0] = %r64, вызовы с wbs = 0x20.
 */
.macro MPROTECT addr, len, prot
	addd	\addr, 0x0, %b[1]
	addd	0x0, \len, %b[2]
	addd	0x0, \prot, %b[3]
	addd	0x0, SYS_mprotect, %b[0]
	sdisp	%ctpr1, 0x3
	call	%ctpr1, wbs = 0x20
	nop
.endm

/*
 * GUARD_ALL prot, fail — три guard-страницы области, описанной в ctx (%r0):
 *   [area, area+G)             под стеком данных (растёт вниз)
 *   [ps_base+ps_size, +G)      над стеком процедур (растёт вверх)
 *   [pcs_base+pcs_size, +G)    над стеком цепочек (растёт вверх)
 * При ошибке mprotect — переход на fail.
 */
.macro GUARD_ALL prot, fail
	ldd	[%r0 + CTX_AREA], %r16
	MPROTECT %r16, CORO_GUARD_SIZE, \prot
	cmpldb	%b[0], 0x0, %pred0
	ibranch	\fail ? %pred0
	nop
	ldd	[%r0 + CTX_SBR], %r16
	ldd	[%r0 + CTX_PS_SIZE], %r17
	addd	%r16, %r17, %r16
	MPROTECT %r16, CORO_GUARD_SIZE, \prot
	cmpldb	%b[0], 0x0, %pred0
	ibranch	\fail ? %pred0
	nop
	ldd	[%r0 + CTX_PCSP_LO], %r16
	ldd	[%r0 + CTX_PCS_SIZE], %r17
	addd	%r16, %r17, %r16
	MPROTECT %r16, CORO_GUARD_SIZE, \prot
	cmpldb	%b[0], 0x0, %pred0
	ibranch	\fail ? %pred0
	nop
.endm

/*
 * int coro_init_ex(coro_ctx_t *ctx, void *area, size_t size,
 *                  void (*entry)(void *), void *arg, coro_ctx_t *ret_ctx,
 *                  const coro_attr_t *attr)
 * attr == NULL — размеры по умолчанию, без guard-страниц.
 * Раскладка (сверху вниз): [guard PCS] PCS [guard PS] PS = данные (растут
 * вниз от sbr) [guard data]. Возвращает 0 или -1 (некорректные аргументы,
 * недостаточный size, ошибка mprotect).
 */
	.globl	coro_init_ex
	.type	coro_init_ex, @function
coro_init_ex:
	setwd	wsz = 0x70, nfx = 0x1	/* окно вызывающего неизвестно: не ниже области параметров */
	setbn	rbs = 0x20, rsz = 0x7, rcur = 0x0
	/* %r0=ctx %r1=area %r2=size %r3=entry %r4=arg %r5=ret_ctx %r6=attr */
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
	andd	%r1, CORO_AREA_ALIGN - 1, %r7
	andd	%r2, CORO_AREA_ALIGN - 1, %r8
	ord	%r7, %r8, %r7
	cmpedb	%r7, 0x0, %pred0	/* pred0 = area и size выровнены */
	ibranch	9f ? ~%pred0
	nop

	/* атрибуты: ps_size, pcs_size, flags (0 -> по умолчанию) */
	addd	0x0, CORO_PS_SIZE, %r11
	addd	0x0, CORO_PCS_SIZE, %r12
	addd	0x0, 0x0, %r13
	cmpedb	%r6, 0x0, %pred0
	ibranch	1f ? %pred0
	nop
	ldd	[%r6 + ATTR_PS_SIZE], %r7
	ldd	[%r6 + ATTR_PCS_SIZE], %r8
	ldd	[%r6 + ATTR_FLAGS], %r13
	cmpedb	%r7, 0x0, %pred0
	ibranch	2f ? %pred0
	nop
	addd	%r7, 0x0, %r11
2:	cmpedb	%r8, 0x0, %pred0
	ibranch	1f ? %pred0
	nop
	addd	%r8, 0x0, %r12
1:	andd	%r11, CORO_AREA_ALIGN - 1, %r7
	andd	%r12, CORO_AREA_ALIGN - 1, %r8
	ord	%r7, %r8, %r7
	cmpedb	%r7, 0x0, %pred0	/* размеры стеков кратны странице */
	ibranch	9f ? ~%pred0
	nop
	andd	%r13, CORO_ATTR_GUARD, %r14
	cmpedb	%r14, 0x0, %pred0
	addd	0x0, 0x0, %r14		/* %r14 = размер guard: 0 или G */
	addd	0x0, CORO_GUARD_SIZE, %r14 ? ~%pred0

	/* геометрия сверху вниз */
	addd	%r1, %r2, %r7		/* top */
	subd	%r7, %r14, %r7		/* pcs_end  = top - guard */
	subd	%r7, %r12, %r10		/* pcs_base */
	subd	%r10, %r14, %r7		/* ps_end   = pcs_base - guard */
	subd	%r7, %r11, %r9		/* ps_base = sbr */
	addd	%r1, %r14, %r7		/* data_lo = area + guard */
	subd	%r9, %r7, %r8		/* data_sz (signed) */
	cmpldb	%r8, CORO_MIN_DATA, %pred0
	ibranch	9f ? %pred0
	nop

	/* параметры, флаги, описание области (для coro_destroy) */
	std	%r4, [%r0 + CTX_ARG]
	std	%r5, [%r0 + CTX_RET]
	std	%r3, [%r0 + CTX_ENTRY]
	addd	0x0, 0x0, %r8
	std	%r8, [%r0 + CTX_FLAGS]
	std	%r1, [%r0 + CTX_AREA]
	std	%r2, [%r0 + CTX_SIZE]
	std	%r13, [%r0 + CTX_ATTR_FLAGS]
	std	%r11, [%r0 + CTX_PS_SIZE]
	std	%r12, [%r0 + CTX_PCS_SIZE]

	/* стек данных: SP = sbr - BOOT_SIZE, доступная область [SP, sbr) */
	std	%r9, [%r0 + CTX_SBR]
	subd	%r9, BOOT_SIZE, %r8
	std	%r8, [%r0 + CTX_USD_LO]	/* usd.lo = base = SP */
	addd	0x0, BOOT_SIZE, %r7
	shld	%r7, 0x20, %r7
	std	%r7, [%r0 + CTX_USD_HI]	/* usd.hi = size << 32 */
	std	%r0, [%r8 + 0x0]	/* own_ctx на вершине стека данных */

	/* стек процедур: base = sbr, index = 0 */
	std	%r9, [%r0 + CTX_PSP_LO]
	shld	%r11, 0x20, %r7
	std	%r7, [%r0 + CTX_PSP_HI]

	/* стек цепочек: одна фабрикованная запись, index = CR_SIZE */
	std	%r10, [%r0 + CTX_PCSP_LO]
	shld	%r12, 0x20, %r7
	addd	%r7, CR_SIZE, %r7
	std	%r7, [%r0 + CTX_PCSP_HI]

	/* chain-запись по pcs_base + CR_SIZE: return в __coro_trampoline */
	addd	0x0, 0x0, %r8
	std	%r8, [%r10 + CR_SIZE + CR0_LO]		/* pregs = 0 */
	addd	0x0, __coro_trampoline, %r8
	std	%r8, [%r10 + CR_SIZE + CR0_HI]		/* адрес возврата */
	rrd	%psr, %r8
	andd	%r8, CR1_LO_PSR_MASK, %r8
	shld	%r8, CR1_LO_PSR_OFF, %r8		/* psr наследуется от создателя */
	rrd	%cuir, %r7
	andd	%r7, CR1_LO_CUIR_MASK, %r7
	shld	%r7, CR1_LO_CUIR_OFF, %r7
	ord	%r8, %r7, %r8
	ord	%r8, CR1_LO_WFX_BIT, %r8		/* wbs = wpsz = 0, wfx = 1 */
	std	%r8, [%r10 + CR_SIZE + CR1_LO]
	addd	0x0, BOOT_SIZE >> 4, %r8
	shld	%r8, CR1_HI_USSZ_OFF, %r8		/* ussz = BOOT_SIZE / 16 */
	std	%r8, [%r10 + CR_SIZE + CR1_HI]

	/* guard-страницы */
	cmpedb	%r14, 0x0, %pred0
	ibranch	8f ? %pred0
	nop
	GUARD_ALL PROT_NONE, 7f
8:
	addd	0x0, 0x0, %r15
9:
	addd	%r15, 0x0, %r0
	return	%ctpr3
	ct	%ctpr3
	nop
7:	/* mprotect не удался: снять то, что успели поставить (best effort) */
	GUARD_ALL PROT_RW, 9b
	ibranch	9b
	nop
	.size	coro_init_ex, .-coro_init_ex

/*
 * int coro_init(ctx, area, size, entry, arg, ret_ctx) — coro_init_ex без attr.
 */
	.globl	coro_init
	.type	coro_init, @function
coro_init:
	setwd	wsz = 0x70, nfx = 0x1
	setbn	rbs = 0x20, rsz = 0x7, rcur = 0x0
	addd	%r0, 0x0, %b[0]
	addd	%r1, 0x0, %b[1]
	addd	%r2, 0x0, %b[2]
	addd	%r3, 0x0, %b[3]
	addd	%r4, 0x0, %b[4]
	addd	%r5, 0x0, %b[5]
	addd	0x0, 0x0, %b[6]
	disp	%ctpr1, coro_init_ex
	call	%ctpr1, wbs = 0x20
	nop
	addd	%b[0], 0x0, %r0
	return	%ctpr3
	ct	%ctpr3
	nop
	.size	coro_init, .-coro_init

/*
 * void coro_destroy(coro_ctx_t *ctx) — снять guard-страницы (область снова
 * целиком доступна и может быть освобождена/переиспользована) и сделать
 * контекст непригодным для coro_transfer. Незавершённую корутину
 * уничтожать допустимо: её стеки просто бросаются.
 */
	.globl	coro_destroy
	.type	coro_destroy, @function
coro_destroy:
	setwd	wsz = 0x70, nfx = 0x1
	setbn	rbs = 0x20, rsz = 0x7, rcur = 0x0
	cmpedb	%r0, 0x0, %pred0
	ibranch	9f ? %pred0
	nop
	ldd	[%r0 + CTX_ATTR_FLAGS], %r7
	andd	%r7, CORO_ATTR_GUARD, %r7
	cmpedb	%r7, 0x0, %pred0
	ibranch	8f ? %pred0
	nop
	GUARD_ALL PROT_RW, 8f
8:
	addd	0x0, 0x0, %r7
	std	%r7, [%r0 + CTX_PSP_HI]
	std	%r7, [%r0 + CTX_PSP_LO]
	std	%r7, [%r0 + CTX_PCSP_HI]
	std	%r7, [%r0 + CTX_PCSP_LO]
	std	%r7, [%r0 + CTX_ENTRY]
	std	%r7, [%r0 + CTX_FLAGS]
	std	%r7, [%r0 + CTX_ATTR_FLAGS]
9:
	return	%ctpr3
	ct	%ctpr3
	nop
	.size	coro_destroy, .-coro_destroy

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
