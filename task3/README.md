# RISC-V Privilege Mode Switching Test (Task 1)

## Overview
This task implements and verifies RISC-V privilege mode transitions using assembly language and the Spike ISS.  
The test starts in Machine mode (M-mode), installs an M-mode trap handler, and demonstrates controlled switching between Machine (M), Supervisor (S), and User (U)modes using standard RISC-V CSRs and return instructions.

---

## Objectives
- Start execution in **Machine mode**
- Implement a function to switch to **Supervisor (a0=0)** or **User (a0=1)** mode (callable only from M-mode)
- Install an **M-mode trap handler**
- Handle:
  - `ECALL` from U-mode → return to S-mode
  - `ECALL` from S-mode → return to M-mode
- Verify current privilege mode
- Exit cleanly from M-mode using `tohost`

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

## Reference

The RISC-V Instruction Set Manual, Volume II: Privileged Architecture

## Author
Muhammad Imran
Task 1 – RISC-V Privilege Mode Switching