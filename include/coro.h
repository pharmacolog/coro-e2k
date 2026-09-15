/*
 * coro.h — стековые кооперативные корутины (symmetric transfer) для e2k.
 *
 * Один API, два бэкенда (выбор при сборке):
 *   DIRECT   (по умолчанию) — src/coro_e2k.S: прямая запись регистров
 *            аппаратных стеков. Эмулятор qemu-e2k с патчем tools/, либо
 *            привилегированный код на железе.
 *   UCONTEXT (-DCORO_BACKEND_UCONTEXT) — src/coro_ucontext.c: поверх
 *            getcontext/makecontext/swapcontext libc; на e2k стеки
 *            переключает ядро. Пользовательский код на железе; любая POSIX-ОС.
 *
 * Модель: coro_transfer(from, to) сохраняет текущий контекст в *from и
 * продолжает *to. Корутина запускается первым coro_transfer в её ctx;
 * entry(arg) вызывается на её стеке. Когда entry возвращается, корутина
 * помечается завершённой и управление уходит в ret_ctx; повторный transfer
 * в завершённую корутину немедленно возвращает управление в ret_ctx.
 * Корутины не переносимы между потоками; ctx и area живут, пока корутина
 * может быть возобновлена.
 */
#ifndef CORO_H
#define CORO_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#if defined(CORO_BACKEND_UCONTEXT)

#include <ucontext.h>

typedef struct coro_ctx {
	ucontext_t uc;
	void (*entry)(void *);
	void *arg;
	struct coro_ctx *ret;
	uint64_t flags;
} coro_ctx_t;

#define CORO_AREA_ALIGN	16
#define CORO_MIN_AREA	(64 * 1024)

#else /* DIRECT */

/* Раскладка полей — см. src/coro_layout.h; отсюда виден только размер. */
typedef struct coro_ctx {
	uint64_t raw[12];
} __attribute__((aligned(16))) coro_ctx_t;

#define CORO_AREA_ALIGN	0x1000
#define CORO_PS_SIZE	0x4000
#define CORO_PCS_SIZE	0x1000
#define CORO_MIN_AREA	(CORO_PS_SIZE + CORO_PCS_SIZE + 0x1000)

#endif

#define CORO_FLAG_FINISHED	0x1u

/*
 * Подготовить корутину. area/size: область стеков, выровненная на
 * CORO_AREA_ALIGN, size кратен CORO_AREA_ALIGN и не меньше CORO_MIN_AREA.
 * Возвращает 0, либо -1 при некорректных аргументах.
 */
int coro_init(coro_ctx_t *ctx, void *area, size_t size,
	      void (*entry)(void *), void *arg, coro_ctx_t *ret_ctx);

/* Сохранить текущий контекст в *from и продолжить *to. */
void coro_transfer(coro_ctx_t *from, coro_ctx_t *to);

/* 1, если entry корутины уже вернулась. */
int coro_finished(const coro_ctx_t *ctx);

#ifdef __cplusplus
}
#endif

#endif /* CORO_H */
