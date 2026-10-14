@echo off
REM ============================================================================
REM build_elf.bat -- build the MicroBlaze firmware (graph viewer) with mb-gcc.
REM
REM Link-time optimization (-flto) lets the compiler inline across the layer
REM files; without it the split code does not fit next to the stack.
REM
REM Bare-metal, no Vitis platform/BSP: startup code, linker script and the few
REM Xilinx headers the drivers need live in vitis\bsp\. Sources: vitis\src\main.c
REM plus every .c in the layer folders (hal, gfx, dsp, source, app). Output:
REM   vitis\elf\df5_app.elf   (loaded by run_board.tcl)
REM
REM mb-gcc is looked up in %XILINX_VITIS%, then in PATH.
REM ============================================================================
setlocal EnableDelayedExpansion

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

set FILES="%SRC%\main.c"
for %%D in (hal gfx dsp source app) do (
    for %%F in ("%SRC%\%%D\*.c") do set FILES=!FILES! "%%F"
)

if not exist "%OUT_DIR%" mkdir "%OUT_DIR%"

"%MB_GCC%" -Os -flto -Wall -Wextra -ffreestanding -nostdlib -fno-stack-protector ^
    -mcpu=v11.0 -mlittle-endian -mxl-soft-mul ^
    -I"%BSP%\include" -I"%SRC%" -T "%BSP%\lscript.ld" ^
    "%BSP%\crt0.S" "%BSP%\stubs.c" %FILES% ^
    -lgcc -o "%OUT_ELF%"
if errorlevel 1 exit /b %errorlevel%

for %%S in ("%MB_GCC%") do set MB_SIZE=%%~dpSmb-size.exe
if exist "%MB_SIZE%" "%MB_SIZE%" "%OUT_ELF%"

echo INFO: ELF ready: %OUT_ELF%
exit /b 0
