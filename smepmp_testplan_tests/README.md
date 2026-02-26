#  Test to verify smepmp extension behaviour in spike (Task 7)

## Overview
This test verifies the behavior of the Smepmp in RISC-V systems by evaluating how the mseccfg.MML bit affects Machine mode execution and memory access permissions when PMP (Physical Memory Protection) rules are configured.

---

## File Structure
├── docs/
| ├── muhammdimran_task7.pdf
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

RISC-V smepmp extention behaviour test

## Author
Muhammad Imran
Task 7 – Test to verify smepmp extension behaviour in spike
