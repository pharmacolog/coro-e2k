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
#include <sys/mman.h>
#include <unistd.h>

#if defined(__e2k__)
/* e2k glibc: освобождение аппаратных стеков, выделенных makecontext.
 * Имя функции в разных источниках — freecontext или freecontext_e2k
 * (документация MCST, гл. 3.2); слабые ссылки на оба, при отсутствии
 * символов вызов пропускается (тогда coro_destroy оставит утечку в ядре —
 * см. README, «Ограничения»). */
extern int freecontext(ucontext_t *ucp) __attribute__((weak));
extern int freecontext_e2k(ucontext_t *ucp) __attribute__((weak));
#endif

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

int coro_init_ex(coro_ctx_t *ctx, void *area, size_t size,
		 void (*entry)(void *), void *arg, coro_ctx_t *ret_ctx,
		 const coro_attr_t *attr)
{
	unsigned aflags = attr ? (unsigned)attr->flags : 0;
	long page = sysconf(_SC_PAGESIZE);
	size_t guard = 0, align = CORO_AREA_ALIGN;

	if (!ctx || !area || !entry)
		return -1;
	/* ps_size/pcs_size здесь не используются (стеки выделяет ядро), но
	 * проверяются как в DIRECT, чтобы ошибки конфигурации не зависели от бэкенда */
	if (attr && ((attr->ps_size | attr->pcs_size) & 0xfff) != 0)
		return -1;
	if (aflags & CORO_ATTR_GUARD) {
		guard = (page > CORO_GUARD_SIZE) ? (size_t)page : CORO_GUARD_SIZE;
		align = guard;
	}
	if (((uintptr_t)area & (align - 1)) != 0 || (size & (align - 1)) != 0 ||
	    size < CORO_MIN_AREA + guard)
		return -1;
	if (getcontext(&ctx->uc) != 0)
		return -1;
	/* стек растёт вниз: guard-страница — в самом низу области */
	if (guard && mprotect(area, guard, PROT_NONE) != 0)
		return -1;
	ctx->uc.uc_stack.ss_sp = (char *)area + guard;
	ctx->uc.uc_stack.ss_size = size - guard;
	ctx->uc.uc_link = 0;
	ctx->entry = entry;
	ctx->arg = arg;
	ctx->ret = ret_ctx;
	ctx->flags = 0;
	ctx->area = area;
	ctx->size = size;
	ctx->guard = guard;
	ctx->attr_flags = aflags;
	makecontext(&ctx->uc, coro_trampoline, 0);
	return 0;
}

int coro_init(coro_ctx_t *ctx, void *area, size_t size,
	      void (*entry)(void *), void *arg, coro_ctx_t *ret_ctx)
{
	return coro_init_ex(ctx, area, size, entry, arg, ret_ctx, 0);
}

void coro_destroy(coro_ctx_t *ctx)
{
	if (!ctx)
		return;
	if ((ctx->attr_flags & CORO_ATTR_GUARD) && ctx->guard)
		mprotect(ctx->area, ctx->guard, PROT_READ | PROT_WRITE);
#if defined(__e2k__)
	if (freecontext_e2k)
		freecontext_e2k(&ctx->uc);
	else if (freecontext)
		freecontext(&ctx->uc);
#endif
	ctx->entry = 0;
	ctx->flags = 0;
	ctx->attr_flags = 0;
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
