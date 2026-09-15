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
	void *area;
	size_t size;
	size_t guard;		/* фактический размер guard-страницы (страница ОС) */
	unsigned attr_flags;
} coro_ctx_t;

#define CORO_AREA_ALIGN	16
#define CORO_GUARD_SIZE	0x1000		/* минимум; с CORO_ATTR_GUARD берётся страница ОС, area выравнивается на неё */
#define CORO_MIN_AREA	(64 * 1024)

#else /* DIRECT */

/* Раскладка полей — см. src/coro_layout.h; отсюда виден только размер. */
typedef struct coro_ctx {
	uint64_t raw[16];
} __attribute__((aligned(16))) coro_ctx_t;

#define CORO_AREA_ALIGN	0x1000
#define CORO_PS_SIZE	0x4000		/* стек процедур по умолчанию */
#define CORO_PCS_SIZE	0x1000		/* стек цепочек по умолчанию (~128 вложенных вызовов) */
#define CORO_GUARD_SIZE	0x1000
/* минимум для размеров по умолчанию без guard; с attr считайте:
 * ps_size + pcs_size + 0x1000 (+ 3*CORO_GUARD_SIZE при CORO_ATTR_GUARD) */
#define CORO_MIN_AREA	(CORO_PS_SIZE + CORO_PCS_SIZE + 0x1000)

#endif

#define CORO_FLAG_FINISHED	0x1u

/* Атрибуты coro_init_ex. Нулевое поле — значение по умолчанию. */
typedef struct coro_attr {
	uint64_t ps_size;	/* DIRECT: стек процедур, кратен 0x1000; UCONTEXT: игнорируется */
	uint64_t pcs_size;	/* DIRECT: стек цепочек, кратен 0x1000; UCONTEXT: игнорируется */
	uint64_t flags;		/* CORO_ATTR_* */
} coro_attr_t;

#define CORO_ATTR_GUARD		0x1u	/* guard-страницы PROT_NONE вокруг стеков (mprotect) */

/*
 * Подготовить корутину. area/size: область стеков, выровненная на
 * CORO_AREA_ALIGN (на страницу при CORO_ATTR_GUARD), size кратен
 * выравниванию и достаточен для стеков (+ guard-страницы).
 * Возвращает 0, либо -1 (некорректные аргументы, недостаточный size,
 * ошибка mprotect).
 */
int coro_init_ex(coro_ctx_t *ctx, void *area, size_t size,
		 void (*entry)(void *), void *arg, coro_ctx_t *ret_ctx,
		 const coro_attr_t *attr);

/* coro_init_ex с attr == NULL: размеры по умолчанию, без guard. */
int coro_init(coro_ctx_t *ctx, void *area, size_t size,
	      void (*entry)(void *), void *arg, coro_ctx_t *ret_ctx);

/*
 * Уничтожить корутину (завершённую или нет): снять guard-страницы, чтобы
 * area можно было освободить или переиспользовать, и сделать ctx
 * непригодным для coro_transfer. На e2k в UCONTEXT-бэкенде дополнительно
 * освобождает ресурсы ядра (freecontext). Не вызывать из самой корутины.
 */
void coro_destroy(coro_ctx_t *ctx);

/* Сохранить текущий контекст в *from и продолжить *to. */
void coro_transfer(coro_ctx_t *from, coro_ctx_t *to);

/* 1, если entry корутины уже вернулась. */
int coro_finished(const coro_ctx_t *ctx);

#ifdef __cplusplus
}
#endif

#endif /* CORO_H */
