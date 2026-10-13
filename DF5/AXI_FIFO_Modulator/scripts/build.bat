@echo off
REM ============================================================================
REM build.bat -- unified Vivado build entry point
REM Usage from scripts\:
REM   build.bat            create/update project only
REM   build.bat -syn       run synthesis
REM   build.bat -impl      run implementation + bitstream
REM   build.bat -xsa       export XSA to vitis\platform\
REM   build.bat -all       run all stages
REM   build.bat -sim       run testbench simulation
REM   build.bat -gui       open project in Vivado GUI
REM   build.bat -board     full flow + firmware (build_elf.bat) + load bit and ELF over JTAG
REM   build.bat -clean     remove generated vivado\project
REM ============================================================================

setlocal
set SCRIPT_DIR=%~dp0
set ROOT_DIR=%SCRIPT_DIR%..
set PROJ_DIR=%ROOT_DIR%\vivado\project

set XIL_USER_DIR=%SCRIPT_DIR%.user
if not exist "%XIL_USER_DIR%" mkdir "%XIL_USER_DIR%"
if not exist "%XIL_USER_DIR%\AppData\Roaming" mkdir "%XIL_USER_DIR%\AppData\Roaming"
if not exist "%XIL_USER_DIR%\AppData\Local" mkdir "%XIL_USER_DIR%\AppData\Local"
if not exist "%XIL_USER_DIR%\Home" mkdir "%XIL_USER_DIR%\Home"

set APPDATA=%XIL_USER_DIR%\AppData\Roaming
set LOCALAPPDATA=%XIL_USER_DIR%\AppData\Local
set USERPROFILE=%XIL_USER_DIR%\Home
set HOME=%XIL_USER_DIR%\Home
set XILINX_LOCAL_USER_DATA=%XIL_USER_DIR%
where vivado >nul 2>nul
if errorlevel 1 (
    echo ERROR: vivado not found in PATH.
    echo        Run from Vivado Tcl Shell or add Vivado bin to PATH.
    exit /b 1
)

if "%1"=="-clean" (
    echo Removing %PROJ_DIR%
    if exist "%PROJ_DIR%" rmdir /s /q "%PROJ_DIR%"
    echo Done.
    exit /b 0
)

if "%1"=="-gui" (
    vivado -mode gui -source "%SCRIPT_DIR%build.tcl"
    exit /b %errorlevel%
)

if "%1"=="-sim" (
    vivado -mode batch -notrace ^
           -source "%SCRIPT_DIR%build.tcl" ^
           -source "%SCRIPT_DIR%sim.tcl"
    exit /b %errorlevel%
)

if "%1"=="-board" (
    call "%~f0" -all
    if errorlevel 1 exit /b %errorlevel%

    call "%SCRIPT_DIR%build_elf.bat"
    if errorlevel 1 exit /b %errorlevel%

    where xsct >nul 2>nul
    if errorlevel 1 (
        echo ERROR: xsct not found in PATH.
        echo        Add Vitis\bin to PATH or run from Vitis Command Prompt.
        exit /b 1
    )

    xsct "%SCRIPT_DIR%run_board.tcl"
    exit /b %errorlevel%
)

set STAGE=
if "%1"=="-syn"  set STAGE=syn
if "%1"=="-impl" set STAGE=impl
if "%1"=="-bit"  set STAGE=bit
if "%1"=="-xsa"  set STAGE=xsa
if "%1"=="-all"  set STAGE=all

if "%STAGE%"=="" (
    vivado -mode batch -notrace -source "%SCRIPT_DIR%build.tcl"
    exit /b %errorlevel%
)

vivado -mode batch -notrace ^
       -source "%SCRIPT_DIR%run_stage.tcl" ^
       -tclargs %STAGE%
exit /b %errorlevel%