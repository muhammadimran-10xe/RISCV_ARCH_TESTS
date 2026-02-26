#define RVTEST_DATA_BEGIN                                               \
        .pushsection .tohost,"aw",@progbits;                            \
        .align 6; .global tohost; tohost: .dword 0; .size tohost, 8;    \
        .align 6; .global fromhost; fromhost: .dword 0; .size fromhost, 8;\
        .popsection;                                                    \
        .align 4; .global begin_signature; begin_signature:
#define RVTEST_CODE_BEGIN                                               \
        .section .text.init;                                            \
        .align  6;                                                      \
        .global _start;   

RVTEST_CODE_BEGIN                 
_start:                                 
        la t0, trap_vector
        csrw mtvec, t0
        j main 

trap_vector:                                                            
    csrr t0, mcause                       
    li t3, 5                  # Load Access Fault
    li t4, 7                  # Store Access Fault
    li t5, 1                  # Instruction Access Fault
    beq t0, t3, load_handler       
    beq t0, t4, store_handler
    beq t0, t5, inst_access_fault        
    j fail

RVTEST_CODE_BEGIN
# start in Machine mode
main:
    .align 6
    # Setting msecceg.MML at the start will cause inst_access_fault
    # because it is a sticky bit once set can not be cleared untill reset, and
    # later pmp entries will be ignored. since at the start no pmp entry is configured
    # after setting mseccfg.MML it does not match any pmp entry and will instantly give
    # inst_access_fault

    # csrwi mseccfg, 1         # do not set mseccfg.MML here

    # enable mseccfg.RLB so that we can modify the PMP entry
    # because initially when mseccfg.MML is not set and we configure the PMP entry 
    # with pmpcfg.L = 1, it will lock the entry for both machine and s/u modes
    # even machine mode can not modify it.

    # Solution of above probelem is RLB (Rule Locking Bypass) bit in mseccfg (bit 2). 
    # RLB allows the modification of locked entries or the creation of 
    # executable rules even when MML is active.
    # 
    li t0, 0x4
    csrw mseccfg, t0

    # Configure a Locked TOR PMP region (Entry 0)
    la t0, _end           
    srli t0, t0, 2
    csrw pmpaddr0, t0

    # adding rule for M-mode-only with executable privileges 
    # Config: 0x8C = 1000 1100 (L=1, A=01 (TOR), X=1, W=0, R=0)
    li t0, 0x8C
    csrw pmpcfg0, t0

    csrwi mseccfg, 1            # set msecfg.MML here after configuring the PMP

    nop                         # Expected: Successfull Execution
    nop                         # Expected: Successfull Execution
    la t0, main
    lw t1, 0(t0)                # Expected: load_access_fault
    li t2, 0x8
    la t0, main
    sw t2, 0(t0)                # Expected: store_access_fault
    nop
    j write_tohost

/* skip the faulty instruction */
load_handler:
    csrr    t2, mepc          
    addi    t2, t2, 4
    csrw    mepc, t2
    mret
/* skip the faulty instruction  */
store_handler:
    csrr    t2, mepc          
    addi    t2, t2, 4
    csrw    mepc, t2
    mret
/* return to caller while handling inst_access_fault */
inst_access_fault:
    csrw    mepc, ra
    mret

fail:
    la t1, base
    lw gp, 0(t1)
    la t0, tohost
    sw gp, 0(t0)              /* write to tohost 0xcafebeef on failure*/
    j fail

.align 2    
write_tohost:
    li gp, 1
    sw gp, tohost, t5
    j write_tohost

.data
base:
.word 0xcafebeef
RVTEST_DATA_BEGIN
