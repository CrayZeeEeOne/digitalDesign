# ============================================================
# Vitis / MicroBlaze build script
# Run from scripts/:
#     make vitis
# ============================================================

set SCRIPT_DIR [file normalize [file dirname [info script]]]
set ROOT_DIR   [file normalize "$SCRIPT_DIR/.."]

# ------------------------------------------------------------
# Paths
# ------------------------------------------------------------

set PROJECT_DIR "$ROOT_DIR/project"
set VITIS_WS   "$ROOT_DIR/ws_vitis"

set XSA_FILE "$PROJECT_DIR/DF5_project.xsa"

set APP_DIR   "$ROOT_DIR/vitis/app_component"
set APP_SRC   "$APP_DIR/src/main.c"
set APP_BUILD "$APP_DIR/build"

set PLATFORM_NAME "DF5_platform"
set PROC_NAME     "microblaze_0"
set DOMAIN_NAME   "standalone_microblaze"

set BSP_DIR \
    "$VITIS_WS/$PLATFORM_NAME/$PROC_NAME/$DOMAIN_NAME/bsp"

set BSP_CPU_DIR \
    "$BSP_DIR/$PROC_NAME"

set BSP_INC \
    "$BSP_CPU_DIR/include"

set BSP_LIB \
    "$BSP_CPU_DIR/lib"

set OBJ_FILE  "$APP_BUILD/main.o"
set ELF_FILE  "$APP_BUILD/app_component.elf"
set LSCRIPT   "$APP_BUILD/lscript.ld"

# ------------------------------------------------------------
# Tools
# ------------------------------------------------------------

set MB_GCC "mb-gcc.exe"

# ------------------------------------------------------------
# Helper
# ------------------------------------------------------------

proc run_command {cmd} {
    puts ""
    puts "------------------------------------------"
    puts "Running:"
    puts "  $cmd"
    puts "------------------------------------------"

    if {[catch {exec {*}$cmd} result]} {
        puts ""
        puts "ERROR:"
        puts $result
        exit 1
    }

    if {$result ne ""} {
        puts $result
    }
}

# ------------------------------------------------------------
# Check files
# ------------------------------------------------------------

puts ""
puts "=========================================="
puts "Checking input files"
puts "=========================================="

if {![file exists $XSA_FILE]} {
    puts "ERROR: XSA file does not exist:"
    puts "       $XSA_FILE"
    exit 1
}

if {![file exists $APP_SRC]} {
    puts "ERROR: Application source does not exist:"
    puts "       $APP_SRC"
    exit 1
}

puts "XSA:"
puts "  $XSA_FILE"

puts "Application:"
puts "  $APP_SRC"

# ------------------------------------------------------------
# Remove old workspace
# ------------------------------------------------------------

puts ""
puts "=========================================="
puts "Preparing Vitis workspace"
puts "=========================================="

if {[file exists $VITIS_WS]} {
    puts "Removing existing workspace:"
    puts "  $VITIS_WS"

    file delete -force $VITIS_WS
}

file mkdir $VITIS_WS

if {[file exists $APP_BUILD]} {
    puts "Removing old application build:"
    puts "  $APP_BUILD"

    file delete -force $APP_BUILD
}

file mkdir $APP_BUILD

# ------------------------------------------------------------
# Workspace
# ------------------------------------------------------------

setws $VITIS_WS

# ------------------------------------------------------------
# Create platform
# ------------------------------------------------------------

puts ""
puts "=========================================="
puts "Creating Vitis platform"
puts "=========================================="

puts "Platform : $PLATFORM_NAME"
puts "Processor : $PROC_NAME"
puts "Domain    : $DOMAIN_NAME"
puts ""

platform create \
    -name $PLATFORM_NAME \
    -hw $XSA_FILE \
    -out $VITIS_WS

# ------------------------------------------------------------
# Create standalone domain
# ------------------------------------------------------------

puts ""
puts "=========================================="
puts "Creating standalone domain"
puts "=========================================="

domain create \
    -name $DOMAIN_NAME \
    -os standalone \
    -proc $PROC_NAME

# ------------------------------------------------------------
# Generate platform / BSP
# ------------------------------------------------------------

puts ""
puts "=========================================="
puts "Generating platform / BSP"
puts "=========================================="

platform generate

puts ""
puts "Platform generated successfully."

# ------------------------------------------------------------
# Check BSP
# ------------------------------------------------------------

puts ""
puts "=========================================="
puts "Checking BSP"
puts "=========================================="

if {![file exists $BSP_INC]} {
    puts "ERROR: BSP include directory does not exist:"
    puts "       $BSP_INC"
    exit 1
}

if {![file exists $BSP_LIB]} {
    puts "ERROR: BSP library directory does not exist:"
    puts "       $BSP_LIB"
    exit 1
}

set XPARAMETERS "$BSP_INC/xparameters.h"
set LIBXIL "$BSP_LIB/libxil.a"

if {![file exists $XPARAMETERS]} {
    puts "ERROR: xparameters.h not found:"
    puts "       $XPARAMETERS"
    exit 1
}

if {![file exists $LIBXIL]} {
    puts "ERROR: libxil.a not found:"
    puts "       $LIBXIL"
    exit 1
}

puts "BSP include:"
puts "  $BSP_INC"

puts "BSP library:"
puts "  $BSP_LIB"

puts "xparameters.h:"
puts "  $XPARAMETERS"

puts "libxil.a:"
puts "  $LIBXIL"

# ------------------------------------------------------------
# Generate linker script
# ------------------------------------------------------------

puts ""
puts "=========================================="
puts "Generating linker script"
puts "=========================================="

set lscript_fd [open $LSCRIPT w]

puts $lscript_fd {
OUTPUT_ARCH(microblaze)
ENTRY(_start)

MEMORY
{
    ram : ORIGIN = 0x00002000, LENGTH = 0x2000
}

SECTIONS
{
    .vectors.reset 0x00002000 :
    {
        KEEP(*(.vectors.reset))
    } > ram

    .vectors.sw_exception :
    {
        KEEP(*(.vectors.sw_exception))
    } > ram

    .vectors.interrupt :
    {
        KEEP(*(.vectors.interrupt))
    } > ram

    .vectors.hw_exception :
    {
        KEEP(*(.vectors.hw_exception))
    } > ram

    .text :
    {
        . = ALIGN(4);

        *(.text)
        *(.text.*)

        . = ALIGN(4);
    } > ram

    .init :
    {
        . = ALIGN(4);
        KEEP(*(.init))
        . = ALIGN(4);
    } > ram

    .fini :
    {
        . = ALIGN(4);
        KEEP(*(.fini))
        . = ALIGN(4);
    } > ram

    .rodata :
    {
        . = ALIGN(4);

        *(.rodata)
        *(.rodata.*)

        . = ALIGN(4);
    } > ram

    .sdata :
    {
        . = ALIGN(4);

        _SDA_BASE_ = . + 0x800;

        *(.sdata)
        *(.sdata.*)

        . = ALIGN(4);
    } > ram

    .sbss :
    {
        . = ALIGN(4);

        __sbss_start = .;

        *(.sbss)
        *(.sbss.*)

        __sbss_end = .;

        . = ALIGN(4);
    } > ram

    .data :
    {
        . = ALIGN(4);

        __data_start = .;

        *(.data)
        *(.data.*)

        __data_end = .;

        . = ALIGN(4);
    } > ram

    .sdata2 :
    {
        . = ALIGN(4);

        _SDA2_BASE_ = . + 0x800;

        *(.sdata2)
        *(.sdata2.*)

        . = ALIGN(4);
    } > ram

    .bss :
    {
        . = ALIGN(4);

        __bss_start = .;

        *(.bss)
        *(.bss.*)
        *(COMMON)

        __bss_end = .;

        . = ALIGN(4);
    } > ram

    .heap :
    {
        . = ALIGN(8);

        __heap_start = .;

        . += 0x400;

        __heap_end = .;

        . = ALIGN(8);
    } > ram

    .stack :
    {
        . = ALIGN(8);

        __stack_start = .;

        . += 0x800;

        __stack_end = .;

        . = ALIGN(8);
    } > ram

    PROVIDE(_heap_start  = __heap_start);
    PROVIDE(_heap_end    = __heap_end);

    PROVIDE(_stack       = __stack_end);
    PROVIDE(_stack_start = __stack_start);
    PROVIDE(_stack_end   = __stack_end);
}
}

close $lscript_fd

puts "Linker script:"
puts "  $LSCRIPT"

# ------------------------------------------------------------
# Compile application
# ------------------------------------------------------------

puts ""
puts "=========================================="
puts "Compiling application"
puts "=========================================="

set compile_cmd [list \
    $MB_GCC \
    -O2 \
    -g \
    -Wall \
    -Wextra \
    -mcpu=v11.0 \
    -mlittle-endian \
    -mxl-soft-mul \
    -ffunction-sections \
    -fdata-sections \
    -I$BSP_INC \
    -c \
    $APP_SRC \
    -o \
    $OBJ_FILE \
]

run_command $compile_cmd

if {![file exists $OBJ_FILE]} {
    puts "ERROR: Object file was not generated:"
    puts "       $OBJ_FILE"
    exit 1
}

puts ""
puts "Compilation successful."
puts "Object:"
puts "  $OBJ_FILE"

# ------------------------------------------------------------
# Link application
# ------------------------------------------------------------

puts ""
puts "=========================================="
puts "Linking application"
puts "=========================================="

set link_cmd [list \
    $MB_GCC \
    -mcpu=v11.0 \
    -mlittle-endian \
    -mxl-soft-mul \
    -Wl,--gc-sections \
    -Wl,-T,$LSCRIPT \
    -L$BSP_LIB \
    $OBJ_FILE \
    -lxil \
    -o \
    $ELF_FILE \
]

run_command $link_cmd

# ------------------------------------------------------------
# Check ELF
# ------------------------------------------------------------

if {![file exists $ELF_FILE]} {
    puts ""
    puts "ERROR: ELF file was not generated:"
    puts "       $ELF_FILE"
    exit 1
}

# ------------------------------------------------------------
# Finish
# ------------------------------------------------------------

puts ""
puts "=========================================="
puts "Vitis build completed successfully"
puts "=========================================="
puts ""

puts "Workspace:"
puts "  $VITIS_WS"

puts ""
puts "Platform:"
puts "  $VITIS_WS/$PLATFORM_NAME"

puts ""
puts "BSP:"
puts "  $BSP_DIR"

puts ""
puts "Linker script:"
puts "  $LSCRIPT"

puts ""
puts "ELF:"
puts "  $ELF_FILE"

puts ""
puts "=========================================="
puts ""