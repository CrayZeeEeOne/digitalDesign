@echo off
REM ============================================================================
REM run_host_sim.bat -- render all viewer screens on the PC, without the board.
REM
REM Builds the firmware's source/dsp/app/gfx code with a host gcc, replacing the
REM SPI driver by an ST7789 emulator (st7789_emu.c), saves out\viewNN.ppm and
REM compares them with golden.md5 (check.py). Also writes out\montage.png when
REM Python has Pillow.
REM
REM   run_host_sim.bat            render + compare with golden.md5
REM   run_host_sim.bat -update    render + store the result as the new golden.md5
REM
REM gcc: %XILINX_VITIS%\..\tps\mingw\...\gcc.exe (ships with Vitis), else PATH.
REM ============================================================================
setlocal

set HERE=%~dp0
set SRC=%HERE%..\..\vitis\src
set OUT=%HERE%out

set GCC=
if defined XILINX_VITIS if exist "%XILINX_VITIS%\..\tps\mingw\10.0.0\win64.o\nt\bin\gcc.exe" set GCC=%XILINX_VITIS%\..\tps\mingw\10.0.0\win64.o\nt\bin\gcc.exe
if not defined GCC for /f "delims=" %%G in ('where gcc 2^>nul') do if not defined GCC set GCC=%%G
if not defined GCC (
    echo ERROR: host gcc not found. Set XILINX_VITIS or add a gcc to PATH.
    exit /b 1
)
for %%G in ("%GCC%") do set PATH=%%~dpG;%PATH%

if not exist "%OUT%" mkdir "%OUT%"

"%GCC%" -O1 -Wall -Wextra -I"%SRC%" -I"%HERE%." ^
    "%HERE%host_main.c" "%HERE%st7789_emu.c" ^
    "%SRC%\gfx\tft.c" "%SRC%\gfx\font5x7.c" "%SRC%\gfx\plot.c" ^
    "%SRC%\dsp\*.c" "%SRC%\source\*.c" "%SRC%\app\*.c" ^
    "%SRC%\hal\sd_card.c" "%SRC%\lib\fatfs\*.c" "%HERE%axi_qspi_stub.c" ^
    -o "%OUT%\host_sim.exe"
if errorlevel 1 exit /b %errorlevel%

"%OUT%\host_sim.exe" "%OUT%"
if errorlevel 1 exit /b %errorlevel%

python "%HERE%check.py" "%OUT%" %1
exit /b %errorlevel%
