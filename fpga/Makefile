# Tang Nano 9K (GW1NR-9C) synthesis for embedded-swift-tangnano9k-console
#
# Usage:
#   make synth   # build bootloader hex + bitstream
#   make run     # write bitstream to SRAM
#   make flash   # write bitstream to Flash

REPO_ROOT := $(abspath ..)
HDL       := $(abspath third_party/hazard3/hdl)
LIBFPGA   := $(abspath third_party/libfpga)
SCRIPTS   := $(abspath third_party/hazard3/scripts)

CHIPNAME      := fpga_tangnano9k
DOTF          := rtl/filelist/fpga_tangnano9k.f
BUILD_DIR     := build

DEVICE_FAMILY := GW1NR-9C
DEVICE_PART   := GW1NR-LV9QN88PC6/I5

GW_SH           ?= /Applications/GowinIDE_V1.9.12.02_SP2.app/Contents/Resources/Gowin_EDA/IDE/bin/gw_sh
OPENFPGA_LOADER ?= openFPGALoader
PYTHON          ?= python3

# Soft SD bootloader (Embedded Swift) — always preloaded into SRAM.
SW_DIR      := $(abspath $(REPO_ROOT)/bootloader)
# abspath for file lists / rules; $readmemh uses basename (cwd = BUILD_DIR).
PRELOAD_HEX := $(abspath $(BUILD_DIR)/bootloader.hex)
PRELOAD_V   := $(abspath $(BUILD_DIR)/preload.v)

# preload.v must come FIRST so TANGNANO9K_PRELOAD_FILE is defined before
# fpga_tangnano9k.v is parsed (Gowin EDA processes files in list order).
export HDL LIBFPGA
SRCS    := $(PRELOAD_V) $(shell HDL=$(HDL) LIBFPGA=$(LIBFPGA) $(SCRIPTS)/listfiles $(DOTF))
INCDIRS := $(shell HDL=$(HDL) LIBFPGA=$(LIBFPGA) $(SCRIPTS)/listfiles -f flati $(DOTF))

CST          := $(abspath fpga_tangnano9k.cst)
SDC          := $(abspath fpga_tangnano9k.sdc)
FILELIST_TCL := $(abspath $(BUILD_DIR)/filelist.tcl)
BITSTREAM    := $(BUILD_DIR)/impl/pnr/$(CHIPNAME).fs

.PHONY: synth run flash clean clean-synth sw gprj

synth: $(BITSTREAM)

$(BITSTREAM): $(SRCS) $(CST) $(SDC) project.tcl Makefile
	mkdir -p $(BUILD_DIR)
	@echo "set SRCS {$(SRCS)}" > $(FILELIST_TCL)
	@echo "set INCDIRS {$(INCDIRS)}" >> $(FILELIST_TCL)
	cd $(BUILD_DIR) && $(GW_SH) $(abspath project.tcl) \
		$(DEVICE_FAMILY) $(DEVICE_PART) $(CHIPNAME) \
		$(CST) $(SDC) $(FILELIST_TCL)

sw: $(PRELOAD_V)

$(PRELOAD_HEX): $(SW_DIR)/bootloader.hex | $(BUILD_DIR)
	cp $< $@

$(SW_DIR)/bootloader.hex:
	$(MAKE) -C $(SW_DIR)

# Define TANGNANO9K_PRELOAD_FILE as a path relative to BUILD_DIR (gw_sh cwd).
$(PRELOAD_V): $(PRELOAD_HEX) | $(BUILD_DIR)
	@echo '`define TANGNANO9K_PRELOAD_FILE "bootloader.hex"' > $@

$(BUILD_DIR):
	mkdir -p $@

# Generate a Gowin EDA GUI project sharing the same RTL / constraints / file list.
gprj: sw $(CST) $(SDC) project.tcl Makefile
	mkdir -p $(BUILD_DIR)
	@echo "set SRCS {$(SRCS)}" > $(FILELIST_TCL)
	@echo "set INCDIRS {$(INCDIRS)}" >> $(FILELIST_TCL)
	cd $(BUILD_DIR) && $(GW_SH) $(abspath project.tcl) \
		$(DEVICE_FAMILY) $(DEVICE_PART) $(CHIPNAME) \
		$(CST) $(SDC) $(FILELIST_TCL) save-only

run: synth
	$(OPENFPGA_LOADER) --board tangnano9k --write-sram $(BITSTREAM)

flash: synth
	$(OPENFPGA_LOADER) --board tangnano9k --write-flash $(BITSTREAM)

clean-synth:
	rm -rf $(BUILD_DIR)/impl $(BUILD_DIR)/filelist.tcl

clean:
	rm -rf $(BUILD_DIR)
	$(MAKE) -C $(SW_DIR) clean
