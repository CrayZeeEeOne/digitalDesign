@echo off
REM ============================================================================
REM sim_tb.bat -- run one self-checking testbench in xsim without a Vivado project.
REM
REM   sim_tb.bat tb_rtl_demod          compile all RTL + the TB, run it
REM   sim_tb.bat tb_dsp_top -gui       same, open the waveform viewer
REM
REM Work files go to vivado\xsim_<tb>\ (git-ignored). The sim_data paths are passed
REM as +plusargs, so every TB finds its data (tb_dsp_top: hop.iq, others: sim.iq) from any directory.
REM Needs xvlog/xelab/xsim in PATH (Vivado 2025.2.1 bin).
REM ============================================================================
setlocal
if "%~1"=="" (
    echo usage: sim_tb.bat ^<tb_name^> [-gui]
    exit /b 1
)
set TB=%~1
set ROOT=%~dp0..
set RTL=%ROOT%\vivado\sources\rtl
set TBDIR=%ROOT%\vivado\sources\tb
set DATA=%ROOT%\vivado\sources\sim_data
set WORK=%ROOT%\vivado\xsim_%TB%

if not exist "%WORK%" mkdir "%WORK%"
cd /d "%WORK%"
copy /y "%ROOT%\vivado\sources\mem\*.mem" . >nul

REM xvlog does not expand wildcards: build the file lists here
set SV=
for %%F in ("%RTL%\*.sv") do call set SV=%%SV%% "%%~fF"
set V=
for %%F in ("%RTL%\*.v") do call set V=%%V%% "%%~fF"
REM sd_card_model.sv: the microSD model shared by the testbenches
call xvlog -sv --nolog %SV% "%TBDIR%\sd_card_model.sv" "%TBDIR%\%TB%.sv" > xvlog.txt 2>&1
if errorlevel 1 (type xvlog.txt & exit /b 1)
call xvlog --nolog %V% >> xvlog.txt 2>&1
if errorlevel 1 (type xvlog.txt & exit /b 1)
call xelab --nolog -debug typical -timescale 1ns/1ps %TB% -s %TB%_snap > xelab.txt 2>&1
if errorlevel 1 (type xelab.txt & exit /b 1)

REM plusargs go through an options file: cmd would split "NAME=value" at the "="
set D=%DATA:\=/%
set IQ=sim.iq
if /i "%TB%"=="tb_dsp_top" set IQ=hop.iq
> xsim_args.txt echo -testplusarg IQ_FILE=%D%/%IQ%
>> xsim_args.txt echo -testplusarg EXPECT_FILE=%D%/sim.expect.txt
>> xsim_args.txt echo -testplusarg TRACE_FILE=%D%/sim.trace.txt
if /i "%~2"=="-gui" (
    call xsim %TB%_snap -gui -f xsim_args.txt
    exit /b %errorlevel%
)
call xsim %TB%_snap --nolog -R -f xsim_args.txt > xsim.txt 2>&1
set RC=%errorlevel%
type xsim.txt
findstr /c:"RESULT: FAIL" /c:"Error:" /c:"FATAL" xsim.txt >nul && set RC=1

REM tb_dsp_top: the capture dump is checked against the C algorithm (bit-exact)
if /i "%TB%"=="tb_dsp_top" (
    python -I "%ROOT%\tools\check_dsp_capture.py" "%DATA%\hop.iq" dsp_capture_dump.txt
    if errorlevel 1 set RC=1
)
exit /b %RC%
