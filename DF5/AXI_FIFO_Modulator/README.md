# DF5 — TFT / SD / I/Q Replay

Проєкт на MicroBlaze: TFT через SPI, SD-карта з FatFs, відтворення та
демодуляція I/Q-записів.

Поточний стан, історія версій і відомі проблеми — у [`STATUS.md`](STATUS.md).
Як усе влаштовано і що відбувається — у [`docs/architecture.md`](docs/architecture.md).

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

## Block 3 signal viewer (MicroBlaze)

The firmware records one capture with two packets and shows it on the ST7789 as four screens,
all calculations on MicroBlaze:

1. `RAW I/Q` -- input I and Q over time, packets marked P1/P2
2. `BITS` -- bits decoded from both packets: waveform + hex
3. `FFT` -- level in dBFS vs frequency (max hold), peak marker
4. `WATERFALL` -- frequency vs time

Keys:
- K1 short -- next screen; K2 short -- zoom x1 -> x2 -> x4 -> x8 -> x16 on the current screen
- K1 held -- scroll the zoomed plot back; K2 held -- scroll forward

Firmware layout (`vitis/src`, dependencies only point down the list):

| Folder | What lives there |
|---|---|
| `main.c`, `config.h` | init + main loop; all system parameters (Fs, frequencies, capture length) |
| `app/` | `viewer` (screens), `keys` (short press / hold), `zoom`, `capture.h` (the recording, filled by the PL), `view_time` (raw, bits), `view_freq` (FFT, waterfall), SD test / format |
| `gfx/` | ST7789 driver `tft`, font, `plot` primitives |
| `hal/` | drivers of the PL blocks: `spi_tft`, `system_ctrl`, `dsp_rtl` (the whole DSP, see `docs/dsp_rtl.md`), `axi_qspi` + `sd_card` |
| `lib/fatfs/` | FatFs R0.15a + diskio for the microSD card |
| `../bsp/` | `crt0.S`, linker script, `xparameters.h` with BD addresses |

The DSP itself runs in the PL (`vivado/sources/rtl/dsp_*.sv`). Its C model -- the
same chain in software, for the host simulator only -- is in `tools/host_sim/model/`.

All screens can be rendered on a PC, without the board:
`tools/host_sim/run_host_sim.bat` (compares with `tools/host_sim/golden.md5`).

Constraints update in `vivado/constraints/tft.xdc`:
- `btn1_n` -> `W21`
- `btn2_n` -> `Y21`

From repo root you can also run one command:

```bat
run_board.bat
```
