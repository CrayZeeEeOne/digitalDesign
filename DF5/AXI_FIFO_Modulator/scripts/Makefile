SHELL := cmd.exe

VIVADO := vivado
VITIS  := vitis

PROJECT_DIR  := ..\project
PROJECT_NAME := DF5_project

PROJECT_FILE := $(PROJECT_DIR)\$(PROJECT_NAME).xpr
XSA_FILE     := $(PROJECT_DIR)\$(PROJECT_NAME).xsa

VITIS_DIR := ..\vitis
VITIS_WS  := ..\ws_vitis
MAIN_C    := ..\vitis\app_component\src\main.c

PROJECT_SCRIPT := project.tcl
BD_SCRIPT      := create_bd.tcl
BUILD_SCRIPT   := build.tcl
PROGRAM_SCRIPT := program.tcl

VITIS_SCRIPT := build_vitis.py
DEBUG_SCRIPT := debug_vitis.py


.PHONY: help check project bd build vitis program debug bit all clean


help:
	@echo.
	@echo ==========================================
	@echo DF5 Project
	@echo ==========================================
	@echo.
	@echo make project  - Create Vivado project
	@echo make bd       - Create Block Design
	@echo make build    - Synthesis, implementation, bitstream and XSA
	@echo make vitis    - Build Vitis platform and application
	@echo make program  - Program FPGA
	@echo make debug    - Run Vitis application
	@echo make bit      - Vivado Flow
	@echo make all      - Run full process 
	@echo make clean    - Remove generated project files
	@echo.


check:
	@echo.
	@echo ==========================================
	@echo Checking project
	@echo ==========================================
	@echo.

	@if not exist "$(PROJECT_FILE)" (echo ERROR: Vivado project does not exist: "$(PROJECT_FILE)" & exit /B 1)

	@if not exist "$(XSA_FILE)" (echo WARNING: XSA does not exist. Run "make build".)

	@if not exist "$(MAIN_C)" (echo ERROR: main.c does not exist: "$(MAIN_C)" & exit /B 1)

	@echo Project:
	@echo   $(PROJECT_FILE)
	@echo.
	@echo XSA:
	@echo   $(XSA_FILE)
	@echo.
	@echo Source:
	@echo   $(MAIN_C)
	@echo.
	@echo Check complete.
	@echo.


project:
	@echo.
	@echo ==========================================
	@echo Creating Vivado project
	@echo ==========================================
	@echo.

	$(VIVADO) -mode batch -source "$(PROJECT_SCRIPT)"

	@echo.
	@echo ==========================================
	@echo Vivado project created
	@echo ==========================================
	@echo.


bd:
	@echo.
	@echo ==========================================
	@echo Creating Block Design
	@echo ==========================================
	@echo.

	@if not exist "$(PROJECT_FILE)" (echo ERROR: Vivado project does not exist. Run "make project" first. & exit /B 1)

	$(VIVADO) -mode batch -source "$(BD_SCRIPT)"

	@echo.
	@echo ==========================================
	@echo Block Design created
	@echo ==========================================
	@echo.


build:
	@echo.
	@echo ==========================================
	@echo Building Vivado project
	@echo ==========================================
	@echo.

	@if not exist "$(PROJECT_FILE)" (echo ERROR: Vivado project does not exist. Run "make project" first. & exit /B 1)

	$(VIVADO) -mode batch -source "$(BUILD_SCRIPT)"

	@echo.
	@echo ==========================================
	@echo Vivado build complete
	@echo ==========================================
	@echo.

	@if not exist "$(XSA_FILE)" (echo ERROR: XSA was not generated: "$(XSA_FILE)" & exit /B 1)

	@echo XSA:
	@echo   $(XSA_FILE)
	@echo.


vitis:
	@echo.
	@echo ==========================================
	@echo Building Vitis application
	@echo ==========================================
	@echo.

	@if not exist "$(XSA_FILE)" (echo ERROR: XSA does not exist. Run "make build" first. & exit /B 1)

	@if not exist "$(MAIN_C)" (echo ERROR: main.c does not exist: "$(MAIN_C)" & exit /B 1)

	@if not exist "$(VITIS_SCRIPT)" (echo ERROR: Vitis script does not exist: "$(VITIS_SCRIPT)" & exit /B 1)

	rmdir /S /Q $(VITIS_WS)

	$(VITIS) -s "$(VITIS_SCRIPT)"

	@echo.
	@echo ==========================================
	@echo Vitis build complete
	@echo ==========================================
	@echo.


program:
	@echo.
	@echo ==========================================
	@echo Programming FPGA
	@echo ==========================================
	@echo.

	@if not exist "$(PROJECT_FILE)" (echo ERROR: Vivado project does not exist. Run "make project" first. & exit /B 1)

	$(VIVADO) -mode batch -source "$(PROGRAM_SCRIPT)"

	@echo.
	@echo ==========================================
	@echo FPGA programmed
	@echo ==========================================
	@echo.


debug:
	@echo.
	@echo ==========================================
	@echo Starting Vitis Debug
	@echo ==========================================
	@echo.

	@if not exist "$(DEBUG_SCRIPT)" (echo ERROR: Debug script does not exist: "$(DEBUG_SCRIPT)" & exit /B 1)

	$(VITIS) -s "$(DEBUG_SCRIPT)"

	@echo.
	@echo ==========================================
	@echo Vitis Debug finished
	@echo ==========================================
	@echo.


bit: project bd build 

all: project bd build vitis program debug


clean:
	@echo.
	@echo ==========================================
	@echo Cleaning generated files
	@echo ==========================================
	@echo.

	@if exist "$(PROJECT_DIR)" rmdir /S /Q "$(PROJECT_DIR)"
	@if exist "$(VITIS_WS)" rmdir /S /Q "$(VITIS_WS)"

	@echo.
	@echo Clean complete.
	@echo.