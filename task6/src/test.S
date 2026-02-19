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
main:
    .align 6
    #Normally, a locked PMP entry (L=1) cannot be changed. However, 
    # the Smepmp extension introduces the mseccfg.RLB (Rule Locking Bypass). 
    # When RLB=1, the lock bit is ignored, allowing the configuration of 
    # locked entries to be modified without a reset.


    # Configure mseccfg.RLB bit (bit 2) 
    # This enables "Rule Lock Bypass" so we can modify "locked" entries later.
    li t0, 0x4
    csrw mseccfg, t0

    # Configure a Locked NAPOT PMP region (Entry 0)
    # Range: 4KB based on 0x1ff (9 trailing ones)
    la t0, pmpnapot           
    srli t0, t0, 2
    ori t0, t0, 0x1ff      # Encode size=4KB into pmpaddr (9 one's)
    csrw pmpaddr0, t0

    # Config: 0x9f = 1001 1111 (L=1, A=11 (NAPOT), X=1, W=1, R=1)
    # This locks the region with RWX permissions.
    li t0, 0x9f
    csrw pmpcfg0, t0

    # =====================================================================
    # QUESTION 1: What two things happen when you configure a locked pmp region?
    # ANSWER: 
    # 1. PMP rules are now strictly enforced even for 
    #    Machine Mode (normally M-mode has full access to all memory).
    # 2. The pmpcfg and associated pmpaddr registers become 
    #    read-only. They cannot be modified until a system reset.
    # =====================================================================

    # Test Execute, Read, and Write in the locked region
    jal pmpnapot

    # Modify the LOCKED PMP entry
    /* if we set the mseccfg.RLB bit later/here after configuring the locked PMP region 
    then any modification of configuration of mseccfg.RLB will be ignored,
    this is why we configure the mseccfg.RLB before the PMP config
    */
    # Because RLB=1, we can change 0x9f (RWX) to 0x99 (Read-only).
    # config byte ==> 0x99 = 1001 1001 (L=1, A=11 (NAPOT), X=0, W=0, R=1)
    li t0, 0x99          
    csrw pmpcfg0, t0
    # Test Execute Permissions: (X=0)
    jal pmpnapot               # Expected: inst_access_fault (X=0)
    # Test Load/Read Permissions: (R=1)
    la t0, pmpnapot
    lw t1, 0(t0)               # Expected: Load Successfull 
    # Test Store permission: will trigger store_handler (W=0)
    li t2, 0xaaaaa
    sw t2, 0(t0)               # Expected: store_access_fault
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

# locked pmpnapot region
.text
.align 12
pmpnapot:
    li t0, 0x12345678
    li t1, 0x555
    la t2, pmpnapot
    sw t1, 0(t2)
    lw t3, 0(t2)
    ret

.data
base:
.word 0xcafebeef
RVTEST_DATA_BEGIN
