# coro-e2k — стековые корутины для архитектуры e2k («Эльбрус»)

[![check](https://github.com/pharmacolog/coro-e2k/actions/workflows/check.yml/badge.svg)](https://github.com/pharmacolog/coro-e2k/actions/workflows/check.yml)

Симметричные кооперативные корутины (`coro_transfer(from, to)`) в духе
`transfer_*` из iris/boost.context, но для e2k с её регистровыми окнами и
тремя аппаратными стеками: стеком данных (USD/USBR), стеком процедур (PS,
регистр PSP) и стеком цепочек вызовов (PCS, регистр PCSP).

Один API — два бэкенда, выбираемых при сборке:

| Бэкенд | Файл | Где применим | Как переключает |
|---|---|---|---|
| **DIRECT** (по умолчанию) | `src/coro_e2k.S` | qemu‑e2k linux‑user с патчем из `tools/`; на железе — только привилегированный код (ядро, гипервизор, bare‑metal) | прямая запись PSP/PCSP/USD/USBR + `return`/`ct` с чужого стека цепочек |
| **UCONTEXT** (`-DCORO_BACKEND_UCONTEXT`) | `src/coro_ucontext.c` | пользовательский код на железе под Linux (glibc e2k), любая POSIX‑ОС | `getcontext/makecontext/swapcontext`; на e2k стеки переключает ядро (syscalls 370/371) |

Почему два: регистры PSP/PCSP на e2k привилегированы. В user‑space на железе
их переключает только ядро (так устроен `swapcontext` в glibc e2k), а
qemu‑e2k эти системные вызовы не реализует (`do_swapcontext: TODO`).
Единого бинарного пути «эмулятор + user‑space железа» не существует;
DIRECT‑бэкенд в эмуляторе играет роль отсутствующей поддержки ядра.

## API (`include/coro.h`)

```c
typedef struct coro_attr { uint64_t ps_size, pcs_size, flags; } coro_attr_t;

int  coro_init_ex(coro_ctx_t *ctx, void *area, size_t size,
                  void (*entry)(void *), void *arg, coro_ctx_t *ret_ctx,
                  const coro_attr_t *attr);
int  coro_init(coro_ctx_t *ctx, void *area, size_t size,
               void (*entry)(void *), void *arg, coro_ctx_t *ret_ctx);  /* attr = NULL */
void coro_transfer(coro_ctx_t *from, coro_ctx_t *to);
int  coro_finished(const coro_ctx_t *ctx);
void coro_destroy(coro_ctx_t *ctx);
```

* `coro_init_ex` готовит корутину в области `area` размера `size`
  (`area` выровнена на `CORO_AREA_ALIGN`, `size` кратен ему и достаточен
  для стеков); возвращает 0 или −1 при некорректных аргументах,
  недостаточном размере или ошибке `mprotect`. `attr` (нулевое поле —
  умолчание): `ps_size`/`pcs_size` — размеры стека процедур и стека цепочек
  (DIRECT; кратны 4 КиБ; по умолчанию 16 КиБ и 4 КиБ ≈ 128 вложенных
  вызовов), `flags = CORO_ATTR_GUARD` — guard‑страницы `PROT_NONE` через
  `mprotect`: под стеком данных и над PS и PCS (DIRECT), под стеком
  (UCONTEXT). С guard `area` выравнивается на страницу ОС.
* `coro_destroy` снимает guard‑страницы (область можно освободить или
  переиспользовать) и делает `ctx` непригодным для `coro_transfer`;
  допустимо для незавершённой корутины (её стеки просто бросаются). На e2k в
  UCONTEXT дополнительно зовёт `freecontext` (слабая ссылка). Не вызывать
  из самой корутины.
* Первый `coro_transfer(x, ctx)` запускает `entry(arg)` на стеке корутины по
  штатному ABI (аргумент в `%r0`). Когда `entry` возвращается, корутина
  помечается завершённой, управление уходит в `ret_ctx`; повторный
  `coro_transfer` в завершённую корутину сразу возвращает управление в
  `ret_ctx` (процесс не завершается).
* Контекст «главного потока» — обычный `coro_ctx_t`, инициализировать не
  нужно: он заполняется первым `coro_transfer(main, …)`.
* Корутины не переносятся между потоками; `ctx` и `area` должны жить, пока
  корутину можно возобновить. Обработка сигналов внутри корутин и отмена с
  раскруткой стека — вне объёма (`coro_destroy` просто бросает стеки).

## Как устроен DIRECT‑бэкенд

Раскладка `area` (`src/coro_layout.h`, всё кратно 4 КиБ; `[G]` — guard‑страницы
только при `CORO_ATTR_GUARD`), снизу вверх:

```
area        [G]              guard под стеком данных
            data_sz          стек данных, растёт ВНИЗ от sbr; верхние 32 байта — own_ctx
sbr         ps_size          стек процедур PS, растёт вверх
            [G]
            pcs_size         стек цепочек PCS, растёт вверх
            [G]
area + size
data_sz = size − ps_size − pcs_size − 3·G  (≥ 4 КиБ)
```

`coro_transfer`: `setwd` до архитектурного максимума (окно вызывающего
неизвестно, а уменьшать окно ниже области параметров нельзя), `flushr`/`flushc`
(регистровый файл и кэш chain‑записей — в память; в qemu это no‑op, на железе
обязательно), сохранение семи регистров стеков в `*from`, загрузка из `*to`,
затем `return %ctpr3` + `ct %ctpr3`: chain‑запись снимается уже с чужого PCS,
окно вызывающего восстанавливается из чужого PS, управление уходит туда, где
`to` в прошлый раз вошла в `coro_transfer`. Регистры окна самой
`coro_transfer` сохранять не нужно — в неё не возвращаются.

`coro_init` кладёт на пустой PCS одну фабрикованную chain‑запись
(`cr0.hi = __coro_trampoline`, `wbs = wpsz = 0`, `wfx = 1`, `psr`/`cuir`
наследуются от создателя, `ussz = 32 байта`). Первый `return` «возвращается»
на трамплин, который читает `own_ctx` с вершины стека данных, вызывает
`entry(arg)` косвенным `movtd`→`%ctpr1`+`call`, а по возврате выставляет
флаг и уходит в `ret_ctx`.

Переполнение PS/PCS. На железе с guard‑страницами ожидается исключение на
первой записи за границу (не проверено). **В qemu linux‑user guard над PS/PCS
не работает**: при исчерпании стека эмулятор вызывает `stack_expand` —
`mremap(…, MREMAP_MAYMOVE)` вырезает область стека из вашего mapping'а и
переносит её, рекурсия продолжается, и лишь позже qemu падает *хостовым*
SIGBUS (проверено: бесконечная рекурсия при PCS 4 КиБ прошла > 256 вызовов).
Guard под стеком данных в qemu работает (стек данных эмулятор не расширяет).
Задавайте `ps_size`/`pcs_size` по ожидаемой глубине вызовов (32 байта PCS
на вызов; PS — по размерам окон) и не полагайтесь на переполнение в эмуляторе.

## Сборка и проверка

Требуется: `cpp` хоста (препроцессор для `.S`), OpenE2K binutils
(`e2k-linux-gnu-as/ld`), qemu‑e2k с патчем `tools/qemu-e2k-user-hwstacks.patch`.
Всё это собирает `tools/build-toolchain.sh` (или `tools/Dockerfile`):

```bash
docker build -t coro-e2k-lab -f tools/Dockerfile .
docker run --rm -v "$PWD":/src -w /src coro-e2k-lab make check
```

Цели `make`:

* `check-emu` — DIRECT: собирает `src/coro_e2k.S` и восемь ассемблерных тестов
  (`tests/test_*.S`), гоняет под `qemu-e2k`, сверяет вывод с
  `tests/*.expected` и код возврата (`tests/*.exitcode`, по умолчанию 0).
  Переменные: `E2K_PREFIX`, `QEMU_E2K`, `CPP`.
* `check-host` — UCONTEXT: `tests/test_coro.c` + `src/coro_ucontext.c` на
  хосте (Linux, macOS, …) — те же сценарии, что и в ассемблерных тестах.
* `check` — обе.

CI (`.github/workflows/check.yml`): `check-host` на Ubuntu и macOS, `check`
целиком — в стенде из `tools/Dockerfile` (образ кешируется по содержимому `tools/`).

Сценарии тестов: базовое чередование двух корутин с состоянием в регистровом
окне и кадром на собственном стеке; завершение (`entry` вернулась → `ret_ctx`,
флаг, повторное возобновление завершённой); стресс 100 000 раундов × 2 корутины
с проверкой кадра через yield; yield из глубины трёх вложенных процедур с живыми
регистрами и кадрами на каждом уровне; геометрия стека данных (SP на вершине,
кадр `getsp −N` внутри области); отказы `coro_init`; атрибуты
(`ps_size`/`pcs_size`, рекурсия глубиной 200 при PCS 8 КиБ, `coro_destroy`
снимает guard); guard‑страница действительно защищена (ожидаемый SIGSEGV,
exit 139).

### На e2k‑машине (железо, lcc + native binutils)

Тулчейн: `lcc` (препроцессор и компилятор C), native `as`/`ld` из
binutils MCST; `cpp` берётся из lcc. Стенд с qemu не нужен.

**UCONTEXT — пользовательский код (это и есть штатный режим на железе):**

```bash
make CC=lcc check-host
```

Цель собирает `tests/test_coro.c` + `src/coro_ucontext.c` с
`-DCORO_BACKEND_UCONTEXT`, запускает и сверяет вывод с
`tests/test_coro.expected`; ожидаемый итог — `PASS test_coro (ucontext, host)`.
Подключение в проект: `lcc -O2 -DCORO_BACKEND_UCONTEXT -Iinclude -c src/coro_ucontext.c`.

**DIRECT — только привилегированный код.** Библиотека и ассемблерные тесты
собираются native‑тулчейном:

```bash
make E2K_PREFIX= CPP='lcc -E' all                       # build/emu/coro_e2k.o
make E2K_PREFIX= CPP='lcc -E' build/emu/test_basic      # тестовые бинарники
```

Запускать `build/emu/test_*` в user‑space на железе **нельзя**: первый же
`rwd %psp.hi` — привилегированное действие, процесс получит SIGILL
(ровно то, что показывает qemu без патча). Прогон DIRECT‑тестов на железе
возможен только из привилегированного окружения (модуль ядра, гипервизор,
bare‑metal), куда переносится `src/coro_e2k.S` и логика тестов; такой
стенд в репозитории не предусмотрен. Полный `make check` на железе поэтому
не применим — используйте `check-host`.

## Патч qemu

`tools/qemu-e2k-user-hwstacks.patch` разрешает в linux‑user запись в
PSP/PCSP/USD/USBR (чтение там и так непривилегированно). Это единственное
изменение эмулятора, которое нужно; семантика инструкций не меняется.
Проверено на OpenE2K/qemu‑e2k, ветка `e2k`, коммит `ebc4bbd`.

## Статус проверки

| Что | Где | Результат |
|---|---|---|
| DIRECT, 8 тестов | qemu‑e2k + патч (Linux/arm64, Docker) | PASS; 400 000 переключений за 0,1 с |
| DIRECT, 8 тестов | qemu‑e2k без патча | SIGILL на первом `rwd %psp.hi` — ожидаемо |
| UCONTEXT, C‑тест | Linux/arm64 glibc, macOS (страница 16 КиБ, SIGBUS на guard) | PASS |
| DIRECT на железе (привилегированный режим) | — | **не проверялось**: нет доступа к машине |
| UCONTEXT на железе (glibc e2k, lcc) | — | **не проверялось**; путь штатный для glibc |

Что нужно подтвердить на железе для DIRECT: достаточность `flushr`/`flushc`
перед чтением PSP/PCSP (PSHTP/PCSHTP после них нулевые), допустимость
записи `cr1.psr` из фабрикованной записи, отсутствие требования `wait`
между записью PCSP и `ct`, установка тега DISP при `movtd` в `%ctpr`
(трамплин). Для UCONTEXT — сборка lcc, `freecontext` (слабая ссылка;
существование и сигнатура в glibc e2k не проверены — при отсутствии символа
аппаратные стеки ядра после `coro_destroy` утекут).

## Ограничения

* **Не проверено на физическом «Эльбрусе»** — ни один бэкенд (см. таблицу).
* **DIRECT в user‑space на железе неприменим**: регистры стеков
  привилегированы. В пользовательских программах остаётся UCONTEXT — а это
  `swapcontext` через ядро: **каждое переключение — системный вызов**
  (на порядки дороже переключения в user‑space на x86/ARM). Для
  высокочастотных переключений измеряйте на железе до принятия решения.
* Guard‑страницы требуют `mprotect`, т.е. ОС: в DIRECT это syscall из
  ассемблера (Linux/qemu); в привилегированном окружении `CORO_ATTR_GUARD`
  неприменим — защита границ ложится на среду. В qemu guard срабатывает
  только под стеком данных; над PS/PCS его опережает `stack_expand`
  эмулятора (см. выше), на железе срабатывание не проверено.
* Контекст DIRECT не включает `%g`‑регистры и FP/векторное состояние сверх
  того, что уносят chain‑записи; код, держащий живые значения в `%g` через
  `coro_transfer`, сломается. Сигналы, пришедшие внутри корутины, не
  тестировались; корутины не переносимы между потоками.
* `cuir` наследуется от создателя; тесты статические — динамическая линковка
  и protected mode не проверялись.
* Тулчейн: проверено только на binutils MCST 2.41 (OpenE2K) и qemu‑e2k
  `ebc4bbd`; сборка lcc — только `make -n`.

## Состав репозитория

```
include/coro.h            API (оба бэкенда)
src/coro_e2k.S            DIRECT: coro_transfer / coro_init(_ex) / coro_destroy / coro_finished / трамплин
src/coro_layout.h         смещения и константы раскладки (ABI DIRECT)
src/coro_ucontext.c       UCONTEXT-бэкенд
tests/test_*.S + .expected [+ .exitcode]  ассемблерные тесты (эмулятор)
tests/test_common.inc     макросы тестов
tests/test_coro.c + .expected C-тест (любой бэкенд)
tools/qemu-e2k-user-hwstacks.patch
tools/build-toolchain.sh, tools/Dockerfile   воспроизводимый стенд
REVIEW.md                 отчёт ревьюера по исходному решению и его доработке
LICENSE                   MIT
```

## Лицензия

MIT — см. `LICENSE`. Патч в `tools/` относится к qemu (GPL‑2.0) и распространяется
на его условиях.
