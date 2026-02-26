# RISC-V VM sv-32 paging test (Task 5)

## Overview
This test verifies the correct implementation of RISC-V Virtual Memory paging, specifically the address translation mechanism using page tables. The objective of the test is to confirm that when virtual memory is enabled (via the satp register), instruction fetches, loads, and stores go through proper virtual-to-physical address translation according to the configured paging mode Sv32.

---

## File Structure
├── docs/
| ├── muhammdimran_task5.pdf
├── src/
│ ├── test.S # Main assembly test
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

### To read the test.elf file
make read_elf

### Clean Generated files
make clean

### clean build and run on Spike

make all

## Reference

Sv32: Page-Based 32-bit Virtual-Memory Systems, Volume II: Privileged Architecture Sec 4.3

## Author
Muhammad Imran
Task 5 – RISC-V VM SV-32 Paging Scheme Test
