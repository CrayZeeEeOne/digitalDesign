# DF5 — MicroBlaze: TFT (ST7789) + SD/FatFs + I/Q replay і FSK-демодулятор

> **Версія v0.4.2, стан на 2026-10-15.** На залізі працює: MicroBlaze + SPI-контролер TFT + кнопки, а на дисплеї —
> графічний переглядач (12 екранів у тому самому порядку, що `vivado/sources/sim_data/rtl_demod_plots.html`).
> RTL FSK-демодулятор (`rtl_demod`, `iq_stream`) готовий **лише в симуляції** і в Block Design ще не доданий.
> SD/FatFs (Блок 2) не починали. Постановка задачі: `../readme.md`.

Платформа: PA35T-StarLite, `xc7a35tfgg484-2`, топ `microblaze_wrapper`, Vivado/Vitis 2025.2.1.
MicroBlaze 100 МГц, 32 КБ LMB BRAM (код + дані + стек), без кешів і без апаратного множника (`-mxl-soft-mul`).
Дисплей ST7789, 320×240 (ROT_90), SPI 12.5 МГц.

## Структура
```
AXI_FIFO_Modulator/
  scripts/             build.bat / build.tcl / run.tcl — Vivado-потік; create_bd.tcl — Block Design;
                       build_elf.bat — прошивка; run_board.tcl — залити bit+ELF по JTAG
  vivado/sources/rtl/  весь синтезований RTL (у BD зараз лише tft_top і system_ctrl_top)
  vivado/sources/tb/   самоперевірні тестбенчі xsim
  vivado/sources/bd/   ЗГЕНЕРОВАНЕ: робоча копія BD (у git не йде, відтворюється з create_bd.tcl)
  vivado/sources/sim_data/  sim.iq + очікувані результати + rtl_demod_plots.html (еталонні графіки)
  vivado/constraints/  tft.xdc (TFT, кнопки, такт)
  vitis/src/           прошивка за шарами (залежності лише вниз):
    main.c, config.h     init + головний цикл; усі параметри системи (Fs, частоти, запис)
    app/                 viewer (екрани, кнопки), capture (запис), view_capture, view_spectrum
    source/              iq_source.h (інтерфейс джерела I/Q), src_synth (тестовий сигнал)
    dsp/                 nco_mixer → decimator → discriminator → burst_detect → bit_decoder, FFT
    gfx/                 tft (ST7789), font5x7, plot (примітиви графіків)
    hal/                 spi_tft, system_ctrl — драйвери блоків PL
  vitis/bsp/           мінімальний bare-metal BSP: crt0.S, linker-скрипт, xparameters.h з адресами BD
  vitis/elf/           ЗГЕНЕРОВАНЕ: df5_app.elf — те, що заливається на плату
  tools/               Python: iqgen (генератор I/Q), demod_model (золота модель), plot_rtl_demod (HTML-графіки)
  tools/host_sim/      ПК-емулятор: усі 12 екранів у PNG без плати + порівняння з golden.md5
  docs/                block1_tft.md — мапа регістрів SPI TFT і піни
```

## Що зараз у залізі (Block Design `microblaze`)
| Блок | Адреса | Що робить |
|---|---|---|
| `microblaze_0` + LMB BRAM | `0x0000_0000`–`0x0000_7FFF` | 32 КБ на код, дані та стек |
| `tft_top` (`spi_tft_ctrl`) | `0x0001_0000` | AXI4-Lite → SPI master до ST7789, TX FIFO 16 байт, ID `0x5F778901` |
| `system_ctrl_top` | `0x44A1_0000` | кнопки KEY1/KEY2 з антидребезгом і подіями (W1C), LED, TICK, дільник SD-SPI |
| `clk_wiz`, `proc_sys_reset`, `mdm`, AXI interconnect | — | такт 100 МГц, скиди, JTAG-дебаг |

Мапа регістрів TFT — [`docs/block1_tft.md`](docs/block1_tft.md); system_ctrl — `vitis/src/hal/system_ctrl.h`.
Де зберігаються дані графіків — [`docs/graph_data_storage.md`](docs/graph_data_storage.md).

## Версії: що означає кожна цифра

Одна версія на весь проєкт: **`vMAJOR.MINOR.PATCH`**. Бітстрім і прошивка (ELF) мають одну версію,
бо працюють лише в парі: прошивка знає адреси й регістри конкретного Block Design.

### MAJOR — який блок ТЗ здано на платі
MAJOR рахує блоки з `../readme.md`, що пройшли **всі** свої критерії готовності на реальній платі
(не в симуляції). Тобто MAJOR відповідає на питання «що вже можна показати як готове».

| MAJOR | Що означає |
|---|---|
| `0.x.x` | bring-up: щось працює, але жоден блок ТЗ ще не прийнято повністю (**ми тут**) |
| `1.x.x` | Блок 1 здано: TFT ініціалізується без зависань, `TFT TEST` і кольорові області, SPI-сигнали перевірені осцилографом/ILA, є приклад використання драйвера |
| `2.x.x` | Блок 2 здано: FatFs читає файл блоками до EOF, коректні помилки (нема карти / mount / open / read), `test.img` RGB565 з SD без спотворень на TFT |
| `3.x.x` | Блок 3 здано: I/Q-файл із SD → replay → RTL-демодулятор **у залізі** → декодовані пакети + графіки на TFT, результат збігається з `sim.expect.txt` |
| `4.x.x`+ | зміни після здачі, що ламають сумісність із попереднім MAJOR (інша плата/частина, інший формат I/Q-файлу тощо) |

MAJOR ніколи не підіймається «за обсяг роботи», лише за прийнятий на платі блок.

### MINOR — нова можливість або зміна інтерфейсу між залізом і прошивкою
MINOR росте, коли з'являється щось нове, що видно на платі чи в симуляції, **або** коли змінюється
контракт між RTL і C: Block Design, адреси, мапа регістрів, піни.

* новий RTL-блок чи тестбенч, новий екран переглядача, нова функція драйвера;
* додано/прибрано IP у BD, змінено адресу або біти регістра, змінено `.xdc`-піни.

Правило сумісності: **бітстрім і ELF з однаковим `MAJOR.MINOR` сумісні між собою**. Після зміни MINOR
треба перезібрати і бітстрім, і прошивку (`build.bat -board`).

### PATCH — виправлення без нових можливостей
PATCH росте за фікси, які не додають функцій і не змінюють інтерфейс RTL↔C: виправлення помилки,
таймінгу, геометрії, значень після скиду, скриптів збірки. Можна оновити щось одне — тільки бітстрім
або тільки ELF — у межах того самого `MAJOR.MINOR`.

Зміни лише в документації (`STATUS.md`, `docs/`) версію не змінюють.

### Як ставити версію
1. Запис у «Історія версій» нижче: версія, дата, що змінилось, що перевірено (симуляція / плата).
2. Після того як зміну перевірено, git-тег на коміт: `git tag v0.4.1`.
3. Сумнів між MINOR і PATCH → питання одне: «чи треба після цього перезбирати *обидві* частини?»
   Так → MINOR, ні → PATCH.

## Історія версій

* **v0.1.0** (2026-09-21 … 2026-10-12, коміти `296f843` … `07eaf2f`) — каркас DF5. Скриптовий
  Vivado-потік (`build.bat -syn/-impl/-xsa/-all/-board`), `spi_tft_ctrl` + `tft_top`, `system_ctrl` з
  кнопками, BD з MicroBlaze; бітстрім зібрано, таймінг закрито. У симуляції — RTL 2-FSK/GFSK
  демодулятор: `demod_nco_mixer` → `demod_cic3` → `demod_discriminator` (CORDIC atan2) → `demod_power`
  → `demod_bit_decoder`, обгортки `rtl_demod_regs`/`rtl_demod_top` і `iq_stream_*`; `sim.iq`
  (`iqgen.py`), золота модель `demod_model.py`, еталонні графіки `rtl_demod_plots.html`.
* **v0.2.0** (2026-10-13) — новий застосунок: `graph_viewer` на MicroBlaze, 12 екранів як у HTML,
  перемикання K1/K2. У моделі детектора виправлено: `age` завжди був 0 (SYNC/PRE/PKT не вмикались),
  оцінка шуму підтягувалась до сигналу (burst гас через ~0.5 мс), провали посеред пакета → заморожування
  шуму під час burst і hangover 16 відліків. Тестове джерело в `main.c`: 2-FSK на −250 кГц, ±50 кГц,
  пакети 192 символи / паузи 128. Перевірено на платі (JTAG) і ПК-рендером.
* **v0.3.0** (2026-10-13) — нова поведінка: графіки не прокручуються. Один запис 36.4 мс (≈2 пакети)
  після старту, кожен графік — увесь запис на одному екрані (min/max на колонку), перемальовування
  лише по кнопці, вісь часу `0 … 36.4MS`.
* **v0.3.1** (2026-10-13) — фікс геометрії: повний екран 320×240 замість квадрата 240×240
  (`TFT_HEIGHT=320`, зсув у RAM ST7789 = `320 − TFT_HEIGHT`). Лише прошивка.
* **v0.4.0** (2026-10-13) — нова можливість: чіткий спектр. Спектрограма і waterfall малюються одразу
  на панель із нових даних: FFT 256 точок (≈17.6 кГц/бін), зум ±562 кГц, 270 колонок × 64 біни;
  waterfall 24 лінії з приховуванням задніх. Перевірено на платі (JTAG) і ПК-рендером.
* **v0.4.1** (2026-10-13) — відтворювана збірка без нових можливостей: BD експортовано в
  `scripts/create_bd.tcl`, прошивка збирається `scripts/build_elf.bat` з `vitis/bsp/` (без
  Vitis-платформи), `build.bat -board` = Vivado + прошивка + JTAG. `spi_tft_ctrl`: після скиду
  `rst_n`=1 і `blk`=1 (раніше 0), `tb_spi_tft_ctrl` оновлено (T1–T8 PASS). Виправлено `build.tcl`:
  BD знову синтезується в стандартному режимі (прибрано `synth_checkpoint_mode None` і ручне додавання
  `microblaze.v`) — через них XSA виходив без `.hwh`/`.mmi`. `run_board.tcl` більше не потребує XSA.
  Перевірено: чистий клон → `build.bat -all` + `build_elf.bat` → `run_board.tcl` → плата працює.
* **v0.4.2** (2026-10-15) — рефакторинг прошивки без зміни поведінки: `graph_viewer.c` (910 рядків)
  розбито на шари `app/ source/ dsp/ gfx/ hal/`, параметри винесено в `config.h`, генератор — у
  `source/src_synth.c` за інтерфейсом `iq_source.h`. Модулі `dsp/` названо за модулями RTL. Точка входу
  переписана на асемблері (`bsp/crt0.S`), прошивка збирається з `-flto`: код 21.4 → 19.2 КБ. ПК-емулятор
  перенесено в `tools/host_sim/`. Перевірено: усі 12 екранів піксель-у-піксель як до рефакторингу
  (`golden.md5`), прошивка працює на платі.

**Наступні кроки до `v1.0.0`**: тестовий екран `TFT TEST` з кольоровими областями, перевірка SPI-сигналів
(ILA або осцилограф) і запис результату сюди.

## Блоки: статус
| Блок | RTL | TB (self-check) | У BD / на залізі | Примітка |
|---|---|---|---|---|
| `spi_tft_ctrl` + `tft_top` | ✅ | ✅ `tb_spi_tft_ctrl` | ✅ / ✅ | SPI mode 0, CLKDIV, ручний/авто CS |
| `system_ctrl_regs` + `_top` | ✅ | ✅ `tb_system_ctrl` | ✅ / ✅ | антидребезг, події кнопок W1C |
| C-драйвер TFT (`hal/spi_tft.c`, `gfx/tft.c`, `gfx/font5x7.c`) | — | — | ✅ | шрифт 5×7 лише `0x20–0x5F` (без малих літер) |
| `iq_stream_regs` / `iq_stream_fifo` / `_top` | ✅ | ✅ `tb_iq_stream` | ❌ | FIFO I/Q з MicroBlaze у AXI-Stream |
| `rtl_demod` (NCO → CIC3 → дискримінатор → power → bit decoder) | ✅ | ✅ `tb_rtl_demod` на `sim.iq` | ❌ | очікування: `sim_data/sim.expect.txt` |
| `fsk_demod_top` + `tb_fsk_demod_plot` (CSV для графіків) | ✅ | ✅ | ❌ | прогін на 300 МБ капчурі: **Watchdog timeout** на 50 мс (2026-10-11) |
| `axi_lite_regs` (спільний міст AXI4-Lite) | ✅ | через `tb_iq_stream`/`tb_rtl_demod` | ❌ | |
| SD-карта (Vivado IP) + FatFs | ❌ | ❌ | ❌ | Блок 2 не почато |
| I/Q replay з SD, керування демодулятором | ❌ | ❌ | ❌ | Блок 3 |
| Graph viewer (прошивка, `vitis/src/app`) | — | `tools/host_sim` + `golden.md5` | ✅ | див. нижче |

2026-10-13 переганяли лише `tb_spi_tft_ctrl` (T1–T8 PASS). Для решти ✅ означає «є самоперевірний TB»,
а не «пройшов сьогодні».

## Graph viewer (`vitis/src/app/viewer.c`)
Уся обробка — на MicroBlaze, ланцюг `dsp/demod_chain.c` з тими самими етапами, що й RTL: `nco_mixer` →
`decimator` (/16) → `discriminator` → `burst_detect` → `bit_decoder`. Вхід — синтетичне джерело
`source/src_synth.c` (не `sim.iq`).

| # | Екран | Що показує | Джерело даних |
|---|---|---|---|
| 1 | INPUT I/Q | вхід I/Q, весь запис | запис 36.4 мс |
| 2–5 | P0/P1 SPECTR, P0/P1 WATERF | спектрограма і waterfall 1-го / 2-го пакета | **живі дані**: чекає пакет і малює ~1–2 с |
| 6 | NCO MIXER | I/Q після мікшера | запис |
| 7 | CIC3 DEC | I/Q після децимації | запис |
| 8 | CONSTELL | 64 точки децимованого I/Q | запис |
| 9 | FM DPHI | вихід дискримінатора | запис |
| 10 | PWR BURST | pavg, noise, поріг, burst | запис |
| 11 | BIT DEC | dphi, AFC, dev, SYNC/PRE/PKT | запис |
| 12 | DECODER | смуги SYNC/PRE/PKT/BURST + маркер RES | запис |

Бюджет пам'яті (32 КБ BRAM, стек від `0x7FF0` донизу):
| Що | Байт |
|---|---|
| код (`.text`, з `-flto`) | 19 216 |
| дані (`.bss`): 160 колонок запису × 38 Б, буфер FFT 1 КБ, кільце спектра 1 КБ, блок I/Q 1 КБ | 9 676 |
| вільно під стек | ≈3 860 (найглибший виклик ≈600; linker перевіряє ≥1 КБ) |

## Збірка і запуск
Потрібно: Vivado і Vitis 2025.2.1 (`vivado` і `xsct` у `PATH`, `XILINX_VITIS` = каталог Vitis для `mb-gcc`),
плата підключена по JTAG.
```
cd AXI_FIFO_Modulator\scripts
build.bat -board               # усе разом: Vivado (BD з create_bd.tcl → бітстрім → XSA) + прошивка + JTAG
```
Або по кроках:
```
build.bat -all                 # Vivado: проєкт → синтез → імплементація → бітстрім → XSA
build_elf.bat                  # прошивка → vitis\elf\df5_app.elf
xsct run_board.tcl             # залити бітстрім + ELF і запустити MicroBlaze
```
Перевірка екранів без плати (після будь-якої зміни в `vitis/src`):
```
tools\host_sim\run_host_sim.bat           # рендер 12 екранів → out\montage.png, порівняння з golden.md5
tools\host_sim\run_host_sim.bat -update   # прийняти нову картинку як еталон (після навмисної зміни)
```
Після правок BD у GUI (`build.bat -gui`) перегенеруй `scripts/create_bd.tcl`:
`write_bd_tcl -force -no_project_wrapper scripts/create_bd.tcl`, потім поверни у файл заголовок,
`set run_remote_bd_flow 0` і виклик `cr_bd_microblaze ""` в кінці.

## Vivado (`impl_1`, 100 МГц): таймінг закрито
| WNS | TNS | WHS | THS | LUT | FF | BRAM | DSP |
|---|---|---|---|---|---|---|---|
| +3.819 | 0 | +0.108 | 0 | 1461 (7 %) | 1468 (3.5 %) | 8 / 50 | 0 / 90 |

Це білд **без** демодулятора та `iq_stream`; ресурси RTL-демодулятора в залізі ще не міряли.

## Відомі проблеми / TODO
* **Переглядач показує не той сигнал, що HTML.** `sim.iq` має зсув каналу −1087 кГц, девіацію ±25 кГц,
  GFSK BT 0.5 і пакети по 108 750 відліків; `source/src_synth.c` — −250 кГц, ±50 кГц, 2-FSK. Зум спектра
  ±562 кГц сигнал з `sim.iq` не покаже. Наступний крок — replay `sim.iq` (SD або вбудований фрагмент).
* **SYNC/PRE/PKT у переглядачі — заглушка**: прапорці за віком burst (8/16/28 відліків), а не реальний
  пошук синхрослова, як у `demod_bit_decoder`.
* **BRAM тісний** (≈28.9 з 32 КБ після `-flto`). Для SD/FatFs (Блок 2) пам'яті, найімовірніше, не
  вистачить — знадобиться більша LMB або зовнішня пам'ять.
* Розмір панелі 240×320 виведено з налаштувань драйвера; на дисплеї візуально ще не підтверджено.
* Немає UART: `xil_printf` — заглушка (`vitis/bsp/stubs.c`), діагностика лише через TFT або JTAG.
* `patch_microblaze_bd_buttons.tcl` жорстко знімає скиди: `Reset` MicroBlaze і LMB — константа 0,
  `aresetn` AXI-периферії — константа 1 (обхід «завислого» `proc_sys_reset` при bring-up).
  Зовнішній скид на MicroBlaze не діє; перезапуск — повторним `run_board.tcl`.
* Бітстрім не містить прошивки: ELF вантажиться в BRAM по JTAG (`run_board.tcl`), після вимкнення
  живлення його треба залити знову. Для автономного старту — вбудувати ELF у бітстрім (`updatemem` з
  `.mmi` з XSA) і записати у flash.
* Заголовний коментар `system_ctrl_top.v` має зіпсоване кодування (`Ð¾Ð±…`).
* Прогін `tb_fsk_demod_plot` на 300 МБ капчурі зупинився по watchdog (50 мс симуляції).
