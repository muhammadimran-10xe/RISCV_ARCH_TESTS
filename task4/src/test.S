#define RVTEST_DATA_BEGIN                                               \
        .pushsection .tohost,"aw",@progbits;                            \
        .align 6; .global tohost; tohost: .dword 0; .size tohost, 8;    \
        .align 6; .global fromhost; fromhost: .dword 0; .size fromhost, 8;\
        .popsection;                                                    \

#define RVTEST_CODE_BEGIN                                               \
        .section .text.init;                                            \
        .align  6;                                                      \
        .global _start;                         
_start:                                 
        la t0, trap_vector
        csrw mtvec, t0
        la t4, begin_signature
        j main;                             
trap_vector:                                                            
    csrr t5, mcause ;  
    li t0, 2
    beq t0, t5, illigal_inst_handler                     
                            
    j fail

RVTEST_CODE_BEGIN
main:
    .align 6
    # when FS is OFF
    fmv.w.x f0, x0           # this must raise and exception and recorded in signature file

    # set FS= Initial
    li t0, (1 << 13)     # FS=Initial (01)
    csrs mstatus, t0
    csrr t1, mstatus
    srli t2, t1, 31     
    bnez t2, fail        # SD should be 0 in initial

    # set FS=CLEAN 
    csrr t1, mstatus       # read mstatus
    li t0, 0x6000          # mask for FS bits (14:13) → 0b11 << 13
    not t0, t0
    and t1, t1, t0         # clear FS bits (without clearing it was reading wrong value)
    li t0, (2 << 13)       # FS=10
    or t1, t1, t0
    csrw mstatus, t1       # write back
    csrr t2, mstatus
    srli t2, t2, 31     
    bnez t2, fail        # SD should be 0 in CLEAN

    # make FS=DIRTY by writing to fp registers
    fmv.w.x f1, x0       
    csrr t1, mstatus
    srli t2, t1, 31      # SD bit
    beqz t2, fail        # SD must be 1

    srli t3, t1, 13
    andi t3, t3, 0x3     # FS[1:0]
    li t4, 3
    bne t3, t4, fail     # FS must be 11 (Dirty)
    j write_tohost
/* illegal instruction trap handler */
illigal_inst_handler:
    csrr t1, mepc
    addi t1, t1, 4         # skip faulty instruction
    csrw mepc, t1
    lb t2, 0(t4)
    addi t2, t2, 1         # record the trap
    sw t2, 0(t4)
    mret

fail:
    la t1, base
    lw gp, 0(t1)
    la t0, tohost
    sw gp, 0(t0)              /* write to tohost 0xdeadbeef on failure*/
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
.align 4; .global begin_signature; begin_signature:
begin_signature:
.fill 1, 1, 0  
end_signature: