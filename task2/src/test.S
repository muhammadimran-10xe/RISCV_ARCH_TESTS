#define RVTEST_DATA_BEGIN                                               \
        .pushsection .tohost,"aw",@progbits;                            \
        .align 6; .global tohost; tohost: .dword 0; .size tohost, 8;    \
        .align 6; .global fromhost; fromhost: .dword 0; .size fromhost, 8;\
        .popsection;  

#define RVTEST_CODE_BEGIN                                               \
        .section .text.init;                                            \
        .align  6;                                                      \
        .global _start;  

.section .tor_section
tor:
    nop
    ret

.section .napot_section
napot:
    .word 0x0

RVTEST_CODE_BEGIN                         
_start:                                 
    # la sp, _sstack           /* initialized the stack */
    la t6, trap_vector       /* trap handler runs in M-mode/No delegation is used */
    csrw mtvec, t6           /* set mtvec to point to trap_vector */
    jal pmp_config
    j main                   /* jump to main test code */
    
trap_vector:                               
    csrr t0, mcause            /* read mcause to determine the cause of the trap */
    li t1, 8                   /* ECALL from U-mode mcause = 8 */
    li t2, 9                   /* ECALL from S-mode mcause =  9 */
    li t3, 5                   /* Load Access Fault */
    li t4, 7                   /* Store Access Fault */
    li t5, 1                   /* instruction access fault */
    beq t0, t1, u_trap_handler     /* if ECALL from U-mode, jump to handle_ecall_u */
    beq t0, t2, s_trap_handler     /* if ECALL from S-mode, jump to handle_ecall_s */
    beq t0, t3, read_handler       
    beq t0, t4, write_handler
    beq t0, t5, execute_handler

    j fail             /* if trap cause is unexpected, jump to unknown_trap */
/* configure .text.init regions as NAPOT with execute permission */
pmp_config:
    # --- configure .text.init as NAPOT with RX ---
    la   t0, .text.init        # load base address of .text.init
    srli t0, t0, 2
    csrw pmpaddr0, t0          
/* initialli i have given all permission to this memory region 
    after switching to the supervisor mode when code tried to exit by wrting tohost
    it writes to .data section which is not configured so it give store access fault
    configured the region with NAPOT */
    li t0, 0x00                # MARK this region OFF
    csrw pmpcfg0, t0

    # TOR region with all permissions
    la t0, _end
    srli t0, t0, 2
    csrw pmpaddr1, t0

    li t1, 0x0f             #   pmp1cfg = 0b00001111
    slli t1, t1, 8
    csrr t0, pmpcfg0
    or t0, t0, t1
    csrw pmpcfg0, t0

    # --- configure TOR_SECTION as NAPOT with X ---
    la t0, _tor_end
    srli t0, t0, 2
    csrw pmpaddr2, t0

    li t1, 0x0c       #   pmp2cfg = 0b00001100
    slli t1, t1, 16
    csrr t0, pmpcfg0
    or t0, t0, t1
    csrw pmpcfg0, t0

    # # --- configure NAPOT_SECTION as NAPOT with R ---
    la t0, .napot_section
    li   t1, 0x1FF
    srli t0, t0, 2
    or   t0, t0, t1
    csrw pmpaddr3, t0  

    li t2, 0x19           # pmp3cfg = 0b00011001
    slli t2, t2, 24
    csrr t0, pmpcfg0
    or t0, t0, t2
    csrw pmpcfg0, t0

    # setting lock bit for TOR and NAPOT regions
    li t1, 0x8080                             # 2 bytes each byte has msb set
    slli t1, t1, 16
    csrr t0, pmpcfg0
    or t0, t0, t1
    csrw pmpcfg0, t0

    ret

main:
    .align 6
    li t0, 0
    jal switch_mode          # switched to supervisor mode

    # READ WRITE and EXECUTE from TOR REGION
    la t0, tor
    lw t1, 0(t0)               # read/load access exception
    li t2, 5
    la t0, tor
    sw t2, 4(t0)               # write/store access exception
    jal tor                      # execute access exception

    # READ WRITE and EXECUTE from NAPOT REGION
    la t0, napot
    lw t1, 0(t0)               # read/load access exception
    li t2, 5
    la t0, napot
    sw t2, 4(t0)               # write/store access exception
    jal napot                      # execute access exception

    # going beck to machine mode
    ecall

    #
    # jal tor                      # successfully jump and execute if not locked

    # READ WRITE and EXECUTE from TOR REGION
    la t0, tor
    lw t1, 0(t0)               # read/load access exception
    li t2, 5
    la t0, tor
    sw t2, 4(t0)               # write/store access exception
    jal tor                      # execute access exception

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
    # sb      t3, 1(t5)         /* Store previous privilege (MPP) */

    li      t1, (3 << 11)
    or      t0, t0, t1      
    csrw    mstatus, t0       /* Set MPP = 3 (Machine) */

    mret
/* skip the faulty instruction and write mcasue code to signature file */
read_handler:
    csrr    t2, mepc          /* Skip the ECALL */
    addi    t2, t2, 4
    csrw    mepc, t2
    mret
/* skip the faulty instruction and write mcasue code to signature file */
write_handler:
    csrr    t2, mepc          /* Skip the ECALL */
    addi    t2, t2, 4
    csrw    mepc, t2
    mret
/* skip the faulty instruction and write mcasue code to signature file */
execute_handler:
    # csrr    t2, mepc          /* Skip the ECALL */
    # addi    t2, t2, 4
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
