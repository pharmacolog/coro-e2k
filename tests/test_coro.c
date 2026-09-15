/*
 * test_coro.c — тесты API на C: те же сценарии, что и в ассемблерных тестах.
 * Собирается с любым бэкендом: -DCORO_BACKEND_UCONTEXT (хост, e2k user-space)
 * или без него — DIRECT (lcc + src/coro_e2k.S под qemu/привилегированный код).
 */
#include "coro.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#include <sys/wait.h>
#include <unistd.h>

#define STACK_SZ	(0x20000)	/* хватает и на guard в 16 КиБ (macOS/arm64) */
#define ROUNDS		100000

static coro_ctx_t main_ctx, ctx1, ctx2;
static unsigned char stack1[STACK_SZ] __attribute__((aligned(0x10000)));
static unsigned char stack2[STACK_SZ] __attribute__((aligned(0x10000)));
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

/* --- attrs / guard / destroy ------------------------------------------- */
static int recurse(int n) { volatile int k = n; return k ? k + recurse(k - 1) : 0; }

static void attrs_worker(void *arg)
{
	(void)arg;
	CHECK(recurse(200) == 200 * 201 / 2, "depth");
	puts("depth: ok");
}

static void guard_worker(void *arg)
{
	volatile char *p = arg;
	puts("before fault");
	p[0] = 1;					/* guard-страница -> SIGSEGV */
	puts("FAIL: no fault");
	exit(1);
}

static void test_attrs(void)
{
	coro_attr_t attr = { 0xC000, 0x2000, CORO_ATTR_GUARD };
	coro_attr_t bad = { 0xC000 + 0x10, 0, 0 };
	CHECK(coro_init_ex(&ctx1, stack1, STACK_SZ, attrs_worker, 0, &main_ctx, &bad) == -1, "bad align attr");
	CHECK(coro_init_ex(&ctx1, stack1 + 8, STACK_SZ, attrs_worker, 0, &main_ctx, &attr) == -1, "guard needs page align");
	CHECK(coro_init_ex(&ctx1, stack1, STACK_SZ, attrs_worker, 0, &main_ctx, &attr) == 0, "init attrs");
	coro_transfer(&main_ctx, &ctx1);
	CHECK(coro_finished(&ctx1), "attrs finished");
	coro_destroy(&ctx1);
	stack1[0] = 0x77;				/* guard снят */
	CHECK(stack1[0] == 0x77, "destroy");
	puts("destroy: ok");

	/* guard действительно защищает: в дочернем процессе ждём SIGSEGV */
	fflush(stdout);
	pid_t pid = fork();
	if (pid == 0) {
		coro_attr_t g = { 0, 0, CORO_ATTR_GUARD };
		if (coro_init_ex(&ctx2, stack2, STACK_SZ, guard_worker, stack2, &main_ctx, &g) != 0)
			_exit(2);
		coro_transfer(&main_ctx, &ctx2);
		_exit(3);
	}
	int st = 0;
	waitpid(pid, &st, 0);
	CHECK(WIFSIGNALED(st) && (WTERMSIG(st) == SIGSEGV || WTERMSIG(st) == SIGBUS), "guard fault");
	puts("guard: ok");
	/* уничтожение незавершённой корутины */
	coro_attr_t g = { 0, 0, CORO_ATTR_GUARD };
	struct param p1 = { 1, &ctx1 };
	CHECK(coro_init_ex(&ctx1, stack1, STACK_SZ, worker, &p1, &main_ctx, &g) == 0, "init2");
	coro_transfer(&main_ctx, &ctx1);		/* step 0, корутина жива */
	coro_destroy(&ctx1);
	stack1[0] = 0x55;
	CHECK(stack1[0] == 0x55, "destroy live");
	puts("attrs: ok");
}

int main(void)
{
	setvbuf(stdout, 0, _IONBF, 0);
	test_basic_finish();
	test_stress();
	test_nested();
	test_init_errors();
	test_attrs();
	if (failures) { printf("FAILURES: %d\n", failures); return 1; }
	puts("all ok");
	return 0;
}
