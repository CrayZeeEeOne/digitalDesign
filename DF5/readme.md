# DF5 / TFT Bring-up + SD/FatFs + I/Q Replay

## Мета

Роботу поділити на три незалежні блоки:

1. **TFT: SPI RTL і C-драйвер** — базово запустити дисплей і показати тестову інформацію.
2. **SD-карта: Vivado IP і FatFs** — читати файли через готовий SD-блок, під'єднавши файлову систему FatFs.
3. **I/Q replay, viewer і demodulator** — об'єднати TFT та читання файлів у кінцевий застосунок.

### Додатокові інпути

- TFT-дисплей, SD-карта, підключення та базова апаратна платформа фізично доступні.
- Для SD-карти **не розробляти власний RTL-контролер**: використовуємо сумісний готовий IP/драйвер із Vivado або платформного BSP.
- Для TFT потрібно реалізувати SPI-передачу в RTL і C-драйвер, якщо відповідний функціонал ще відсутній.

---

# Блок 1 — TFT: SPI RTL, C-драйвер і тест виводу

## Мета

Налаштувати шлях від MicroBlaze до TFT і підтвердити його окремим тестом. На цьому етапі **не потрібно** виводити I/Q-графіки або результати демодуляції.

> Архітектура цього блоку — **software-driven**: MicroBlaze сам формує пікселі/текст через C API, SPI RTL виконує роль простого байтового транспорту до ST7789 (команди/дані через `DC`).

## Завдання

### RTL

- Реалізувати SPI master для обміну даними з TFT.
- Передбачити керування потрібними сигналами дисплея: `SCLK`, `MOSI`, `CS`, `DC` та `RESET` — відповідно до контролера конкретного TFT.
- Під'єднати SPI-блок до MicroBlaze через доступний AXI-периферійний інтерфейс або наявний у проєкті спосіб доступу.
- Документувати регістри керування і передачі даних.

### C-драйвер

Реалізувати C API для MicroBlaze, щонайменше:

- ініціалізація SPI та TFT;
- передавання команд і даних;
- очищення дисплея;
- вивід тестового тексту або простих графічних примітивів.

Приклади можливих функцій:

```c
tft_init();
tft_clear(color);
tft_draw_pixel(x, y, color);
tft_draw_text(x, y, text, color);
```

Назви та API можна адаптувати до наявної архітектури.

## Перевірка та критерії готовності

- Після запуску MicroBlaze TFT проходить ініціалізацію без зависань.
- Тестова програма показує текст, наприклад `TFT TEST`, і тестові кольорові області.
- Перевірено правильність SPI-сигналів і параметрів дисплея.
- Створено короткий приклад використання C-драйвера.

---

# Блок 2 — SD-карта: готовий Vivado IP і FatFs

## Мета

Забезпечити MicroBlaze доступ до файлів на SD-карті. SD-контролер з нуля не розробляти.

## Завдання

1. Визначити, який готовий SD/SDIO IP або платформний драйвер підтримується поточним Vivado-проєктом і платою.
2. Під'єднати його до MicroBlaze відповідно до платформи та налаштувати BSP.
3. Знайти сумісну open-source реалізацію FatFs і додати її до C-проєкту.
4. Реалізувати код між FatFs (`diskio`) і драйвером SD-карти.
5. Перевірити монтування файлової системи, відкриття файлу, читання даних та обробку помилок.

## Тест

Підготувати тестову програму, яка:

- монтує SD-карту;
- відкриває тестовий файл;
- читає його блоками;
- виводить кількість прочитаних байтів і статус у консоль;
- коректно повідомляє про відсутню карту, помилку монтування, відкриття або читання.

### Тест із картинкою (сумісно з waterfall-рендером із Блоку 3)

Замість абстрактного файлу — тестове зображення, яке зразу і наочно підтверджує FatFs + TFT-драйвер разом:

- формат — сирий RGB565 (ширина × висота × 2 байти, без заголовка/стиснення), покласти на SD як `test.img`;
- читати файл блоками (не цілком в один буфер) і передавати прочитані пікселі в TFT-драйвер (Блок 1) рядок за рядком;

## Критерії готовності

- MicroBlaze читає файл із SD-карти через FatFs.
- Підтверджено читання кількох послідовних блоків до EOF.
- Перевірено помилки та обмеження драйвера, зокрема розмір буфера і швидкість читання.
- Тестове зображення коректно і без спотворень відображається на TFT (кольори, орієнтація, немає зсуву).


---

# Блок 3 — I/Q replay, Signal Viewer і Demodulator

Можна юзать алгоритм який лежить тут (сішна реалізація) *https://github.com/igoryashkka/AsicDesign/tree/main/DigitalDesign/FPGA0/fsk_demod* 
Тут лежить файл з записом IQ який треба читать *https://github.com/igoryashkka/AsicDesign/blob/main/DigitalDesign/FPGA0/fsk_demod/resources/resources.7z*
 
## Мета

Використати TFT-драйвер із блоку 1 та читання файлів із блоку 2, щоб відтворювати I/Q-файл, показувати його характеристики та передавати дані в RTL-демодулятор.

Один і той самий I/Q-файл повинен підтримувати два основних режими:

1. **Signal Viewer** — читати I/Q із файлу, аналізувати сигнал, показувати його на TFT у різних представленнях, перемикати представлення кнопкою.
2. **Demodulator** — читати той самий I/Q-файл, передавати I/Q у RTL-демодулятор, отримувати результат демодуляції, показувати decoded data та результати аналізу на TFT, виводити текстові логи/status.

Файл працює як **recorded signal source / signal replay source**.

## 3.1 Загальна архітектура

```text
                    I/Q FILE (SD, FatFs — блок 2)
                       |
                       v
              +------------------+
              |  MicroBlaze C    |
              |   File Reader    |
              +--------+---------+
                       |
                 I/Q sample stream
                       |
          +------------+-------------+
          |                          |
          v                          v
   SIGNAL VIEWER                RTL DEMODULATOR
          |                          |
          |                          v
          |                   decoded bits/bytes
          |                          |
          +------------+-------------+
                       |
                       v
                ANALYSIS ENGINE
                       |
                       v
          TFT DISPLAY (драйвер — блок 1)
                       |
              +--------+--------+
              |                 |
          graph mode        text/log mode
```

MicroBlaze відповідає за:

- відкриття I/Q-файлу (FatFs);
- читання I/Q блоками;
- replay сигналу;
- перемикання режимів;
- керування демодулятором;
- отримання результатів;
- підготовку даних для TFT;
- текстові логи та status.

RTL відповідає за:

- високошвидкісний DSP;
- демодуляцію;
- потокову обробку I/Q;
- формування вимірюваних параметрів.

---

## 3.2 Формат I/Q-файлу

Вхідний файл — бінарний, з чергуванням `I` та `Q`:

```text
I0, Q0, I1, Q1, ...
```

Формат:

```text
I = int16_t
Q = int16_t
little-endian
```

Один complex sample:

```text
4 bytes = I[15:0] + Q[15:0]
```

Формат текстового файлу, якщо він потрібен для тестування, має бути описаний окремо.

MicroBlaze повинен читати файл блоками, наприклад:

```text
16384 complex samples
```

і ніколи не передавати в DSP неповну I/Q пару.

---

## 3.3 File Replay

```text
FILE OPEN
   |
   v
READ BLOCK
   |
   v
PROCESS BLOCK
   |
   +----> Viewer
   |
   +----> Demodulator
   |
   v
READ NEXT BLOCK
```

Необхідно підтримати:

```text
START
STOP
PAUSE
RESTART
EOF
```

Також бажано мати можливість `seek / restart from beginning` для повторного програвання того самого сигналу.

---

## 3.4 Signal Viewer

Повинна існувати можливість **взяти I/Q-файл і одразу подивитися сигнал на TFT без запуску демодулятора**.

Viewer обробляє поточний блок I/Q поблоково та формує графік:

```text
I/Q file
   |
   v
16384 samples
   |
   v
calculate visualization data
   |
   v
TFT
```

### Режими відображення

**MODE 0 — I waveform**

```text
X = sample/time
Y = I amplitude
```

**MODE 1 — Q waveform**

```text
X = sample/time
Y = Q amplitude
```

**MODE 2 — I + Q** — одночасно `I(t)` і `Q(t)` для порівняння.

**MODE 3 — Magnitude / Power**

```text
|x|² = I² + Q²
```

або нормалізована magnitude `sqrt(I² + Q²)`. Якщо sqrt занадто дороге для MicroBlaze, дозволяється використовувати лише `I² + Q²`.

**MODE 4 — Frequency spectrum** — FFT поточного блоку, magnitude FFT на TFT. Горизонтальна вісь — frequency, вертикальна — magnitude/power. Повинен бути явно заданий `Fs` для правильної побудови frequency axis.

**MODE 5 — Waterfall**

```text
I/Q block -> FFT -> magnitude -> one horizontal line -> waterfall buffer
```

Новий спектр додається зверху/знизу, старі лінії зсуваються — видно зміну спектра в часі.

### Перемикання режимів

Кнопка `BUTTON_NEXT` циклічно перемикає:

```text
I -> Q -> I+Q -> POWER -> SPECTRUM -> WATERFALL -> I
```

Бажано також `BUTTON_PREV`, `BUTTON_SELECT`, якщо апаратно доступні додаткові кнопки.

При перемиканні режиму TFT одразу очищається та перемальовується, наприклад:

```text
--------------------------------
VIEW: WATERFALL
Fs: 4.5 MHz
LO: 867.4 MHz
FILE: capture.iq
--------------------------------
       [waterfall]
--------------------------------
```

---

## 3.5 TFT-вивід: дві області екрана

```text
+--------------------------------+
| STATUS / LOG                   |
| Fs: 4.5 MHz                    |
| File: capture.iq               |
| Mode: DEMOD                    |
| Burst: ACTIVE                  |
| Freq: 866.31 MHz               |
| SNR: 18.2 dB                   |
+--------------------------------+
|                                |
|        GRAPH / WATERFALL       |
|                                |
+--------------------------------+
```

Верхня частина — текстовий status/log. Нижня — графік / waterfall / waveform / результати демодуляції.

Для першої інтеграції достатньо показати ім'я файлу, частоту дискретизації, режим і поточний стан replay.

### Text / Log output (обов'язково)

Перегляд:

```text
[VIEW]
File opened: capture.iq
Fs: 4.5 MHz
Samples: 75000000
Mode: WATERFALL
FFT: 1024
```

Демодуляція:

```text
[DEMOD]
File opened: capture.iq
Demodulator started

[BURST]
Burst detected
Frequency: 866.31 MHz
Power: ...
SNR: ...

[SYNC]
Preamble detected
Sync: 0x91D3
Sync OK

[PACKET]
Bits: 384
Bitrate: 19200
CRC: OK
```

Якщо нічого не знайдено:

```text
[DEMOD]
No burst detected
```

Помилки:

```text
[ERROR]
IQ FIFO overflow
```

```text
[ERROR]
Invalid IQ file length
```

---

## 3.6 Demodulator Mode

```text
I/Q file
   |
   v
MicroBlaze
   |
   v
IQ FIFO
   |
   v
RTL DEMOD
   |
   +--> frequency
   +--> power/SNR
   +--> bitrate
   +--> burst
   +--> sync
   +--> decoded bits
   +--> packet status
   |
   v
MicroBlaze
   |
   v
TFT
```

### Важлива вимога

Якщо пакетів не знайдено, TFT повинен показувати явний статус, наприклад:

```text
Burst: NO
Sync: NOT FOUND
Packets: 0
```

а **не порожній графік**. Приклад позитивного результату:

```text
Burst:       YES
Frequency:   866.31 MHz
SNR:         19.4 dB
Bitrate:     19200
Preamble:    FOUND
Sync:        0x91D3
CRC:         OK
Bits:        384
```

Decoded bytes відображаються як hex (`91 D3 42 A7 01 05 ...`) або ASCII, якщо дані printable.

---

## 3.7 Режими системи

```text
MODE_VIEW        — File -> Viewer -> TFT
MODE_DEMOD       — File -> RTL Demod -> TFT
MODE_VIEW_DEMOD  — File -> Viewer
                        -> RTL Demod (один блок I/Q доступний обом гілкам без пошкодження даних)
```

Кнопка перемикає: `I -> Q -> I+Q -> POWER -> SPECTRUM -> WATERFALL -> DEMOD STATUS`.

---

## 3.8 RTL modules

Мінімальний набір:

```text
spi_tft_ctrl.sv        (драйвер з блоку 1)
iq_stream_fifo.sv
rtl_demod.sv
system_ctrl_regs.sv
iq_stream_regs.sv
rtl_demod_regs.sv
spi_tft_regs.sv
```

Для FFT — готовий Vivado FFT IP, або власний RTL FFT, якщо окремо потрібно. AXI Interconnect / AXI SmartConnect — готові, власний не писати.

---

## 3.9 Vitis C modules

```text
main.c
config.c / config.h
iq_file.c / iq_file.h       (поверх FatFs з блоку 2)
signal_viewer.c / signal_viewer.h
spectrum.c / spectrum.h
waterfall.c / waterfall.h
demod.c / demod.h
tft_ui.c / tft_ui.h          (поверх C-драйвера з блоку 1)
tft_graphics.c / tft_graphics.h
logger.c / logger.h
button.c / button.h
```

### IQ file API

```c
source_open_file(...)
source_next(...)
source_restart(...)
source_close(...)
```

`source_next()` повертає блок:

```c
typedef struct {
    int16_t i;
    int16_t q;
} iq_sample_t;

iq_sample_t buffer[16384];
```

### Visualization API

```c
viewer_set_mode(...)
viewer_process_iq(...)
viewer_draw(...)
```

```c
viewer_set_mode(VIEW_WATERFALL);

while (...) {
    n = source_next(buffer, 16384);

    viewer_process_iq(buffer, n);

    if (mode == MODE_VIEW_DEMOD)
        demod_process(buffer, n);

    viewer_draw();
}
```

### Кнопки (`button.c/.h`)

Мінімальні події: `BTN_NEXT_VIEW`, `BTN_PREV_VIEW`, `BTN_START`, `BTN_STOP`, `BTN_PAUSE`, `BTN_RESTART`. При `BTN_NEXT_VIEW` — `current_view_mode++` і перемальовка TFT.

### Configuration (`config.c/.h`)

Єдине місце для дефолтних параметрів:

```c
fs = 4.5e6;
lo = 867.4e6;
bitrate = 19200;

channel_tol_hz = 30000;

fft_size = 1024;

viewer_mode = VIEW_WATERFALL;
system_mode = MODE_VIEW_DEMOD;

input_file = "...";   /* файл для replay */
```

---

## 3.10 Демодулятор — базовий DSP pipeline

```text
I/Q
 |
 v
Burst detector
 |
 v
Carrier estimation
 |
 v
Frequency shift
 |
 v
LPF
 |
 v
Decimation
 |
 v
FM discriminator
 |
 v
FSK level detection
 |
 v
Clock recovery
 |
 v
Hard decision
 |
 v
Preamble / Sync detector
 |
 v
Packet
 |
 v
CRC
```

Основні результати: `frequency, power, SNR, bitrate, deviation, burst length, bits count, sync status, CRC status, decoded bytes`.

---

## 3.11 Демонстраційний сценарій (acceptance)

1. На SD-карті (блок 2) лежить `capture.iq`.
2. MicroBlaze відкриває файл через FatFs. На TFT (блок 1): `FILE: capture.iq`, `Fs: 4.5 MHz`, `Samples: ...`.
3. Кнопка → `VIEW: I`, видно waveform I.
4. Кнопка → `VIEW: Q`.
5. Кнопка → `VIEW: I + Q`.
6. Кнопка → `VIEW: SPECTRUM`, видно спектр.
7. Кнопка → `VIEW: WATERFALL`, видно waterfall із записаного сигналу.
8. Перемикання system mode `FILE -> DEMOD`: той самий файл передається в RTL demodulator.
9. На TFT з'являється:
   ```text
   DEMOD ACTIVE

   Burst: YES
   Freq: 866.31 MHz
   SNR: XX dB
   Bitrate: 19200
   Sync: FOUND
   CRC: OK
   Bits: XXX
   ```
10. Якщо демодулятор нічого не знайшов:
    ```text
    DEMOD ACTIVE

    Burst: NO
    Sync: NOT FOUND
    Packets: 0
    ```
    а не просто порожній екран.

## Критерії готовності Блоку 3

- Файл читається із SD через FatFs і обробляється блоками.
- Кнопка перемикає режими viewer.
- У режимі `MODE_DEMOD` відображаються результати або явне повідомлення про їх відсутність.
- У `MODE_VIEW_DEMOD` один блок I/Q доступний обом гілкам без пошкодження даних.