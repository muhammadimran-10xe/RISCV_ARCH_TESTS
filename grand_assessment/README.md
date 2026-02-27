# Hypervisor Extension - Two-Stage Translation and Guest Memory Access (Grand Assessment)

## Overview
 * This test implements a privilege transitions :
 *   M-mode → HS-mode (Hypervisor Supervisor) → VS-mode (Virtual Supervisor) → VU-mode (Virtual User)
 * and exercises the RISC-V Hypervisor Extension (H-extension) features:
 *   - Two-stage address translation via vsatp (VS-stage) + hgatp (G-stage)
 *   - HLV.WU  : Hypervisor Load  Word Unsigned — data read  from guest memory
 *   - HSV.W   : Hypervisor Store Word          — data write to guest memory
 *   - HLVX.WU : Hypervisor Load  Word Unsigned — instruction fetch from guest code 
 *   - Trap delegation using medeleg (bits 8, 10, 12, 13, 15)

---

## File Structure
├── docs/
| ├── muhammdimran_grand_assessment.pdf
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

Hypervisor Extension, Version 1.0: Privileged Architecture Sec 8

## Author
Muhammad Imran
Grand Assessment – Hypervisor Extension - Two-Stage Translation and Guest Memory Access 
