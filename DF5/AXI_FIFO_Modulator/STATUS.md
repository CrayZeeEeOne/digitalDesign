# DF5 — MicroBlaze: TFT (ST7789) + SD/FatFs + I/Q replay і FSK-демодулятор

> **Стан на 2026-10-13.** На залізі працює: MicroBlaze + SPI-контролер TFT + кнопки, а на дисплеї —
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
  vitis/src/           C: драйвер TFT, system_ctrl, graph_viewer, main
  vitis/bsp/           мінімальний bare-metal BSP: crt0, linker-скрипт, xparameters.h з адресами BD
  vitis/elf/           ЗГЕНЕРОВАНЕ: df5_app.elf — те, що заливається на плату
  tools/               Python: iqgen (генератор I/Q), demod_model (золота модель), plot_rtl_demod (HTML-графіки)
  docs/                block1_tft.md — мапа регістрів SPI TFT і піни
```

## Що зараз у залізі (Block Design `microblaze`)
| Блок | Адреса | Що робить |
|---|---|---|
| `microblaze_0` + LMB BRAM | `0x0000_0000`–`0x0000_7FFF` | 32 КБ на код, дані та стек |
| `tft_top` (`spi_tft_ctrl`) | `0x0001_0000` | AXI4-Lite → SPI master до ST7789, TX FIFO 16 байт, ID `0x5F778901` |
| `system_ctrl_top` | `0x44A1_0000` | кнопки KEY1/KEY2 з антидребезгом і подіями (W1C), LED, TICK, дільник SD-SPI |
| `clk_wiz`, `proc_sys_reset`, `mdm`, AXI interconnect | — | такт 100 МГц, скиди, JTAG-дебаг |

Мапа регістрів TFT — [`docs/block1_tft.md`](docs/block1_tft.md); system_ctrl — `vitis/src/system_ctrl.h`.

## Історія версій

Нумерація: `<напрям> v<major>.<minor>.<patch>`. major = перевірено на залізі, minor = новий набір функцій,
patch = фікси. Напрями: **HW** (бітстрім/BD), **SIM** (RTL у симуляції), **VIEW** (прошивка переглядача).

* **HW v0.1.0** (2026-09-21 … 2026-10-12, коміти `296f843` … `07eaf2f`) — каркас DF5: скриптовий
  Vivado-потік (`build.bat -syn/-impl/-xsa/-all/-board`), `spi_tft_ctrl` + `tft_top`, `system_ctrl` з
  кнопками (`btn1_n` → W21, `btn2_n` → Y21), BD з MicroBlaze. Бітстрім зібрано, таймінг закрито
  (див. «Vivado»). Коміт `07eaf2f` лишив у репо тільки відтворювані bring-up джерела й скрипти.
* **SIM v0.1.0** (2026-10-11) — RTL 2-FSK/GFSK демодулятор у симуляції: `demod_nco_mixer` → `demod_cic3`
  → `demod_discriminator` (CORDIC atan2) → `demod_power` (детектор пакета) → `demod_bit_decoder`;
  обгортки `rtl_demod_regs`/`rtl_demod_top` (AXI4-Lite + AXI-Stream), `iq_stream_*` (FIFO MicroBlaze → AXIS).
  Тестовий сигнал `sim.iq` (Python `iqgen.py`), золота модель `demod_model.py`, графіки
  `rtl_demod_plots.html` (12 графіків, `plot_rtl_demod.py`).
* **VIEW v0.1.0** (2026-10-13) — `graph_viewer` на MicroBlaze: 12 екранів, як у HTML, перемикання K1/K2.
  Знайдено та виправлено в моделі детектора: `age` завжди був 0 (SYNC/PRE/PKT ніколи не вмикались),
  оцінка шуму підтягувалась до сигналу (burst гас через ~0.5 мс), провали посеред пакета → додано
  заморожування шуму під час burst і hangover 16 відліків. Нове тестове джерело в `main.c`: 2-FSK
  на −250 кГц, ±50 кГц, пакети 192 символи / паузи 128.
* **VIEW v0.2.0** (2026-10-13) — графіки не прокручуються: один запис 36.4 мс (≈2 пакети) після
  старту, кожен графік — увесь запис на одному екрані (min/max на колонку), перемальовування лише по
  кнопці. Підпис осі часу `0 … 36.4MS`.
* **VIEW v0.3.0** (2026-10-13) — повний екран 320×240 замість квадрата 240×240
  (`TFT_HEIGHT=320`, зсув у RAM ST7789 = `320 − TFT_HEIGHT`).
* **VIEW v0.4.0** (2026-10-13) — чіткий спектр: спектрограма і waterfall малюються одразу на панель
  з нових даних (не зберігаються в BRAM). FFT 256 точок (≈17.6 кГц/бін), зум ±562 кГц, 270 колонок
  × 64 біни; waterfall 24 лінії з приховуванням задніх. Залито на плату через JTAG (MicroBlaze у
  Running).
* **HW v0.2.0** (2026-10-13) — проєкт відтворюється з чистого клону: Block Design експортовано в
  `scripts/create_bd.tcl`, прошивка збирається `scripts/build_elf.bat` з `vitis/bsp/` (без Vitis-платформи),
  `build.bat -board` = Vivado + прошивка + JTAG. `spi_tft_ctrl`: після скиду `rst_n`=1 і `blk`=1
  (раніше 0), `tb_spi_tft_ctrl` оновлено й пройдено. `btn1_n` → W21. Закомічено разом із VIEW v0.1–v0.4.

## Блоки: статус
| Блок | RTL | TB (self-check) | У BD / на залізі | Примітка |
|---|---|---|---|---|
| `spi_tft_ctrl` + `tft_top` | ✅ | ✅ `tb_spi_tft_ctrl` | ✅ / ✅ | SPI mode 0, CLKDIV, ручний/авто CS |
| `system_ctrl_regs` + `_top` | ✅ | ✅ `tb_system_ctrl` | ✅ / ✅ | антидребезг, події кнопок W1C |
| C-драйвер TFT (`spi_tft.c`, `tft.c`, `font5x7.c`) | — | — | ✅ | шрифт 5×7 лише `0x20–0x5F` (без малих літер) |
| `iq_stream_regs` / `iq_stream_fifo` / `_top` | ✅ | ✅ `tb_iq_stream` | ❌ | FIFO I/Q з MicroBlaze у AXI-Stream |
| `rtl_demod` (NCO → CIC3 → дискримінатор → power → bit decoder) | ✅ | ✅ `tb_rtl_demod` на `sim.iq` | ❌ | очікування: `sim_data/sim.expect.txt` |
| `fsk_demod_top` + `tb_fsk_demod_plot` (CSV для графіків) | ✅ | ✅ | ❌ | прогін на 300 МБ капчурі: **Watchdog timeout** на 50 мс (2026-10-11) |
| `axi_lite_regs` (спільний міст AXI4-Lite) | ✅ | через `tb_iq_stream`/`tb_rtl_demod` | ❌ | |
| SD-карта (Vivado IP) + FatFs | ❌ | ❌ | ❌ | Блок 2 не почато |
| I/Q replay з SD, керування демодулятором | ❌ | ❌ | ❌ | Блок 3 |
| `graph_viewer` (прошивка) | — | ПК-рендер (ST7789-емулятор) | ✅ | див. нижче |

2026-10-13 переганяли лише `tb_spi_tft_ctrl` (T1–T8 PASS). Для решти ✅ означає «є самоперевірний TB»,
а не «пройшов сьогодні».

## Graph viewer (`vitis/src/graph_viewer.c`)
Уся обробка — на MicroBlaze, той самий тракт, що й RTL: NCO-мікшер → усереднення /16 → FM-дискримінатор →
потужність/шум/поріг → прапорці SYNC/PRE/PKT. Вхід — синтетичне джерело в `main.c` (не `sim.iq`).

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
| код (`.text`) | 21 354 |
| дані (`.bss`): 160 колонок запису × 38 Б, буфер FFT 1 КБ, кільце спектра 1 КБ, блок I/Q 1 КБ | 9 656 |
| вільно під стек | ≈1 740 (найглибший виклик ≈600; linker перевіряє ≥1 КБ) |

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
Після правок BD у GUI (`build.bat -gui`) перегенеруй `scripts/create_bd.tcl`:
`write_bd_tcl -force -no_project_wrapper scripts/create_bd.tcl`, потім поверни у файл заголовок,
`set run_remote_bd_flow 0` і виклик `cr_bd_microblaze ""` в кінці.

## Vivado (`impl_1`, 100 МГц): таймінг закрито
| WNS | TNS | WHS | THS | LUT | FF | BRAM | DSP |
|---|---|---|---|---|---|---|---|
| +3.684 | 0 | +0.094 | 0 | 1462 (7 %) | 1467 (3.5 %) | 8 / 50 | 0 / 90 |

Це білд **без** демодулятора та `iq_stream`; ресурси RTL-демодулятора в залізі ще не міряли.

## Відомі проблеми / TODO
* **Переглядач показує не той сигнал, що HTML.** `sim.iq` має зсув каналу −1087 кГц, девіацію ±25 кГц,
  GFSK BT 0.5 і пакети по 108 750 відліків; джерело в `main.c` — −250 кГц, ±50 кГц, 2-FSK. Зум спектра
  ±562 кГц сигнал з `sim.iq` не покаже. Наступний крок — replay `sim.iq` (SD або вбудований фрагмент).
* **SYNC/PRE/PKT у переглядачі — заглушка**: прапорці за віком burst (8/16/28 відліків), а не реальний
  пошук синхрослова, як у `demod_bit_decoder`.
* **BRAM майже повний** (≈31.2 з 32 КБ). Будь-яка нова функція в прошивці потребує або більшої LMB,
  або зовнішньої пам'яті.
* Розмір панелі 240×320 виведено з налаштувань драйвера; на дисплеї візуально ще не підтверджено.
* Немає UART: `xil_printf` — заглушка (`vitis/bsp/stubs.c`), діагностика лише через TFT або JTAG.
* `patch_microblaze_bd_buttons.tcl` жорстко знімає скиди: `Reset` MicroBlaze і LMB — константа 0,
  `aresetn` AXI-периферії — константа 1 (обхід «завислого» `proc_sys_reset` при bring-up).
  Зовнішній скид на MicroBlaze не діє; перезапуск — повторним `run_board.tcl`.
* Заголовний коментар `system_ctrl_top.v` має зіпсоване кодування (`Ð¾Ð±…`).
* Прогін `tb_fsk_demod_plot` на 300 МБ капчурі зупинився по watchdog (50 мс симуляції).
