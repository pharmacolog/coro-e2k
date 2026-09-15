# coro-e2k — сборка и проверка.
#
#   make check-emu   — бэкенд DIRECT: сборка тестов e2k и прогон под qemu-e2k
#   make check-host  — бэкенд UCONTEXT: C-тест на хосте (любая POSIX-система)
#   make check       — оба
#
# Переменные: E2K_PREFIX (по умолчанию e2k-linux-gnu-), QEMU_E2K (qemu-e2k),
#             CPP (хостовый препроцессор для .S).

E2K_PREFIX ?= e2k-linux-gnu-
E2K_AS     ?= $(E2K_PREFIX)as
E2K_LD     ?= $(E2K_PREFIX)ld
QEMU_E2K   ?= qemu-e2k
CPP        ?= cpp
CC         ?= cc
BUILD      ?= build

TESTS_EMU := basic finish stress nested frame init_errors attrs guard_fault
EMU_BINS  := $(addprefix $(BUILD)/emu/test_,$(TESTS_EMU))

.PHONY: all check check-emu check-host clean

all: $(BUILD)/emu/coro_e2k.o

check: check-emu check-host

# ---- DIRECT (e2k, эмулятор) -------------------------------------------------

$(BUILD)/emu/%.s: src/%.S src/coro_layout.h | $(BUILD)/emu
	$(CPP) -P -x assembler-with-cpp -Isrc $< -o $@

$(BUILD)/emu/%.s: tests/%.S tests/test_common.inc src/coro_layout.h | $(BUILD)/emu
	$(CPP) -P -x assembler-with-cpp -Isrc -Itests $< -o $@

$(BUILD)/emu/%.o: $(BUILD)/emu/%.s
	$(E2K_AS) -o $@ $<

$(BUILD)/emu/test_%: $(BUILD)/emu/test_%.o $(BUILD)/emu/coro_e2k.o
	$(E2K_LD) -o $@ $(BUILD)/emu/coro_e2k.o $<

$(BUILD)/emu:
	mkdir -p $@

check-emu: $(EMU_BINS)
	@fail=0; for t in $(TESTS_EMU); do \
	  exp=tests/test_$$t.expected; out=$(BUILD)/emu/test_$$t.out; \
	  want=0; [ -f tests/test_$$t.exitcode ] && want=$$(cat tests/test_$$t.exitcode); \
	  $(QEMU_E2K) $(BUILD)/emu/test_$$t > $$out 2>$$out.err; rc=$$?; \
	  if [ $$rc -eq $$want ] && diff -u $$exp $$out > $$out.diff; then echo "PASS test_$$t"; \
	  else echo "FAIL test_$$t (exit=$$rc)"; cat $$out.diff; tail -5 $$out; fail=1; fi; \
	done; exit $$fail

# ---- UCONTEXT (хост / e2k user-space через ядро) ----------------------------

$(BUILD)/host:
	mkdir -p $@

$(BUILD)/host/test_coro: tests/test_coro.c src/coro_ucontext.c include/coro.h | $(BUILD)/host
	$(CC) -std=c11 -O2 -Wall -Wextra -D_XOPEN_SOURCE=700 -DCORO_BACKEND_UCONTEXT \
	  -Iinclude tests/test_coro.c src/coro_ucontext.c -o $@

check-host: $(BUILD)/host/test_coro
	@$(BUILD)/host/test_coro > $(BUILD)/host/test_coro.out 2>&1; rc=$$?; \
	if [ $$rc -eq 0 ] && diff -u tests/test_coro.expected $(BUILD)/host/test_coro.out; \
	then echo "PASS test_coro (ucontext, host)"; else echo "FAIL test_coro (exit=$$rc)"; cat $(BUILD)/host/test_coro.out; exit 1; fi

clean:
	rm -rf $(BUILD)
