#  test to change behaviour of a locked pmp region using smepmp extension in spike (Task 6)

## Overview
This test verifies the behavior of a locked PMP region and demonstrates how the Smepmp extension (mseccfg.RLB bit) allows modification of a locked PMP entry without reset.

---

## File Structure
├── docs/
| ├── muhammdimran_task6.pdf
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
Task 6 – RISC-V smepmp extention behaviour test
