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

.PHONY: build size hex clean

build:
	@echo "building Embedded Swift soft SD bootloader (ORIGIN 0x0000, max 8 KiB)..."
	$(SWIFT_BUILD) \
		$(SWIFT_BUILD_ARGS) \
		-Xlinker -T -Xlinker link.ld \
		--verbose
	@echo "extracting binary..."
	$(LLVM_OBJCOPY) -O binary "$(BUILDROOT)/Boot" "$(NAME).bin"
	@# Word-addressed hex for $readmemh (little-endian 32-bit words)
	$(PYTHON) -c "\
d=open('$(NAME).bin','rb').read();\
d=d+b'\\x00'*((4-len(d)%4)%4);\
open('$(NAME).hex','w').write('\\n'.join(f'{int.from_bytes(d[i:i+4],\"little\"):08x}' for i in range(0,len(d),4))+'\\n')"
	@$(MAKE) --no-print-directory size

size:
	@echo "--- $(NAME) size ---"
	@if [ -x "$(LLVM_SIZE)" ]; then \
		"$(LLVM_SIZE)" "$(BUILDROOT)/Boot"; \
	elif command -v riscv64-elf-size >/dev/null 2>&1; then \
		riscv64-elf-size "$(BUILDROOT)/Boot"; \
	else \
		echo "(size tool not found; bin size only)"; \
	fi
	@wc -c "$(NAME).bin" 2>/dev/null || true
	@$(PYTHON) -c "\
import os;\
n=os.path.getsize('$(NAME).bin');\
print(f'bin: {n} bytes ({n/1024:.2f} KiB) of 8192 boot region ({100*n/8192:.1f}% used, {8192-n} free)')"

hex: build

clean:
	@echo "cleaning..."
	@swift package clean
	@rm -rf .build "$(NAME).bin" "$(NAME).hex" map.txt
