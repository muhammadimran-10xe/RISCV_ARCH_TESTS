TOOLCHAIN := riscv64-unknown-elf
AS := $(TOOLCHAIN)-as
CC := $(TOOLCHAIN)-gcc
OBJDUMP := $(TOOLCHAIN)-objdump


C_FLAGS := -march=rv32g -mabi=ilp32 -nostdlib
SRC := ./src/test.S
LD_SCRIPT := ./src/link.ld
.PHONY: build clean run help

all: clean build run

build:
	@$(CC) $(C_FLAGS) -T $(LD_SCRIPT) $(SRC) -o ./logs/test.elf 
	@$(OBJDUMP) -d ./logs/test.elf > ./logs/test.dis

run:
	@spike --isa=rv32i -l --log-commits +signature=./logs/test.signature.output +signature-granularity=1 ./logs/test.elf >./logs/spike.out 2>./logs/spike.log

debug:
	@spike --isa=rv32i -d ./logs/test.elf

clean:
	@rm -f ./logs/*

help:
	@echo "Makefile for building and running RISC-V assembly tests"
	@echo "Available targets:"
	@echo "  build  - Compile the assembly code into an ELF binary"
	@echo "  run    - Run the compiled ELF binary using Spike simulator"
	@echo "  debug  - Run the compiled ELF binary in debug mode using Spike simulator"
	@echo "  clean  - Remove generated files"

