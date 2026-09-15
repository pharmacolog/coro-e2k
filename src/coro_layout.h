/*
 * coro_layout.h — константы раскладки для бэкенда DIRECT (asm и C).
 * Значения смещений — часть ABI библиотеки; менять синхронно с include/coro.h.
 */
#ifndef CORO_LAYOUT_H
#define CORO_LAYOUT_H

/* блок контекста */
#define CTX_PSP_HI	0x00
#define CTX_PSP_LO	0x08
#define CTX_PCSP_HI	0x10
#define CTX_PCSP_LO	0x18
#define CTX_USD_HI	0x20
#define CTX_USD_LO	0x28
#define CTX_SBR		0x30
#define CTX_ARG		0x38
#define CTX_RET		0x40
#define CTX_ENTRY	0x48
#define CTX_FLAGS	0x50
#define CTX_RESERVED	0x58
#define CORO_CTX_SIZE	0x60

#define CORO_FLAG_FINISHED	0x1

/* раскладка области стеков */
#define CORO_AREA_ALIGN	0x1000
#define CORO_PS_SIZE	0x4000		/* стек процедур: 16 КиБ */
#define CORO_PCS_SIZE	0x1000		/* стек цепочек: 4 КиБ = 128 вложенных вызовов */
#define CORO_MIN_DATA	0x1000
#define CORO_MIN_AREA	(CORO_PS_SIZE + CORO_PCS_SIZE + CORO_MIN_DATA)
#define BOOT_SIZE	0x20		/* вершина стека данных: own_ctx + резерв */

/* chain-запись (CR) */
#define CR_SIZE		0x20
#define CR0_LO		0x00
#define CR0_HI		0x08
#define CR1_LO		0x10
#define CR1_HI		0x18
#define CR1_LO_WFX_BIT	0x2000000	/* бит 25 */
#define CR1_LO_CUIR_OFF	40
#define CR1_LO_CUIR_MASK 0x1ffff	/* 17 бит */
#define CR1_LO_PSR_OFF	57
#define CR1_LO_PSR_MASK	0x7f		/* 7 бит */
#define CR1_HI_USSZ_OFF	36

/* регистр подготовки перехода */
#define CTPR_TAG_OFF	54
#define CTPR_TAG_DISP	0x3

#endif /* CORO_LAYOUT_H */
