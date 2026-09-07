NAME := $(shell basename $(CURDIR))

# swiftly-installed open-source Swift 6.3.2 (RISC-V). Do not use Xcode Swift.
SWIFT_TOOLCHAIN  ?= $(HOME)/Library/Developer/Toolchains/swift-6.3.2-RELEASE.xctoolchain
export PATH := $(SWIFT_TOOLCHAIN)/usr/bin:$(HOME)/.swiftly/bin:$(PATH)
export TOOLCHAINS := org.swift.632202605101a

TOOLSET          := toolset.json
LLVM_OBJCOPY     := $(SWIFT_TOOLCHAIN)/usr/bin/llvm-objcopy
LLVM_SIZE        := $(SWIFT_TOOLCHAIN)/usr/bin/llvm-size
SWIFT_BUILD      := swift build
PYTHON           ?= python3

ARCH             := riscv32
TARGET           := $(ARCH)-none-none-eabi
SWIFT_BUILD_ARGS := \
	--build-system native \
	--configuration release \
	--triple $(TARGET) \
	--toolset $(TOOLSET)
BUILDROOT        := $(shell $(SWIFT_BUILD) $(SWIFT_BUILD_ARGS) --show-bin-path)

.PHONY: build size clean

build:
	@echo "building SFX app image (linked at 0x2000 for soft SD boot)..."
	$(SWIFT_BUILD) \
		$(SWIFT_BUILD_ARGS) \
		-Xlinker -T -Xlinker link.ld \
		--verbose
	@echo "extracting binary..."
	$(LLVM_OBJCOPY) \
		-O binary \
		"$(BUILDROOT)/Game" \
		"$(NAME).bin"
	@$(MAKE) --no-print-directory size
	@echo "note: copy as SD root PROG.BIN; soft boot loads it to 0x2000"

size:
	@echo "--- $(NAME) size ---"
	@if [ -x "$(LLVM_SIZE)" ]; then \
		"$(LLVM_SIZE)" "$(BUILDROOT)/Game"; \
	elif command -v riscv64-elf-size >/dev/null 2>&1; then \
		riscv64-elf-size "$(BUILDROOT)/Game"; \
	fi
	@wc -c "$(NAME).bin" 2>/dev/null || true

clean:
	@echo "cleaning..."
	@swift package clean
	@rm -rf .build "$(NAME).bin" map.txt
