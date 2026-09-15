/*
 * coro_ucontext.c — бэкенд UCONTEXT: те же coro_init/coro_transfer/
 * coro_finished поверх ucontext(3). На e2k glibc реализует make/swapcontext
 * через системные вызовы ядра (makecontext=370, swapcontext=371), которое и
 * переключает аппаратные стеки PS/PCS, — единственный путь для
 * непривилегированного кода на железе.
 *
 * Собирать с -DCORO_BACKEND_UCONTEXT (заголовок выбирает раскладку ctx).
 */
#include "coro.h"

#include <stdint.h>

#define CORO_FLAG_STARTED	0x2u

/* Контекст, стартующий прямо сейчас: makecontext не передаёт указатель
 * переносимо, поэтому трамплин забирает его отсюда. Потокобезопасно:
 * корутины не мигрируют между потоками. */
static __thread coro_ctx_t *coro_starting;

static void coro_trampoline(void)
{
	coro_ctx_t *c = coro_starting;

	coro_starting = 0;
	c->entry(c->arg);
	c->flags |= CORO_FLAG_FINISHED;
	for (;;)
		coro_transfer(c, c->ret);
}

int coro_init(coro_ctx_t *ctx, void *area, size_t size,
	      void (*entry)(void *), void *arg, coro_ctx_t *ret_ctx)
{
	if (!ctx || !area || !entry)
		return -1;
	if (((uintptr_t)area & (CORO_AREA_ALIGN - 1)) != 0 ||
	    (size & (CORO_AREA_ALIGN - 1)) != 0 || size < CORO_MIN_AREA)
		return -1;
	if (getcontext(&ctx->uc) != 0)
		return -1;
	ctx->uc.uc_stack.ss_sp = area;
	ctx->uc.uc_stack.ss_size = size;
	ctx->uc.uc_link = 0;
	ctx->entry = entry;
	ctx->arg = arg;
	ctx->ret = ret_ctx;
	ctx->flags = 0;
	makecontext(&ctx->uc, coro_trampoline, 0);
	return 0;
}

void coro_transfer(coro_ctx_t *from, coro_ctx_t *to)
{
	if (!(to->flags & CORO_FLAG_STARTED)) {
		to->flags |= CORO_FLAG_STARTED;
		coro_starting = to;
	}
	swapcontext(&from->uc, &to->uc);
}

int coro_finished(const coro_ctx_t *ctx)
{
	return (ctx->flags & CORO_FLAG_FINISHED) != 0;
}
