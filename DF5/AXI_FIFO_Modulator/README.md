# DF5 — TFT / SD / I/Q Replay

Проєкт на MicroBlaze: TFT через SPI, SD-карта з FatFs, відтворення та
демодуляція I/Q-записів.

Поточний стан, історія версій і відомі проблеми — у [`STATUS.md`](STATUS.md).

## Структура

```
AXI_FIFO_Modulator/
├── scripts/              точка входу в потік, нічого не редагується вручну
│   ├── build.bat         єдина команда для всього
│   ├── build.tcl         створення проєкту, сканування джерел
│   ├── run.tcl           синтез / implementation / bitstream / XSA
│   ├── run_stage.tcl     передача етапу з батника в run.tcl
│   └── sim.tcl           запуск тестбенча в xsim
├── vivado/
│   ├── sources/
│   │   ├── rtl/          синтезований RTL (.sv, .v)
│   │   ├── tb/           тестбенчі (у проєкт ідуть як sim_1)
│   │   └── bd/           ЗГЕНЕРОВАНЕ: робоча копія BD (джерело -- scripts/create_bd.tcl)
│   ├── constraints/      .xdc
│   └── project/          ЗГЕНЕРОВАНЕ, у git не потрапляє
├── vitis/
│   ├── src/              C-код застосунку
│   ├── platform/         ЗГЕНЕРОВАНЕ, сюди падає .xsa
│   └── workspace/        ЗГЕНЕРОВАНЕ
├── docs/
└── .gitignore
```

Принцип: усе, що лежить у `vivado/sources/` і `vivado/constraints/`,
підхоплюється автоматично. Додав файл — просто перезапусти `build.bat`,
правити Tcl не треба.

## Команди

```bat
cd scripts

build.bat              створити або оновити проєкт
build.bat -syn         + синтез
build.bat -impl        + implementation і bitstream
build.bat -xsa         + експорт XSA у vitis\platform\
build.bat -all         усе підряд
build.bat -sim         симуляція тестбенча
build.bat -gui         відкрити GUI (для редагування Block Design)
build.bat -board       усе: Vivado + прошивка (build_elf.bat) + запуск на платі по JTAG
build.bat -clean       видалити згенерований проєкт
```

Block Design редагується в GUI (`build.bat -gui`).
Після змін перегенеруй `scripts/create_bd.tcl` (див. STATUS.md, «Збірка і запуск») --
саме з нього BD будується на чистому клоні.

## Параметри проєкту

Задаються вгорі `scripts/build.tcl`:

| Змінна | Значення |
|---|---|
| `part_name` | `xc7a35tfgg484-2` |
| `top_module` | `microblaze_wrapper` |
| `bd_name` | `microblaze` |

## Блоки

| Блок | Стан | Документ |
|---|---|---|
| 1 — TFT: SPI RTL і C-драйвер | в роботі | [`docs/block1_tft.md`](docs/block1_tft.md) |
| 2 — SD-карта: Vivado IP і FatFs | — | |
| 3 — I/Q replay, Viewer, Demodulator | — | |

## Block 3 LCD graph viewer (MicroBlaze)

A firmware viewer is added in `vitis/src` to render demodulator-style plots directly on ST7789 LCD with all calculations on MicroBlaze:
- input I/Q
- mixer I/Q
- CIC decimated I/Q
- discriminator + power/burst
- spectrogram
- waterfall
- constellation
- decoder state timeline

Button navigation is handled by `system_ctrl_regs` events:
- KEY1 (`btn1_n`) cycles view forward
- KEY2 (`btn2_n`) cycles view backward

Main files:
- `vitis/src/main.c`
- `vitis/src/graph_viewer.c`
- `vitis/src/graph_viewer.h`
- `vitis/src/system_ctrl.c`
- `vitis/src/system_ctrl.h`

Constraints update in `vivado/constraints/tft.xdc`:
- `btn1_n` -> `W21`
- `btn2_n` -> `Y21`

From repo root you can also run one command:

```bat
run_board.bat
```
