# RISC-V Physical Memory Protection (Task 2)

## Overview
This test creates and configures two memory regions with different constraints and verifies them. One follows the TOR addressing method with 'X' permissions and other follows the NAPOT addressing method with 'R' permissions. PMP checks are also applied on the existing memory regions created in the previous tasks. Load , Stores and Executes accesses are tested from the lower privilege modes on these configured memory regions and verified that configured PMP restrictions are working correctly. Each access gives the appropriate access fault. At the end the same restrictions are also set for Machine mode setting the lock bit of each PMP region and appropriate access faults are again tested and verified for Machine mode. Trap handler for corresponding access faults is also added to the trap vector to address the access faults.
---

## File Structure
├── docs/
| ├── muhammdimran_task2.pdf
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

The RISC-V Instruction Set Manual, Volume II: Privileged Architecture Sec 3.1.8

## Author
Muhammad Imran
Task 2 – RISC-V Physical Memory Protection
