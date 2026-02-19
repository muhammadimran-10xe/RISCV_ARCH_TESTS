#define RVTEST_DATA_BEGIN                                               \
        .pushsection .tohost,"aw",@progbits;                            \
        .align 6; .global tohost; tohost: .dword 0; .size tohost, 8;    \
        .align 6; .global fromhost; fromhost: .dword 0; .size fromhost, 8;\
        .popsection;  

#define RVTEST_CODE_BEGIN                                               \
        .section .text.init;                                            \
        .align  6;                                                      \
        .global _start;  
# TOR Region
.section .tor_section,"aw" 
tor:
    nop
    ret
# NAPOT Region
.section .napot_section, "aw"
napot:
    .word 0xdeadbeef

RVTEST_CODE_BEGIN                         
_start:            
    # Initialize Trap Vector to handle traps                     
    la t6, trap_vector       
    csrw mtvec, t6
/*
PMP Regions:
pmpaddr0 ==> code region (TOR) RWX permissions
pmpaddr1 ==> TOR Region with execute only permission
pmpaddr2 ==> NAPOT region with read only permission
*/
    # clear PMP configuration initially or it may read garbage configuration
    li t2, 0x00000000             # clear it
    csrw pmpcfg0, t2   

    # pmpaddr0 defines the lower bound for TOR entry 
    la   t0, _end                 # address of the _end(label in linker script) of the code region
    srli t0, t0, 2               # Addresses are word aligned (paddr >> 2)
    csrw pmpaddr0, t0  

    # pmpaddr1 defines the upper bound for TOR entry 
    la t0,_tor_end
    srli t0, t0, 2
    csrw pmpaddr1, t0

    # --- configure PMP Entry 1 as TOR with Execute (X) only ---
    # Config byte: L=0, A=01 (TOR), X=1, W=0, R=0 -> 0b00001100 (0x0C)
    li t1, 0x0c                     #   pmp1cfg = 0b00001100
    slli t1, t1, 8                  # to align with pmpcfg0[15:8]
    csrr t0, pmpcfg0
    or t0, t0, t1
    csrw pmpcfg0, t0               # write at pmpcfg0[15:8]

    # --- configure PMP Entry 2 as NAPOT with Read (R) only ---
    # Range is determined by the number of trailing 1s in pmpaddr
    la t0, _napot_start
    srli t0, t0, 2
    li   t1, 0x1FF        # pmpaddr must have nine 1's for a region of size 4KB
    or   t0, t0, t1
    csrw pmpaddr2, t0  

    # Config byte: L=0, A=11 (NAPOT), X=0, W=0, R=1 -> 0b00011001 (0x19)
    li t2, 0x19           # pmp2cfg = 0b00011001
    slli t2, t2, 16       # to align with pmpcfg0[23:16]
    csrr t0, pmpcfg0
    or t0, t0, t2
    csrw pmpcfg0, t0      # write at pmpcfg0[23:16]
/*
    after configuring TOR and NAPOT region when we switch to S-Mode or U-Mode, the processor checks PMP for EVERY access.
    If the current PC (instruction fetch) isn't in a PMP-protected range with 'X' permission, 
    it will trigger an immediate Instruction Access Fault.Since the code region which have the program 
    is not configured yet.
    so we need to configure the code region too
*/
    # --- configure PMP Entry 0 for the Code region ---
    # Full permissions (RWX) required to avoid inst_access faults faulting when switching modes
    # Config byte: L=0, A=01 (TOR), X=1, W=1, R=1 -> 0b00001111 (0x0F)
    li t2, 0x0f                # TOR region    pmp0cfg = 0b00001111
    csrr t0, pmpcfg0
    or t0, t0, t2
    csrw pmpcfg0, t0          # write at pmpcfg0[7:0]

    j main                  
    
main:
    .align 6
    li t0, 0
    jal switch_mode          # supervisor mode

    # --- TEST : TOR REGION (Execute Only) ---
    la t0, tor
    lw t1, 0(t0)                # EXPECTED: Load Access Fault (No Read permission)
    li t2, 5
    la t0, tor
    sw t2, 4(t0)               # EXPECTED: Store Access Fault (No Write permission)
    jal tor                    # EXPECTED: Success (Execute permission exists)

    # --- TEST: NAPOT REGION (Read Only) ---
    la t0, napot
    lw t1, 0(t0)               # EXPECTED: Success (Read permission exists)
    li t2, 5
    la t0, napot
    sw t2, 4(t0)               # EXPECTED: Store Access Fault (No Write permission)
    jal napot                   # EXPECTED: Instruction Access Fault (No Exec permission)

    #  machine mode
    ecall

    # Setting Lock bit (bit 7) for PMP entry 1(TOR) and entry 2(NAPOT)
    # This enforces PMP rules even in Machine Mode
    li t1, 0x8080       # 2 bytes each byte has lock bit set for pmp3cfg and pmp2cfg
    slli t1, t1, 8
    csrr t0, pmpcfg0
    or t0, t0, t1
    csrw pmpcfg0, t0
    
    # Repeat tests in Machine Mode (should now fault due to Lock bits)
    la t0, tor
    lw t1, 0(t0)               # read/load access exception
    li t2, 5
    la t0, tor
    sw t2, 4(t0)               # write/store access exception
    jal tor                      # execute access success

    # READ WRITE and EXECUTE from NAPOT REGION in Machine Mode after setting lock bit
    la t0, napot
    lw t1, 0(t0)               # read/load access Success
    li t2, 5
    la t0, napot
    sw t2, 4(t0)               # write/store access exception
    jal napot                      # execute access exception

    j write_tohost            
# function to switch in S-Mode
switch_mode:
    mv t6, ra                 
    csrr t0, mstatus         
    li t1, 1
    slli t1, t1, 11
    or t0, t0, t1
    csrw mepc , t6
    csrw mstatus, t0
    mret

/* Trap handler for ECALL from S-mode
    This handler will set MPP to 11 to switch to M-mode and return at address in mepc using mret
    which will cause the processor to switch to M-mode and jump to the instruction after ECALL in main */
s_trap_handler:

    csrr    t2, mepc          /* Skip the ECALL */
    addi    t2, t2, 4
    csrw    mepc, t2
    csrr    t0, mstatus       /* Read mstatus */
    srli    t3, t0, 11

    li      t1, (3 << 11)
    or      t0, t0, t1      
    csrw    mstatus, t0       /* Set MPP = 3 (Machine) */

    mret

trap_vector:                               
    csrr t0, mcause          
    li t2, 9                   /* ECALL from S-mode */
    li t3, 5                   /* Load Access Fault */
    li t4, 7                   /* Store Access Fault */
    li t5, 1                   /* instruction access fault */
    beq t0, t2, s_trap_handler     /*  jump to handle_ecall_s */
    beq t0, t3, read_handler       
    beq t0, t4, write_handler
    beq t0, t5, execute_handler

    j fail             

/* skip the faulty instruction */
read_handler:
    csrr    t2, mepc          
    addi    t2, t2, 4
    csrw    mepc, t2
    mret
/* skip the faulty instruction  */
write_handler:
    csrr    t2, mepc          
    addi    t2, t2, 4
    csrw    mepc, t2
    mret
/* return to caller while handling inst_access_fault */
execute_handler:
    csrw    mepc, ra
    mret

fail:
    la t1, base
    lw gp, 0(t1)
    la t0, tohost
    sw gp, 0(t0)              /* write to tohost 0xdeadbeef on failure*/
    j fail
  
write_tohost:
    li gp, 1
    la t0, tohost
    sw gp, 0(t0)              /* write to tohost 1 on success*/
    j write_tohost


RVTEST_DATA_BEGIN
base:
.word 0xcafebeef      
