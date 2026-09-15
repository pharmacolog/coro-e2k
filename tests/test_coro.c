/*
 * test_coro.c — тесты API на C: те же сценарии, что и в ассемблерных тестах.
 * Собирается с любым бэкендом: -DCORO_BACKEND_UCONTEXT (хост, e2k user-space)
 * или без него — DIRECT (lcc + src/coro_e2k.S под qemu/привилегированный код).
 */
#include "coro.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define STACK_SZ	(0x12000)
#define ROUNDS		100000

static coro_ctx_t main_ctx, ctx1, ctx2;
static unsigned char stack1[STACK_SZ] __attribute__((aligned(0x1000)));
static unsigned char stack2[STACK_SZ] __attribute__((aligned(0x1000)));
static int failures;

#define CHECK(cond, what) do { if (!(cond)) { printf("FAIL: %s\n", what); failures++; } } while (0)

struct param { int id; coro_ctx_t *own; };

/* --- basic + finish ------------------------------------------------------ */
static void worker(void *arg)
{
	struct param *p = arg;
	for (int step = 0; step < 3; step++) {
		char buf[32];					/* кадр на стеке корутины */
		snprintf(buf, sizeof buf, "worker %d: step %d\n", p->id, step);
		fputs(buf, stdout);
		coro_transfer(p->own, &main_ctx);		/* yield */
		CHECK(strstr(buf, "step") != 0, "frame after yield");
	}
}

static void test_basic_finish(void)
{
	struct param p1 = { 1, &ctx1 }, p2 = { 2, &ctx2 };
	CHECK(coro_init(&ctx1, stack1, STACK_SZ, worker, &p1, &main_ctx) == 0, "init1");
	CHECK(coro_init(&ctx2, stack2, STACK_SZ, worker, &p2, &main_ctx) == 0, "init2");
	CHECK(!coro_finished(&ctx1), "early flag");
	puts("main: start");
	for (int i = 0; i < 4; i++) {			/* 4-й раунд — завершение */
		coro_transfer(&main_ctx, &ctx1);
		coro_transfer(&main_ctx, &ctx2);
	}
	CHECK(coro_finished(&ctx1) && coro_finished(&ctx2), "not done");
	puts("both finished");
	coro_transfer(&main_ctx, &ctx1);		/* завершённая: сразу назад */
	coro_transfer(&main_ctx, &ctx2);
	puts("resume finished ok");
}

/* --- stress ------------------------------------------------------------- */
static void stress_worker(void *arg)
{
	struct param *p = arg;
	for (uint64_t n = 0; n < ROUNDS - 1; n++) {
		volatile uint64_t marker = n ^ 0x5a5a;
		coro_transfer(p->own, &main_ctx);
		if (marker != (n ^ 0x5a5a)) { puts("FAIL: stack"); exit(1); }
	}
}

static void test_stress(void)
{
	struct param p1 = { 1, &ctx1 }, p2 = { 2, &ctx2 };
	coro_init(&ctx1, stack1, STACK_SZ, stress_worker, &p1, &main_ctx);
	coro_init(&ctx2, stack2, STACK_SZ, stress_worker, &p2, &main_ctx);
	for (int i = 0; i < ROUNDS; i++) {
		coro_transfer(&main_ctx, &ctx1);
		coro_transfer(&main_ctx, &ctx2);
	}
	CHECK(coro_finished(&ctx1) && coro_finished(&ctx2), "count");
	puts("stress: ok");
}

/* --- nested ------------------------------------------------------------- */
static int level2(coro_ctx_t *own, int v)
{
	volatile int keep = v;
	puts("level2 in");
	coro_transfer(own, &main_ctx);
	CHECK(keep == 0x3333, "level2");
	puts("level2 back");
	return keep + 1;
}

static int level1(coro_ctx_t *own, int v)
{
	volatile int keep = v;
	int r = level2(own, 0x3333);
	CHECK(r == 0x3334 && keep == 0x2222, "level1");
	puts("level1 ok");
	return keep + 1;
}

static void nested_worker(void *arg)
{
	struct param *p = arg;
	for (int i = 0; i < 2; i++) {
		int r = level1(p->own, 0x2222);
		CHECK(r == 0x2223, "level0");
		puts("level0 ok");
	}
}

static void test_nested(void)
{
	struct param p1 = { 1, &ctx1 };
	coro_init(&ctx1, stack1, STACK_SZ, nested_worker, &p1, &main_ctx);
	for (int i = 0; i < 3; i++) {
		coro_transfer(&main_ctx, &ctx1);
		puts("main: got");
	}
	CHECK(coro_finished(&ctx1), "nested");
	puts("nested: ok");
}

/* --- init errors --------------------------------------------------------- */
static void entry_ran(void *arg) { (void)arg; puts("entry ran"); }

static void test_init_errors(void)
{
	CHECK(coro_init(0, stack1, STACK_SZ, entry_ran, 0, &main_ctx) == -1, "null ctx");
	CHECK(coro_init(&ctx1, stack1, STACK_SZ, 0, 0, &main_ctx) == -1, "null entry");
	CHECK(coro_init(&ctx1, stack1 + 8, STACK_SZ, entry_ran, 0, &main_ctx) == -1, "unaligned area");
	CHECK(coro_init(&ctx1, stack1, STACK_SZ - 8, entry_ran, 0, &main_ctx) == -1, "unaligned size");
	CHECK(coro_init(&ctx1, stack1, CORO_MIN_AREA - CORO_AREA_ALIGN, entry_ran, 0, &main_ctx) == -1, "small size");
	CHECK(coro_init(&ctx1, stack1, CORO_MIN_AREA, entry_ran, 0, &main_ctx) == 0, "min size");
	coro_transfer(&main_ctx, &ctx1);
	puts("init errors: ok");
}

int main(void)
{
	setvbuf(stdout, 0, _IONBF, 0);
	test_basic_finish();
	test_stress();
	test_nested();
	test_init_errors();
	if (failures) { printf("FAILURES: %d\n", failures); return 1; }
	puts("all ok");
	return 0;
}
