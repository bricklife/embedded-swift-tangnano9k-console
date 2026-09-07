# embedded-swift-tangnano9k-console
#
# Top-level convenience targets.

.PHONY: synth run flash clean gprj bootloader apps help submodules

help:
	@echo "Targets:"
	@echo "  make submodules  - init FPGA submodules (hazard3, libfpga, fpgascripts)"
	@echo "  make synth       - build bootloader + FPGA bitstream"
	@echo "  make run         - synth + program Tang Nano 9K SRAM"
	@echo "  make flash       - synth + program Tang Nano 9K Flash"
	@echo "  make gprj        - write Gowin EDA GUI project (fpga/*.gprj)"
	@echo "  make bootloader  - build Embedded Swift SD bootloader only"
	@echo "  make apps        - build all software apps"
	@echo "  make clean       - clean FPGA build + bootloader"

submodules:
	git submodule update --init
	git -C fpga/third_party/hazard3 submodule update --init scripts

synth run flash clean gprj:
	$(MAKE) -C fpga $@

bootloader:
	$(MAKE) -C bootloader

apps:
	@for d in software/pong software/dodge software/flappy software/sfx; do \
		echo "==> $$d"; $(MAKE) -C $$d || exit 1; \
	done
