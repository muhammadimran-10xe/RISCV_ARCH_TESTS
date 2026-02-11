#define RVTEST_DATA_BEGIN                                               \
        .pushsection .tohost,"aw",@progbits;                            \
        .align 6; .global tohost; tohost: .dword 0; .size tohost, 8;    \
        .align 6; .global fromhost; fromhost: .dword 0; .size fromhost, 8;\
        .popsection;                                       
#define RVTEST_CODE_BEGIN                                               \
        .section .text.init;                                            \
        .align  6;                                                      \
        .global _start;  
.section tor_section
.align 12
TOR_SECTION_START:
    nop
TOR_SECTION_END:
.section .napot_section
.align 12
NAPOT_SECTION:
    .word 0x12345678
RVTEST_CODE_BEGIN                         
_start:                                 
    # la sp, _sstack           /* initialized the stack */
    la t6, trap_vector       /* trap handler runs in M-mode/No delegation is used */
    csrw mtvec, t6           /* set mtvec to point to trap_vector */
    la t5, begin_signature     /* load address of signature region base to t5, trap handlers will use t5 to write test results */
    jal pmp_config
    j main                   /* jump to main test code */
    
trap_vector:                               
    csrr t0, mcause            /* read mcause to determine the cause of the trap */
    slli t0, t0, 1       
    srli t0, t0, 1             /* shift left and right to discard the MSB(interrupt) bit */
    li t1, 8                   /* ECALL from U-mode mcause = 8 */
    li t2, 9                   /* ECALL from S-mode mcause =  9 */
    beq t0, t1, u_trap_handler     /* if ECALL from U-mode, jump to handle_ecall_u */
    beq t0, t2, s_trap_handler     /* if ECALL from S-mode, jump to handle_ecall_s */

    j fail             /* if trap cause is unexpected, jump to unknown_trap */
/* configure .text.init regions as NAPOT with execute permission */
pmp_config:
    # --- configure .text.init as NAPOT with RX ---
    la   t0, .text.init        # load base address of .text.init
    li   t1, 0xFFF
    srli t0, t0, 2
    or   t0, t0, t1
    csrw pmpaddr0, t0          

    la t2, pmpcfg_byte
    lb t2, 0(t2)
    li t0, 0x1f                # given all permission otherwise writing to .data section cause store access fault
    or t0, t2, t0

    csrw pmpcfg0, t0
    # --- configure TOR_SECTION as NAPOT with X ---
    la t0, TOR_SECTION_END
    srli t0, t0, 2
    csrw pmpaddr1, t0

    la t2, pmpcfg_byte
    lb t2, 0(t2)
    li t0, 0x0c                # given all permission otherwise writing to .data section cause store access fault
    or t0, t2, t0
    slli t0, t0, 8
    csrr t2, pmpcfg0
    or t2, t2, t0
    csrw pmpcfg0, t2
    # --- configure NAPOT_SECTION as NAPOT with R ---
    la t0, NAPOT_SECTION
    li   t1, 0xFFF
    srli t0, t0, 2
    or   t0, t0, t1
    csrw pmpaddr2, t0  

    li t2, 0x19
    slli t2, t2, 8
    csrw pmpcfg0, t2

    ret

main:
    .align 6
    li t0, 0
    jal switch_mode
    li t1, 5
    # la t0, TOR_SECTION_START
    # jalr t0

    j write_tohost            

switch_mode:
    mv t6, ra                  /* save return address in t6 */
    csrr t0, mstatus         
    li t1, 3                /* mask = 0b11 */
    slli t1, t1, 11         /* shift to bits 11:12 */
    not t1, t1              /* invert to create clear mask */
    and t0, t0, t1          /* clear MPP bits */
    li t3, 1                
    beq a0, zero, 1f           /* switch to S-mode */
    beq a0, t3, 2f             /* switch to U-mode */
    j fail                     /* if a0 is not 0 or 1, jump to unknown_trap */

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
/*
switch_to_u_mode:
    csrr t0, sstatus
    li t1, ~(1 << 8)
    and t0, t0, t1
    csrw sstatus, t0
    la t2, u_mode_code
    csrw sepc, t2
    sret
    */
/* Trap handler for ECALL from U-mode
    This handler will set MPP to 01 to switch to S-mode and return using mret
    which will cause the processor to switch to S-mode and jump to the instruction after ECALL in main */
u_trap_handler:

    csrr    t2, mepc
    addi    t2, t2, 4          /* Skip the ECALL */
    csrw    mepc, t2
    csrr    t0, mstatus        /* Read mstatus */
    srli    t3, t0, 11
    andi    t3, t3, 3
    sb      t3, 2(t5)          /* Store previous privilege (MPP) */
    li      t1, ~(3 << 11)
    and     t0, t0, t1         /* Clear MPP bits */

    li      t1, (1 << 11)      /* Set MPP = 01 (S-mode) */
    or      t0, t0, t1
    csrw    mstatus, t0

    mret
/* Trap handler for ECALL from S-mode
    This handler will set MPP to 11 to switch to M-mode and return using mret
    which will cause the processor to switch to M-mode and jump to the instruction after ECALL in main */
s_trap_handler:

    csrr    t2, mepc          /* Skip the ECALL */
    addi    t2, t2, 4
    csrw    mepc, t2
    csrr    t0, mstatus       /* Read mstatus */
    srli    t3, t0, 11
    andi    t3, t3, 3
    sb      t3, 1(t5)         /* Store previous privilege (MPP) */

    li      t1, (3 << 11)
    or      t0, t0, t1      
    csrw    mstatus, t0       /* Set MPP = 3 (Machine) */

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
.align 4; .global begin_signature; 
begin_signature:
    .fill 4, 1, 0  
end_signature:
base:
.word 0xcafebeef
pmpcfg_byte:
.byte 0
