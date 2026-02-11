# RISC-V S-Mode Exception Delegation Test (Task 3)

## Overview
This task implements and verifies exception delegation and privilege-level trap handling in a RISC-V processor using assembly language and the Spike ISA simulator.

---

## File Structure
├── docs/
| ├── muhammdimran_task1.pdf
├── src/
│ ├── test.S # Main assembly test
│ ├── macro.S # Register save/restore macros
│ └── link.ld # Linker script
├── logs/
│ ├── test.elf # Compiled ELF
│ ├── test.dis # Disassembly
│ ├── spike.log # Spike execution log 
│ ├── spike.out # Spike output 
│ └── test.signature.output # Signature file
├── Makefile
├── README.md

## Build and Run Instructions

### Build
make build

### Run on Spike
make run

### Debug on Spike
make debug

### Clean Generated files
make clean

### clean build and run on Spike

make all

## Reference

The RISC-V Instruction Set Manual, Volume II: Privileged Architecture Sec 3.1.8

## Author
Muhammad Imran
Task 3 – RISC-V Trap Delegation to S-Mode