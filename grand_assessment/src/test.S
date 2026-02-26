/*
 * test.S - RISC-V Hypervisor Extension Test
 *
 * Task: Two-Stage Address Translation and Guest Memory Access
 *
 * This test implements a full privilege transition:
 *   M-mode → HS-mode (Hypervisor Supervisor) → VS-mode (Virtual Supervisor) → VU-mode (Virtual User)
 * and exercises the RISC-V Hypervisor Extension (H-extension) features:
 *   - Two-stage address translation via vsatp (VS-stage) + hgatp (G-stage)
 *   - HLV.WU / HSV.W instructions for hypervisor-mode guest memory access
 *   - Trap delegation using medeleg and hedeleg
 *
 * Privilege levels:
 *   3 = M-mode  (Machine)
 *   1 = HS-mode (Hypervisor Supervisor / Host Supervisor)
 *   0 = VU-mode (Virtual User) or VS-mode (Virtual Supervisor, shown as 1 w/ V=1)
 *
 * Mode transition sequence:
 *   M → HS → VS → VU → (ecall) → HS → VS → (ecall) → HS → (ecall) → M → done
 */
#define RVTEST_DATA_BEGIN                                               \
        .pushsection .tohost,"aw",@progbits;                            \
        .align 6; .global tohost; tohost: .dword 0; .size tohost, 8;    \
        .align 6; .global fromhost; fromhost: .dword 0; .size fromhost, 8;\
        .popsection;  

#define RVTEST_CODE_BEGIN                                               \
        .section .text.init;                                            \
        .align  6;                                                      \
        .global _start;  


/* ========================================================================
 * ENTRY POINT: _start (executes in M-mode, privilege level 3)
 * ======================================================================== */
RVTEST_CODE_BEGIN                         
_start:        
    /* ----------------------------------------------------------------
     * Setup M-mode trap vector
     * mtvec holds the address of m_trap_vector, which handles M-mode
     * exceptions (specifically the HS-mode ecall that signals test end).
     * ---------------------------------------------------------------- */
    la t6, m_trap_vector       /* load address of M-mode trap handler */
    csrw mtvec, t6             /* write to Machine Trap-Vector Base-Address CSR */

    /* ----------------------------------------------------------------
     * sets medeleg for exception delegation
     * write 0xb500 to medeleg, delegating:
     *   bit  8: Environment call from U-mode (VU-mode ecall → HS)
     *   bit 10: Environment call from VS-mode (VS ecall → HS)
     *   bit 12: Instruction page fault
     *   bit 13: Load page fault
     *   bit 15: Store page fault
     * ---------------------------------------------------------------- */
    li t0, 0xb500           
    csrw medeleg, t0

    /* ----------------------------------------------------------------
     * Initialize hgatp for G-stage (Guest Physical → Host Physical)
     * address translation.
     * hgatp is the Hypervisor Guest Address Translation and Protection CSR.
     * Format: MODE[63:60] | VMID[57:44] | PPN[43:0]
     *   MODE = 8 → Sv39x4 (39-bit guest-physical with 4x root table size)
     *   PPN  = Root_Page_Table_H >> 12
     * The root table for G-stage is the Host's root page table.
     * ---------------------------------------------------------------- */
    la t0, Root_Page_Table_H   /* physical address of host root page table */
    srli t0, t0, 12            /* convert to Page Frame Number (PPN = PA >> 12) */
    li   t1, (8 << 60)         /* MODE=8 selects Sv39x4 two-stage translation */
    or   t0, t0, t1            /* combine MODE and PPN fields */
    csrw hgatp, t0             /* program G-stage page table root */
    hfence.gvma                /* flush all G-stage TLB entries globally */

    /* ----------------------------------------------------------------
     * Step 4: Jump to main for page table setup before switching to HS-mode
     * ---------------------------------------------------------------- */
    j main
    

/* ========================================================================
 * M-MODE TRAP HANDLER: m_trap_vector
 * Handles the HS-mode ecall at the end of the test.
 * Expected cause: mcause = 9 (Environment call from S-mode / HS-mode ecall)
 * Action: skip the ecall instruction (mepc += 4), then mret back to HS
 * ======================================================================== */
m_trap_vector:                               
    csrr t0, mcause            /* read Machine Cause Register */
    li t1, 9                   /* cause code 9 = ecall from S-mode (HS-mode ecall) */
    bne t0, t1, fail           /* if not a HS ecall, test has failed */
    csrr t2, mepc              /* read faulting instruction address */
    addi t2, t2, 4             /* advance past the ecall instruction */
    csrw mepc, t2              /* write updated return address */
    mret                       /* return to HS-mode (continues at hs_mode_exit+4 → write_tohost) */


/* ========================================================================
 * HS-MODE TRAP HANDLER: hs_trap_vector
 * Handles two different ecall types from guests:
 *   scause = 8  → VU-mode ecall: read/modify/write guest memory via HLV/HSV
 *   scause = 10 → VS-mode ecall: test is complete, exit to M-mode
 * ======================================================================== */
hs_trap_vector:
    csrr t0, scause            /* read Supervisor Cause Register (reflects guest cause) */
    li t1, 8                   /* cause code 8 = ecall from U-mode (VU-mode) */
    li t2, 10                  /* cause code 10 = ecall from VS-mode */
    beq t0, t2, hs_mode_exit   /* if VS ecall (cause=10), branch to exit path */
    bne t0, t1, fail           /* if neither 8 nor 10, something went wrong → fail */

    /* ----------------------------------------------------------------
     * Handle VU-mode ecall (scause = 8):
     * The VU-mode application passed the guest memory address in a0.
     * Check a1 command code to determine what is the purpose of VU-mode ecall.
     * We use HLV.WU to read from it (through two-stage translation),
     * add 0x100, then use HSV.W to write the modified value back.
     * ---------------------------------------------------------------- 
     * Set hstatus.SPVP = 1 (bit 8) so HLV/HSV use Supervisor privilege
     * for the virtual address translation of the guest access.
     * SPVP controls the effective privilege used for HLV/HSV instructions:
     *   0 = User privilege, 1 = Supervisor privilege
     * We OR bit 8 into hstatus to set SPVP=1. */
    li t1, 0x100              /* SPVP is bit 8 of hstatus */
    csrr t2, hstatus           /* read current hstatus */
    or t1, t1, t2             /* set SPVP bit */
    csrw hstatus, t1          /* write updated hstatus */

    li  t3, 1
    li t4, 2
    beq a1, t3, mem_access
    beq a1, t4, fetch_vs_inst
    j fail

fetch_vs_inst:
    hlvx.wu t2, (a0)
    csrr t0, sepc
    addi t0, t0, 4
    csrw sepc, t0
    sret

mem_access:
    /* command code a1 = 1 
    /* HLV.WU: Hypervisor Load Word Unsigned
     * Reads a 32-bit unsigned word from guest virtual address in a0.
     * Translation proceeds through VS-stage (vsatp) then G-stage (hgatp),
     * i.e., the full two-stage walk: GVA → GPA → HPA.
     * Result in t2 = 0xDEADBEEF (zero-extended, no sign extension). */
    hlv.wu t2, (a0)           /* t2 = Guest[a0] unsigned; a0 = 0x80004088 */

    /* Modify: add 0x100 to the value
     * 0xDEADBEEF + 0x100 = 0xDEADBFEF */
    li t3, 0x100
    add t2, t2, t3            /* compute modified value */

    /* HSV.W: Hypervisor Store Word
     * Writes the 32-bit value in t2 back to guest virtual address a0.
     * Translation again uses two-stage walk (vsatp + hgatp). */
    hsv.w t2, (a0)            /* Guest[a0] = 0xDEADBFEF */

    /* Redirect sret to vs_verify instead of returning to the ecall site.
     * vs_verify is the VS-mode code that confirms the modified value. */
    la t0, vs_verify           /* address of VS-mode verification code */
    csrw sepc, t0             /* set supervisor exception program counter */

    /* Configure return to VS-mode:
     *   sstatus.SPP = 1 → return to S-mode (which is VS-mode due to hstatus.SPV=1)
     *   hstatus.SPV = 1 → virtualization is active after sret (return to VS, not HS) */
    li t0, 0x100
    csrs sstatus, t0           /* set SPP=1 (return to supervisor mode) */
    li t0, 0x80
    csrs hstatus, t0           /* set SPV=1 (supervisor mode means VS-mode) */

    sret                       /* return to VS-mode at vs_verify */


/* ========================================================================
 * MAIN: Page Table Setup + Switch to HS-mode
 * Sets up three-level Sv39 page tables for both Host (HS-mode) and
 * Guest (VS-mode) address spaces, then performs M → HS transition.
 * ======================================================================== */
main:
    .align 6   

    /* ---- Host (H-extension G-stage) Page Table Setup ----
     * The host page tables map physical addresses used by vs_mode and vu_mode
     * into the guest-physical address space seen by the guest.
     *
     * pte_setup(a0=VA, a1=PA_target, a2=perm_bits, a3=level, a4=is_guest)
     *   a3=2 → write at root (L2) page table
     *   a3=1 → write at level-1 page table
     *   a3=0 → write at level-0 (leaf) page table
     *   a4=0 → use Host page tables (Root/L1/L0_Page_Table_H)
     *   a4=1 → use Guest page tables (Root/L1/L0_Page_Table_G)
     */

    /* Host L2 (root) PTE: maps vs_mode GVA → Level_one_Page_Table_H */
    la a0, vs_mode             /* virtual address to map */
    la a1, Level_one_Page_Table_H  /* next-level page table PA */
    li a2, 0x00               /* no leaf permissions (non-leaf PTE) */
    li a3, 2                  /* write into L2 (root) page table */
    li a4, 0                  /* Host page table (a4=0) */
    jal pte_setup

    /* Host L1 PTE: maps vs_mode GVA → Level_zero_Page_Table_H */
    la a0, vs_mode
    la a1, Level_zero_Page_Table_H
    li a2, 0x00               /* non-leaf */
    li a3, 1                  /* write into L1 page table */
    li a4, 0                  /* Host page table */
    jal pte_setup

    /* Host L0 (leaf) PTE: maps vs_mode GVA → vs_mode PA (identity-ish)
     * Permission bits 0xde = 0b11011110:
     *   D=1 (dirty), A=1 (accessed), G=0, U=1 (user), X=1 (execute),
     *   W=1 (write), R=1 (read), V=1 (valid, added by pte_setup) */
    la a0, vs_mode
    la a1, vs_mode            /* map VA → same PA */
    li a2, 0xde              /* RWX+User+Accessed+Dirty leaf PTE */
    li a3, 0                 /* write into L0 page table */
    li a4, 0                 /* Host page table */
    jal pte_setup

    /* Host L0 leaf PTE: maps vu_mode GVA → vu_mode PA */
    la a0, vu_mode
    la a1, vu_mode
    li a2, 0xde              /* RWX+User+Accessed+Dirty leaf PTE */
    li a3, 0
    li a4, 0                 /* Host page table */
    jal pte_setup

    /* ---- Guest Page Table Setup (for VS/VU-mode inside the guest) ----
     * These entries are used by vsatp (VS-stage first-level translation).
     * For simplicity each level is an identity-mapped leaf PTE. */

    /* Guest root PTE: identity map Root_Page_Table_G */
    la a0, Root_Page_Table_G
    la a1, Root_Page_Table_G
    li a2, 0xde
    li a3, 0
    li a4, 0                 /* still uses pte_setup with a4=0 here
                               * because Root_Page_Table_G is set up before
                               * switching to guest mode */
    jal pte_setup

    /* Guest L1 PTE: identity map Level_one_Page_Table_G */
    la a0, Level_one_Page_Table_G
    la a1, Level_one_Page_Table_G
    li a2, 0xde
    li a3, 0
    li a4, 0
    jal pte_setup

    /* Guest L0 PTE: identity map Level_zero_Page_Table_G */
    la a0, Level_zero_Page_Table_G
    la a1, Level_zero_Page_Table_G
    li a2, 0xde
    li a3, 0
    li a4, 0
    jal pte_setup

    /* Fall through to switch_hs to perform M → HS mode transition */
    jal switch_hs


/* ========================================================================
 * SWITCH TO HS-MODE: switch_hs
 * Uses mret to drop from M-mode to HS-mode (Hypervisor Supervisor).
 * Sets MPP=1 in mstatus so mret targets S-mode (HS-mode, not VS-mode).
 * ======================================================================== */
switch_hs:
    li t0, 0x00000800         /* MPP field: bits [12:11] = 01 → S-mode (HS) */
    csrs mstatus, t0          /* set MPP=1 in mstatus (was 0=U-mode) */
    la t0, hs_mode            /* address of HS-mode entry point */
    csrw mepc, t0             /* mret will jump here */
    mret                      /* drop to HS-mode (privilege level 1) */


/* ========================================================================
 * HS-MODE ENTRY: hs_mode
 * Hypervisor Supervisor mode setup:
 *   1. Install HS-mode trap vector (hs_trap_vector)
 *   2. Configure vsatp for guest first-stage address translation (Sv39)
 *   3. Setup guest-side page table entries (using G-stage tables)
 *   4. Configure hstatus.SPV=1 and sstatus.SPP=1 for sret → VS-mode
 * ======================================================================== */
hs_mode:
    /* Install the HS-mode trap vector. All traps taken in HS-mode (or
     * delegated from VS/VU-mode) are handled at hs_trap_vector. */
    la t0, hs_trap_vector
    csrw stvec, t0            /* Supervisor Trap-Vector CSR */

    /* Configure vsatp: VS-stage first-level page table for the guest.
     * vsatp format: MODE[63:60]=8 (Sv39) | ASID | PPN
     * The guest's root page table is Root_Page_Table_G. */
    la t0, Root_Page_Table_G
    srli t0, t0, 12           /* PPN = PA >> 12 */
    li t1, (8 << 60)          /* MODE=8 → Sv39 for VS-stage */
    or t0, t0, t1
    csrw vsatp, t0            /* program VS-stage translation root */
    hfence.vvma               /* flush VS-stage TLB (all VMID/ASID entries) */

    /* ---- Guest (VS-stage) page table entries via pte_setup ----
     * These PTEs map addresses as seen by the guest (GVA → GPA → HPA
     * through two-stage translation). a4=1 selects guest page tables. */

    /* Guest L2 root PTE for vs_mode → Level_one_Page_Table_G */
    la a0, vs_mode
    la a1, Level_one_Page_Table_G
    li a2, 0x00               /* non-leaf pointer PTE */
    li a3, 2
    li a4, 1                  /* Guest page table (a4=1) */
    jal pte_setup

    /* Guest L1 PTE for vs_mode → Level_zero_Page_Table_G */
    la a0, vs_mode
    la a1, Level_zero_Page_Table_G
    li a2, 0x00               /* non-leaf pointer PTE */
    li a3, 1
    li a4, 1
    jal pte_setup

    /* Guest L0 leaf PTE for vs_mode → vs_mode (identity)
     * Permissions 0xce = 0b11001110: D=1, A=1, G=0, U=0 (supervisor only),
     * X=1, W=1, R=1 — note U=0 so VU-mode cannot access vs_mode directly */
    la a0, vs_mode
    la a1, vs_mode
    li a2, 0xce              /* RWX+Supervisor+Accessed+Dirty */
    li a3, 0
    li a4, 1
    jal pte_setup

    /* Guest L0 leaf PTE for vu_mode → vu_mode (identity)
     * Permissions 0xde includes U=1 so VU-mode can execute vu_mode code */
    la a0, vu_mode
    la a1, vu_mode
    li a2, 0xde              /* RWX+User+Accessed+Dirty */
    li a3, 0
    li a4, 1
    jal pte_setup

    /* ----------------------------------------------------------------
     * Perform sret to jump into VS-mode (Virtual Supervisor).
     * hstatus.SPV=1 means "after sret, set V=1 (guest mode active)"
     * sstatus.SPP=1 means "the previous mode was S-mode" (→ VS-mode)
     * sepc = vs_mode entry point
     * ---------------------------------------------------------------- */
    /* Set hstatus.SPV = 1 (bit 7): sret will enter virtualized mode */
    li t0, 0x80
    csrs hstatus, t0          /* hstatus.SPV=1: next sret activates V=1 */

    /* Set sstatus.SPP = 1 (bit 8): previous privilege was S-mode
     * Combined with hstatus.SPV=1, sret goes to VS-mode (not HS-mode) */
    li t0, 0x100
    csrs sstatus, t0          /* sstatus.SPP=1: return to supervisor (VS) */

    la t0, vs_mode            /* VS-mode entry point */
    csrw sepc, t0             /* supervisor exception PC */
    sret                      /* jump to VS-mode (V=1, Priv=S) */


/* ========================================================================
 * HS-MODE EXIT: hs_mode_exit
 * Called when HS trap handler sees scause=10 (VS-mode ecall).
 * Issues an ecall to escalate to M-mode, then falls through to write_tohost.
 * ======================================================================== */
hs_mode_exit:
    ecall                      /* ecall from HS → M-mode (mcause=9) */
    j write_tohost             /* after M-mode returns, write success */


/* ========================================================================
 * PTE_SETUP SUBROUTINE
 * Builds and stores a single Page Table Entry.
 *
 * Arguments:
 *   a0 = Virtual address being mapped (GVA or VA)
 *   a1 = Physical address of target (next-level PT or leaf page)
 *   a2 = Permission bits (e.g., 0xde=RWX+U+A+D, 0x00=non-leaf pointer)
 *   a3 = Page table level to write into (2=root/L2, 1=L1, 0=L0/leaf)
 *   a4 = 0 → Host page tables, 1 → Guest page tables
 *
 * PTE format (Sv39, 8 bytes):
 *   [63:54] reserved | [53:10] PPN[2:0] | [9:8] RSW | [7] D | [6] A |
 *   [5] G | [4] U | [3] X | [2] W | [1] R | [0] V
 *
 * The subroutine:
 *   1. Extracts VPN[0], VPN[1], VPN[2] from the virtual address
 *   2. Builds the PTE: PPN = a1>>12, then << 10, OR permissions, OR V=1
 *   3. Writes the PTE at the correct index in the chosen page table
 * ======================================================================== */
pte_setup:
    /* Extract virtual page numbers from the 39-bit virtual address (a0):
     * Sv39 VA layout: VPN[2][38:30] | VPN[1][29:21] | VPN[0][20:12] | offset[11:0] */
    srli t0, a0, 12            /* shift out the 12-bit page offset */
    andi t1, t0, 0x1ff         /* VPN[0] = bits [20:12] (9 bits) */
    srli t0, t0, 9
    andi t2, t0, 0x1ff         /* VPN[1] = bits [29:21] (9 bits) */
    srli t3, t0, 9             /* VPN[2] = bits [38:30] (9 bits) */
        
    /* Build the PTE value:
     *   PPN = physical page number of target = a1 >> 12
     *   PTE = (PPN << 10) | permission_bits | V(=1) */
    srli t4, a1, 12            /* PPN of target physical page */
    slli t4, t4, 10            /* shift PPN to bits [53:10] of PTE */
    or   t4, t4, a2            /* OR in permission bits (D,A,G,U,X,W,R) */
    ori  t4, t4, 1             /* set V=1 (valid bit, bit 0) */

    /* Dispatch to Host or Guest page table based on a4 */
    bnez a4, guest             /* if a4!=0 use guest tables */

    /* ---- Host page tables (a4=0) ---- */
    la s1, Root_Page_Table_H
    slli t5, t3, 3             /* index = VPN[2] * 8 (each PTE is 8 bytes) */
    add  t6, s1, t5            /* &Root_Page_Table_H[VPN[2]] */
    li   t0, 2
    beq  a3, t0, L2            /* if level=2, write here (root) */

    /* Level 1 host page table */
    la s2, Level_one_Page_Table_H
    slli t5, t2, 3             /* index = VPN[1] * 8 */
    add  t6, s2, t5            /* &Level_one_Page_Table_H[VPN[1]] */
    li   t0, 1
    beq  a3, t0, L1            /* if level=1, write here */

    /* Level 0 host page table (leaf) */
    la s3, Level_zero_Page_Table_H
    slli t5, t1, 3             /* index = VPN[0] * 8 */
    add  t6, s3, t5            /* &Level_zero_Page_Table_H[VPN[0]] */
    sd   t4, 0(t6)             /* store the 8-byte PTE */
    ret

/* ---- Guest page tables (a4!=0) ---- */
guest:
    la s1, Root_Page_Table_G
    slli t5, t3, 3             /* index = VPN[2] * 8 */
    add  t6, s1, t5            /* &Root_Page_Table_G[VPN[2]] */
    li   t0, 2
    beq  a3, t0, L2            /* if level=2, write here */

    /* Level 1 guest page table */
    la s2, Level_one_Page_Table_G
    slli t5, t2, 3             /* index = VPN[1] * 8 */
    add  t6, s2, t5            /* &Level_one_Page_Table_G[VPN[1]] */
    li   t0, 1
    beq  a3, t0, L1            /* if level=1, write here */

    /* Level 0 guest page table (leaf) */
    la s3, Level_zero_Page_Table_G
    slli t5, t1, 3             /* index = VPN[0] * 8 */
    add  t6, s3, t5            /* &Level_zero_Page_Table_G[VPN[0]] */
    sd   t4, 0(t6)             /* store the 8-byte PTE */
    ret

/* Common store points for root (L2) and level-1 (L1) PTEs */
L2:
    sd t4, 0(t6)               /* store non-leaf PTE at root table entry */
    ret
L1:
    sd t4, 0(t6)               /* store non-leaf PTE at L1 table entry */
    ret


/* ========================================================================
 * PASS / FAIL / WRITE_TOHOST
 * ======================================================================== */
pass:
    j write_tohost             /* jump to success write */
    
fail:
    /* Write 0xcafebeef to tohost to signal failure to the test harness */
    la t1, base
    lw gp, 0(t1)              /* load failure signature = 0xcafebeef */
    la t0, tohost
    sw gp, 0(t0)              /* tohost = 0xcafebeef → FAIL */
    j fail                    /* spin forever */
  
write_tohost:
    /* Write 1 to tohost to signal success to the test harness (Spike exits) */
    li gp, 1
    la t0, tohost
    sw gp, 0(t0)              /* tohost = 1 → PASS */
    j write_tohost            /* spin (Spike will terminate on tohost=1) */


/* ========================================================================
 * VS-MODE CODE SECTION
 * .align 12 = 4KB page alignment (required so VS-mode page is page-aligned
 * and can be mapped as a single 4KB page in the guest page table).
 *
 * vs_mode: Guest Supervisor (VS-mode) code.
 *   1. Stores test value 0xDEADBEEF at a known guest physical address
 *   2. Transitions to VU-mode by clearing sstatus.SPP and executing sret
 *
 * vs_verify: VS-mode verification code (jumped to by HS-mode after HLV/HSV).
 *   1. Loads the (now modified) value with LW + shift trick to strip sign ext.
 *   2. Verifies it equals 0xDEADBFEF (= 0xDEADBEEF + 0x100)
 *   3. Issues ecall to HS-mode (scause=10) to signal test completion
 * ======================================================================== */
.text
.align 12                     /* 4KB alignment: vs_mode starts on its own page */
vs_mode: 
    /* Store test magic value 0xDEADBEEF at guest address 0x80004088
     * This address is within the vs_mode page (0x80004000), at offset 0x88.
     * The HS-mode hypervisor will later read and modify this via HLV.WU/HSV.W. */
    li t0, 0x80004088          /* target guest virtual address */
    li t1, 0xDEADBEEF          /* test pattern */
    sw t1, 0(t0)               /* store 32-bit value to guest memory */

    /* Transition to VU-mode:
     * Clear sstatus.SPP (bit 8) → sret will return to User mode (VU-mode)
     * hstatus.SPV remains 1, so User mode means Virtual User (VU) mode */
    li t0, 0x100
    csrc sstatus, t0           /* sstatus.SPP = 0 (next sret → U/VU mode) */
    
    la t0, vu_mode             /* VU-mode entry point */
    csrw sepc, t0              /* set supervisor exception PC */
    sret                       /* jump to VU-mode (V=1, Priv=U) */


/* vs_verify: reached after HS trap handler handles VU-mode ecall.
 * At this point Guest[0x80004088] has been modified by HS via HSV.W.
 * We verify the modified value is 0xDEADBFEF. */
vs_verify:
    li t0, 0x80004088          /* guest virtual address of test value */
    /* Note: LW sign-extends. We use shift trick to zero-extend to 64 bits:
     *   t1 = (lw << 32) >> 32  ≡  zero-extend to 64-bit */
    lwu t1, 0(t0)               /* load 32-bit value (unsigned-zero-extended: 0x00000000DEADBFEF) */
    li t2, 0xDEADBFEF          /* expected: 0xDEADBEEF + 0x100 */
    bne t1, t2, fail           /* if mismatch, test fails */
    ecall                      /* VS-mode ecall → HS-mode (scause=10 in HS) */


/* ========================================================================
 * VU-MODE CODE SECTION
 * .align 12 = 4KB page alignment (vu_mode on its own page, U-accessible)
 *
 * VU-mode application:
 *   Passes the guest memory address (0x80004088) in a0, then calls ecall.
 *   The ecall traps to HS-mode (scause=8, VU ecall delegated via medeleg).
 * ======================================================================== */
.text
.align 12                     /* 4KB alignment for VU-mode page */
vu_mode:
    la a0, vs_mode
    li a1, 2                   /* command argument to verify execute instruction HLVX.WU */
    ecall
    li a0, 0x80004088          /* a0 = guest VA where 0xDEADBEEF was stored */
    li a1, 1                   /* a1 = mem_access (command code, purpose of ecall RW from mem) */
    ecall                      /* VU-mode ecall → HS-mode trap (scause=8) */

    j write_tohost             /* unreachable; HS redirects sepc to vs_verify */

.align 12


/* ========================================================================
 * PAGE TABLE DATA SECTION
 * All page tables are placed in .text with specific alignment.
 *
 * Host (Hypervisor) page tables — used for G-stage translation (hgatp):
 *   Root_Page_Table_H     : 16KB (Sv39x4 root has 2048 entries of 8B each)
 *   Level_one_Page_Table_H: 4KB  (standard Sv39 L1 = 512 entries × 8B)
 *   Level_zero_Page_Table_H: 4KB (standard Sv39 L0 = 512 entries × 8B)
 *
 * Guest page tables — used for VS-stage translation (vsatp):
 *   Root_Page_Table_G      : 4KB (512 entries × 8B)
 *   Level_one_Page_Table_G : 4KB
 *   Level_zero_Page_Table_G: 4KB
 *
 * Note: Sv39x4 (used for G-stage) has a root table 4× larger than Sv39
 * because two extra GPA bits are handled at the root level (2+9+9+9+12=42 bits).
 * ======================================================================== */
.text

/* Host page tables */
.align 14                      /* 16KB alignment for Sv39x4 root page table */
Root_Page_Table_H:
    .space 16384               /* 2048 PTEs × 8 bytes = 16384 bytes */
.align 12                      /* 4KB alignment */
Level_one_Page_Table_H:
    .space 4096                /* 512 PTEs × 8 bytes = 4096 bytes */
Level_zero_Page_Table_H:
    .space 4096                /* 512 PTEs × 8 bytes = 4096 bytes */

/* Guest page tables */
.align 12                      /* 4KB alignment */
Root_Page_Table_G:
    .space 4096                /* 512 PTEs × 8 bytes (Sv39 root) */
Level_one_Page_Table_G:
    .space 4096                /* 512 PTEs × 8 bytes */
Level_zero_Page_Table_G:
    .space 4096                /* 512 PTEs × 8 bytes */


/* ========================================================================
 * TEST DATA: failure signature loaded by fail handler
 * ======================================================================== */
RVTEST_DATA_BEGIN
base:
.word 0xcafebeef               /* failure signature written to tohost on test failure */