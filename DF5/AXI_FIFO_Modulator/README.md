# DF5 — TFT / SD / I/Q Replay

Проєкт на MicroBlaze + RTL: справжній I/Q-запис (Pluto SDR, пакети GFSK, що
стрибають по 15 каналах) іде з microSD нативною 4-бітною шиною прямо в DSP у
FPGA у реальному часі; DSP знаходить канал кожного пакета, демодулює, знебілює
PN9 і перевіряє CRC; MicroBlaze малює 6 екранів на TFT ST7789.

Поточний стан, історія версій і відомі проблеми — у [`STATUS.md`](STATUS.md).
Повний опис роботи RTL і прошивки, аж до окремих блоків коду, — у
[`docs/how_it_works.md`](docs/how_it_works.md): з ним не треба відкривати джерела.
DSP і SD-контролер у PL, мапи регістрів — у [`docs/dsp_rtl.md`](docs/dsp_rtl.md).
Старіший огляд (до переходу DSP у залізо) — у [`docs/architecture.md`](docs/architecture.md).

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

build.bat              створити або оновити проєкт і Block Design (без синтезу)
build.bat -bd          перебудувати BD з create_bd.tcl, далі все підряд (після змін BD/модулів у ньому)
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
| 1 — TFT: SPI RTL і C-драйвер | працює на платі; `TFT TEST` і перевірка SPI осцилографом -- ще ні | [`docs/block1_tft.md`](docs/block1_tft.md) |
| 2 — SD-карта і FatFs | працює на платі (нативна шина, `sd_host`); `test.img` -- ще ні | [`docs/dsp_rtl.md`](docs/dsp_rtl.md) |
| 3 — I/Q replay, демодулятор, екрани | працює на платі в реальному часі, 59/59 пакетів запису | [`docs/how_it_works.md`](docs/how_it_works.md) |

Версії та що в кожній -- [`STATUS.md`](STATUS.md).

## Block 3 signal viewer

The PL does all the signal processing; the firmware plays the file from the card into it and
draws. The card holds `CAPTURE.IQ8` (int8 I/Q, 4.5 MS/s; make it with
`tools/iq16to8.py` from the int16 capture). It plays once in real time, then the screens stay
(END); K1+K2 plays it again.

1. `RAW I/Q` -- input I and Q, 21.8 ms around the last packet
2. `BITS` -- slicer bits of the packet; channel, CRC16, CRC8, packet number, alarm counter; receive statistics
3. `FFT` -- level in dBFS over the whole band 865.15..869.65 MHz, peak marker
4. `WATERFALL` -- the whole file, 0..16.7 s top to bottom
5. `SD CARD` -- the card test, root directory, the file
6. `FFT+WF` -- FFT above, waterfall below

Keys:
- K1 short -- next screen; K2 short -- pause while playing, zoom x1 -> x16 otherwise
- K1 / K2 held -- scroll the zoomed plot back / forward
- K1 + K2 -- go on after a pause, play the file again after it ended

Firmware layout (`vitis/src`, dependencies only point down the list):

| Folder | What lives there |
|---|---|
| `main.c`, `config.h` | states and main loop; all system parameters (Fs, channels, file, thresholds) |
| `app/` | `viewer` (screens), `view_time` (raw, bits), `view_freq` (FFT, waterfall), `view_sd`, `keys`, `zoom`, `frame` (the Alarm-Beacon frame), `sd_iq` (file -> PL stream), SD test / format |
| `gfx/` | ST7789 driver `tft`, font, `plot` primitives |
| `hal/` | drivers of the PL blocks: `spi_tft`, `system_ctrl`, `dsp_rtl` (the whole DSP), `sd_host` (microSD in the PL), `sd_card` (SD protocol) |
| `lib/fatfs/` | FatFs R0.15a + diskio for the microSD card |
| `../bsp/` | `crt0.S`, linker script, `xparameters.h` with BD addresses |

The DSP itself runs in the PL (`vivado/sources/rtl/dsp_*.sv`, `demod_*.sv`), the SD host in
`sd_host.sv`. A C model of the DSP -- for the host simulator only -- is in `tools/host_sim/model/`.

All screens can be rendered on a PC, without the board:
`tools/host_sim/run_host_sim.bat` (compares with `tools/host_sim/golden.md5`).

Constraints update in `vivado/constraints/tft.xdc`:
- `btn1_n` -> `W21`
- `btn2_n` -> `Y21`

From repo root you can also run one command:

```bat
run_board.bat
```
