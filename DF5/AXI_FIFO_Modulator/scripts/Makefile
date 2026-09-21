VIVADO := vivado
XSCT   := xsct

ROOT_DIR        := ..
PROJECT_DIR     := $(ROOT_DIR)/project
VITIS_DIR       := $(ROOT_DIR)/vitis
VITIS_WS        := $(ROOT_DIR)/ws_vitis
LOG_DIR         := $(ROOT_DIR)/logs
SCRIPT_DIR      := .

PROJECT_NAME := DF5_project
PROJECT_FILE := $(PROJECT_DIR)/$(PROJECT_NAME).xpr

BITSTREAM := $(PROJECT_DIR)/$(PROJECT_NAME).runs/impl_1/system_wrapper.bit
XSA       := $(PROJECT_DIR)/$(PROJECT_NAME).xsa
ELF       := $(VITIS_DIR)/app_component/build/app_component.elf


.PHONY: all
all: full


.PHONY: project
project:
	@if not exist "$(LOG_DIR)" mkdir "$(LOG_DIR)"
	$(VIVADO) -mode batch -source "$(SCRIPT_DIR)/project.tcl" -log "$(LOG_DIR)/project.log"


.PHONY: bd
bd: project
	$(VIVADO) -mode batch -source "$(SCRIPT_DIR)/bd.tcl" -log "$(LOG_DIR)/bd.log"


.PHONY: bitstream
bitstream: bd
	$(VIVADO) -mode batch -source "$(SCRIPT_DIR)/build.tcl" -log "$(LOG_DIR)/build.log"


$(XSA): bitstream
	@if not exist "$(XSA)" (echo ERROR: XSA was not generated & exit /b 1)


.PHONY: xsa
xsa: $(XSA)


.PHONY: vitis
vitis: $(XSA)
	$(XSCT) "$(SCRIPT_DIR)/vitis.tcl"


.PHONY: full
full: bitstream vitis


.PHONY: program
program:
	@if not exist "$(BITSTREAM)" (echo ERROR: Bitstream not found: "$(BITSTREAM)" & exit /b 1)
	@if not exist "$(ELF)" (echo ERROR: ELF not found: "$(ELF)" & exit /b 1)
	@if not exist "$(LOG_DIR)" mkdir "$(LOG_DIR)"
	$(VIVADO) -mode batch -source "$(SCRIPT_DIR)/program.tcl" -log "$(LOG_DIR)/program.log"
	$(XSCT) "$(SCRIPT_DIR)/load_elf.tcl"


.PHONY: clean
clean:
	@if exist "$(PROJECT_DIR)" rmdir /S /Q "$(PROJECT_DIR)"
	@if exist "$(VITIS_WS)" rmdir /S /Q "$(VITIS_WS)"
	@if exist "$(VITIS_DIR)\app_component\build" rmdir /S /Q "$(VITIS_DIR)\app_component\build"
	@if exist "$(LOG_DIR)" rmdir /S /Q "$(LOG_DIR)"


.PHONY: help
help:
	@echo.
	@echo Available targets:
	@echo.
	@echo   make           - full Vivado + Vitis build
	@echo   make full      - full Vivado + Vitis build
	@echo   make project   - recreate Vivado project
	@echo   make bd        - recreate Block Design
	@echo   make bitstream - synthesize, implement and generate bitstream
	@echo   make xsa       - generate XSA
	@echo   make vitis     - build MicroBlaze ELF
	@echo   make program   - program FPGA and load ELF
	@echo   make clean     - remove generated files
	@echo.