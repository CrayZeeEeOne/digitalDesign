@echo off
setlocal

set SCRIPT_DIR=%~dp0AXI_FIFO_Modulator\scripts\
set ROOT_DIR=%~dp0AXI_FIFO_Modulator\

set BIT=%ROOT_DIR%vivado\project\DF5_project.runs\impl_1\microblaze_wrapper.bit
if not exist "%BIT%" (
    echo ERROR: bitstream not found:
    echo        %BIT%
    echo Run full build once: call "%SCRIPT_DIR%build.bat" -all
    exit /b 1
)

where xsct >nul 2>nul
if errorlevel 1 (
    echo ERROR: xsct not found in PATH.
    echo        Add Vitis\bin to PATH or run from Vitis Command Prompt.
    exit /b 1
)

xsct "%SCRIPT_DIR%run_board.tcl"
exit /b %errorlevel%
