# ============================================================================
# Makefile - Cocotb testbench for tt_um_universal_memory
# Project    : Universal Memory Cell Development (Hybrid Persistent-RAM)
# Phase      : Day 2, Step 4 - Verification & Testbench Generation
#
# Layout assumed (standard Tiny Tapeout repo pipeline):
#   <repo>/src/tt_um_universal_memory.v   <- DUT RTL
#   <repo>/test/Makefile                  <- this file
#   <repo>/test/test.py                   <- cocotb testbench
#
# Usage:
#   cd test
#   make                 # runs with default sim (icarus)
#   make SIM=verilator   # runs with Verilator instead
#   make clean
# ============================================================================

# ---------------------------------------------------------------------------
# Simulator selection
# ---------------------------------------------------------------------------
SIM ?= icarus
TOPLEVEL_LANG ?= verilog

# ---------------------------------------------------------------------------
# Source locations
# ---------------------------------------------------------------------------
SRC_DIR := $(PWD)/../src

# Gate-level netlist support (Tiny Tapeout GL sim), off by default.
GATES ?= no

ifeq ($(GATES),yes)
    # Gate-level simulation: use the synthesized netlist + sky130 primitives.
    COMPILE_ARGS    += -DGL_TEST
    COMPILE_ARGS    += -DFUNCTIONAL
    COMPILE_ARGS    += -DUSE_POWER_PINS
    COMPILE_ARGS    += -DSIM
    VERILOG_SOURCES += $(PDK_ROOT)/sky130A/libs.ref/sky130_fd_sc_hd/verilog/primitives.v
    VERILOG_SOURCES += $(PDK_ROOT)/sky130A/libs.ref/sky130_fd_sc_hd/verilog/sky130_fd_sc_hd.v
    VERILOG_SOURCES += $(SRC_DIR)/gate_level_netlist.v
else
    # RTL simulation (default path for this testbench).
    VERILOG_SOURCES += $(PWD)/tt_um_universal_memory.v
endif

# ---------------------------------------------------------------------------
# Simulator-specific arguments
# ---------------------------------------------------------------------------
ifeq ($(SIM), icarus)
    COMPILE_ARGS += -DSIM
    ifeq ($(GATES),yes)
        PLUSARGS += -fst
    endif
endif

ifeq ($(SIM), verilator)
    EXTRA_ARGS += --trace --trace-structs
    EXTRA_ARGS += -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM
    EXTRA_ARGS += --timing
endif

# ---------------------------------------------------------------------------
# DUT / cocotb module configuration
# ---------------------------------------------------------------------------
TOPLEVEL = tt_um_universal_memory
MODULE   = test

# Deterministic randomization for the sweep test in test.py; override with
# `make RANDOM_SEED=<n>` if you need to reproduce a specific run.
export RANDOM_SEED ?= 42

# ---------------------------------------------------------------------------
# Cocotb entrypoint
# ---------------------------------------------------------------------------
include $(shell cocotb-config --makefiles)/Makefile.sim

.PHONY: clean-all
clean-all: clean
	rm -rf sim_build results.xml dump.vcd dump.fst __pycache__
