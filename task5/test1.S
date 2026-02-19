#define RVTEST_DATA_BEGIN                                               \
        .pushsection .tohost,"aw",@progbits;                            \
        .align 6; .global tohost; tohost: .dword 0; .size tohost, 8;    \
        .align 6; .global fromhost; fromhost: .dword 0; .size fromhost, 8;\
        .popsection;  

#define RVTEST_CODE_BEGIN                                               \
        .section .text.init;                                            \
        .align  6;                                                      \
        .global _start;  

.section .root_pt;
.align 12
.global root; 
root: .space 4096

.section .leaf_pt;
.align 12
.global leaf; 
leaf: .space 4096

.section .test, "aw", @progbits;    # page with RWX permissions
.align 12
test: 
    li t0, 5
    ret

RVTEST_CODE_BEGIN                         
_start:                                 
    la t6, trap_vector       /* trap handler runs in M-mode/No delegation is used */
    csrw mtvec, t6           /* set mtvec to point to trap_vector */

    j main                   /* jump to main test code */
    
trap_vector:                               
    csrr t0, mcause            /* read mcause to determine the cause of the trap */
    li t1, 8                   /* ECALL from U-mode mcause = 8 */
    li t2, 9                   /* ECALL from S-mode mcause =  9 */
    li t3, 13                   /* Load Page Fault */
    li t4, 15                   /* Store page Fault */
    li t6, 12                  /* instruction page fault */
    beq t0, t1, u_trap_handler     /* if ECALL from U-mode, jump to handle_ecall_u */
    beq t0, t2, s_trap_handler     /* if ECALL from S-mode, jump to handle_ecall_s */
    beq t0, t6, inst_page_fault_handler
    beq t0, t3, load_page_fault_handler
    beq t0, t4, store_page_fault_handler

    j fail             
/* a0 = VA, a1 = PA, a2 = permissions, a3 = 0(leaf)/1(root) */ 
pte_setup:
    srli t0, a0, 12          # discard page offset from VA
    andi t1, t0, 0x3ff       # extract VA[0]
    srli t2, t0, 10          # extract VA[1]

    srli t0, a1, 12          # extract PPN
    slli t0, t0, 10          # make space form permissions
    or t0, t0, a2            # add permissions
    ori t0, t0, 1            # make it valid

    beqz a3, _leaf
    la   t3, root        # use symbol, not section name
    slli t2, t2, 2       # index * 4
    add  t3, t3, t2
    sw   t0, 0(t3)            # write to root PT
    ret
_leaf:
    la   t4, leaf
    slli t1, t1, 2
    add  t4, t4, t1
    sw   t0, 0(t4)
    ret                      # write to leaf PT

main:
    .align 6
    la   a0, test              # any VA in this region
    la   a1, leaf
    li   a2, 0                       # no RWX for pointer
    li   a3, 1                       # root level
    jal  pte_setup

    la a0, test
    la a1, test
    li a2, 0xce                #  setting A, D and  RWX permissions
    li a3, 0
    jal pte_setup

    la a0, .text.init
    la a1, .text.init
    li a2, 0xce                #  setting A, D and  RWX permissions
    li a3, 0
    jal pte_setup

    la a0, root
    la a1, root
    li a2, 0xce
    li a3, 0
    jal pte_setup

    la a0, leaf
    la a1, leaf
    li a2, 0xce
    li a3, 0
    jal pte_setup

    la t0, root
    srli t0, t0, 12
    li t1, (1 << 31)
    or t0, t0, t1
    csrw satp, t0
    sfence.vma                  # Flush TLB caches

    li a0, 0
    jal switch_mode
    jal test

    la a0, test
    la a1, test
    li a2, 0xc0                #  setting A, D and  RWX permissions
    li a3, 0
    jal pte_setup

    jal test
load_inst:
    la t0, test
    lw t1, 0(t0)
store_inst:
    li t1, 0x3
    not t2, t1
    and t0, t0, t2
    sw t1, 32(t0)
exit:
    ecall                      # exit in M-mode
    j write_tohost            

switch_mode:
    mv t6, ra                 
    csrr t0, mstatus         
    li t1, 3                
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
    csrr    t2, mepc          
    addi    t2, t2, 4
    csrw    mepc, t2
    mret
/* skip the faulty instruction and write mcasue code to signature file */
write_handler:
    csrr    t2, mepc          
    addi    t2, t2, 4
    csrw    mepc, t2
    mret
/* skip the faulty instruction and write mcasue code to signature file */
execute_handler:
    csrr    t2, mepc          
    addi    t2, t2, 4
    csrw    mepc, t2
    mret
inst_page_fault_handler:
    la t2, load_inst
    csrw    mepc, t2
    mret
load_page_fault_handler:
    la t2, store_inst
    csrw    mepc, t2
    mret
store_page_fault_handler:
    la t2, exit
    csrw    mepc, t2
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
