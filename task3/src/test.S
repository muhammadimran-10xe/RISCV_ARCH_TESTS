#include "macro.S"

#define RVTEST_DATA_BEGIN                                               \
        .pushsection .tohost,"aw",@progbits;                            \
        .align 6; .global tohost; tohost: .dword 0; .size tohost, 8;    \
        .align 6; .global fromhost; fromhost: .dword 0; .size fromhost, 8;\
        .popsection;                                       
#define RVTEST_CODE_BEGIN                                               \
        .section .text.init;                                            \
        .align  6;                                                      \
        .global _start;  
RVTEST_CODE_BEGIN                         
_start:                                 
    la sp, _sstack           /* initialized the stack */
    jal trap_setup
    la t6, m_trap_vector       /* trap handler runs in M-mode/No delegation is used */
    csrw mtvec, t6           /* set mtvec to point to trap_vector */
    la t6, s_mode_handler
    csrw stvec, t6
    la t5, begin_signature     /* load address of signature region base to t5, trap handlers will use t5 to write test results */
    j main                   /* jump to main test code */
m_trap_vector: 
    SAVE_REGS                  /* save all registers context */                                         
    csrr t0, mcause            /* read mcause to determine the cause of the trap */
    slli t0, t0, 1       
    srli t0, t0, 1             /* shift left and right to discard the MSB(interrupt) bit */
    li t1, 8                   /* ECALL from U-mode mcause = 8 */
    li t2, 9                   /* ECALL from S-mode mcause =  9 */
    beq t0, t1, u_trap_handler     /* if ECALL from U-mode, jump to handle_ecall_u */
    beq t0, t2, s_trap_handler     /* if ECALL from S-mode, jump to handle_ecall_s */

    j unknown_trap             /* if trap cause is unexpected, jump to unknown_trap */
s_mode_handler:
    # SAVE_REGS
    csrr t0, scause
    slli t0, t0, 1            /* discard the MSB interrupt bit */
    srli t0, t0, 1
    sb t0, 4(t5)              /* record scause in signature file */
    csrr t1, sepc
    addi t1, t1, 4            /* skip the illegal instruction */
    csrw sepc, t1
    # RESTORE_REGS
    sret

trap_setup:
    li t0, 4                /* medeleg[2] = 1 for illegal instruction delegation */
    csrrs zero, medeleg, t0
    ret
main:
    .align 6
    # switch to U mode
    li a0, 1
    jal switch_mode
    .word 0xffffffff
    ecall
    ecall

    j write_tohost            


verify_u_mode:
    csrr t0, mstatus        /* this will trap */
    ret

/* this label is only succesfully execute in S-Mode otherwise it will trap or fail*/
verify_s_mode:
    csrr t0, mstatus        /* this will trap */
    ret
/* this label is only succesfully execute in M-Mode otherwise it will trap*/
verify_m_mode:
    csrr t0, mstatus        /* read mstatus */
    li t1, 3                /* expected mode value for M-mode is 3 */
    sb t1, 0(t5)               /* store expected mode value at the beginning of signature region */
    ret
u_mode_switch:
    mv t1, ra                  /* save return address in t1 */
    csrw sepc, t1           /* set sepc to return to the instruction after ecall in case of trap */
    csrr t0, sstatus        /* read sstatus to check if we are in S-mode */
    li t2, 0                /* mask for SPP bit (bit 8) */
    slli t2, t2, 8          /* shift to bit 8 */
    and t0, t0, t2          /* check if SPP bit is 0, which indicates we are in S-mode */
    csrw sstatus, t0          /* write back sstatus to clear any side effects */
    sret                     /* return from trap, should switch to U-mode and jump to the instruction after ecall in main */

/* switch_mode: set MPP bits in mstatus and set mepc 
    to desired mode address and jumps to that mode using mret*/
switch_mode:
    mv t6, ra                  /* save return address in t6 */
    csrr t0, mstatus        /* read mstatus */
    li t1, 0x3              /* mask for MPP bits (bits 11 and 12) */
    slli t1, t1, 11         /* shift to correct position */
    not t1, t1
    and t0, t0, t1          /* clear MPP  */
    li t3, 1                /* use t3 instead of t5 to avoid corrupting signature base address */
    beq a0, zero, 1f        /* if a0 == 0, switch to S-mode, else switch to U-mode */
    beq a0, t3, 2f
    j fail             /* if a0 is not 0 or 1, jump to unknown_trap */


/* this label write MPP bits to 01 to switch to S-mode
    set mepc to next instruction after switch_mode and return from trap */
1:
    li t1, 1
    slli t1, t1, 11
    or t0, t0, t1
    csrw mepc , t6
    csrw mstatus, t0
    mret
2:
    csrw mepc , t6
    csrw mstatus, t0
    mret

/* Trap handler for ECALL from U-mode
    This handler will set MPP to 01 to switch to S-mode and return using mret
    which will cause the processor to switch to S-mode and jump to the instruction after ECALL in main */
u_trap_handler:
    csrr t2, mepc        /* read mepc to get the address of the instruction that caused the trap */
    addi t2, t2, 4       /* increment mepc to point to the next instruction after ECALL */
    csrw mepc, t2
    csrr t0, mstatus    
    li t1, 3                /* mask = 0b11 */
    slli t1, t1, 11         /* shift to bits 11:12 */
    not t1, t1              /* invert to create clear mask */
    and t0, t0, t1          /* clear MPP bits */
    
    li t1, 1                /* MPP value = 01 */
    slli t1, t1, 11         /* shift to bits 11:12 */
    or t0, t0, t1           /* set MPP bits */
    csrw mstatus, t0
    RESTORE_REGS            /* restore the context */
    mret                   /* mret is used to return from trap and will switch to the mode specified in MPP */
/* Trap handler for ECALL from S-mode
    This handler will set MPP to 11 to switch to M-mode and return using mret
    which will cause the processor to switch to M-mode and jump to the instruction after ECALL in main */
s_trap_handler:
    csrr t2, mepc        /* read mepc to get the address of the instruction that caused the trap */
    addi t2, t2, 4       /* increment mepc to point to the next instruction after ECALL */
    csrw mepc, t2
    csrr t0, mstatus
    li t1, 3                /* mask = 0b11 */
    slli t1, t1, 11         /* shift to bits 11:12 */
    not t1, t1              /* invert to create clear mask */
    and t0, t0, t1          /* clear MPP bits */

    li t1, 3                /* MPP value = 11 */
    slli t1, t1, 11         /* shift to bits 11:12 */
    or t0, t0, t1           /* set MPP bits */
    csrw mstatus, t0
    RESTORE_REGS
    mret

unknown_trap:
    lw t0, 10*4(sp)            /* load the value of a0 which is the argument passed to main, this will indicate which mode we were trying to switch to when the unexpected trap occurred */
    li t1, 3
    blt t1, t0, fail            /* if a0 < 3, it means the trap occurred while trying to switch modes, jump to fail */
    csrr t2, mepc        /* read mepc to get the address of the instruction that caused the trap */
    addi t2, t2, 4       /* increment mepc to point to the next instruction after the one that caused the trap */
    csrw mepc, t2
    csrr t0, mstatus        /* read mstatus to indicate the cause of the unexpected trap */
    srli t0, t0, 11         /* shift to bits 11:12 */
    li t1, 3
    and t1, t0, t1          /* mask mstatus to only get the relevant bits for mstatus */
    beqz t1, U              /* if mstatus is 0, it means we are in M-mode, jump to fail */
    li t3, 1
    beq t1, t3, S
U:
    sb t0, 2(t5)             /* store the previous mode from which trap has occured */
    RESTORE_REGS
    mret                     /* return from trap, should return to the instruction after the one that caused the trap */
S:
    sb t0, 1(t5)             /* store the previous mode from which trap has occured */
    RESTORE_REGS
    mret                     /* return from trap, should return to the instruction after the one that caused the trap */
fail:
    lb t0, 3(t5)             /* load a non-zero value to indicate unknown trap */
    addi t0, t0, 0xff
    sb t0, 3(t5)              /* store the value to signature region to */

write_tohost:
    li gp, 1
    la t0, tohost
    sw gp, 0(t0)              /* write to tohost to finish the test and exit */
    j write_tohost


RVTEST_DATA_BEGIN
.align 4; .global begin_signature; 
begin_signature:
    .fill 5, 1, 0  
end_signature:

