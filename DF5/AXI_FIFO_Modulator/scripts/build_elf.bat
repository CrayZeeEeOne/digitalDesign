@echo off
REM ============================================================================
REM build_elf.bat -- build the MicroBlaze firmware (graph viewer) with mb-gcc.
REM
REM Bare-metal, no Vitis platform/BSP: startup code, linker script and the few
REM Xilinx headers the drivers need live in vitis\bsp\. Output:
REM   vitis\elf\df5_app.elf   (loaded by run_board.tcl)
REM
REM mb-gcc is looked up in %XILINX_VITIS%, then in PATH.
REM ============================================================================
setlocal

set SCRIPT_DIR=%~dp0
set ROOT_DIR=%SCRIPT_DIR%..
set SRC=%ROOT_DIR%\vitis\src
set BSP=%ROOT_DIR%\vitis\bsp
set OUT_DIR=%ROOT_DIR%\vitis\elf
set OUT_ELF=%OUT_DIR%\df5_app.elf

set MB_GCC=
if defined XILINX_VITIS if exist "%XILINX_VITIS%\gnu\microblaze\nt\bin\mb-gcc.exe" set MB_GCC=%XILINX_VITIS%\gnu\microblaze\nt\bin\mb-gcc.exe
if not defined MB_GCC for /f "delims=" %%G in ('where mb-gcc 2^>nul') do if not defined MB_GCC set MB_GCC=%%G
if not defined MB_GCC (
    echo ERROR: mb-gcc not found. Set XILINX_VITIS to the Vitis install
    echo        directory, e.g. C:\AMDDesignTools\2025.2.1\Vitis, or add
    echo        Vitis\gnu\microblaze\nt\bin to PATH.
    exit /b 1
)

if not exist "%OUT_DIR%" mkdir "%OUT_DIR%"

"%MB_GCC%" -Os -Wall -Wextra -ffreestanding -nostdlib -fno-stack-protector ^
    -mcpu=v11.0 -mlittle-endian -mxl-soft-mul ^
    -I"%BSP%\include" -I"%SRC%" -T "%BSP%\lscript.ld" ^
    "%BSP%\crt0.c" "%BSP%\stubs.c" ^
    "%SRC%\main.c" "%SRC%\graph_viewer.c" "%SRC%\spi_tft.c" "%SRC%\tft.c" ^
    "%SRC%\font5x7.c" "%SRC%\dsp_tables.c" "%SRC%\system_ctrl.c" ^
    -lgcc -o "%OUT_ELF%"
if errorlevel 1 exit /b %errorlevel%

for %%S in ("%MB_GCC%") do set MB_SIZE=%%~dpSmb-size.exe
if exist "%MB_SIZE%" "%MB_SIZE%" "%OUT_ELF%"

echo INFO: ELF ready: %OUT_ELF%
exit /b 0
