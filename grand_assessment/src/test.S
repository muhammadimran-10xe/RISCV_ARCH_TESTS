/*
 * test.S - RISC-V Hypervisor Extension Test
 *
 * Task: Two-Stage Address Translation and Guest Memory Access
 *
 * This test implements a privilege transitions :
 *   M-mode → HS-mode (Hypervisor Supervisor) → VS-mode (Virtual Supervisor) → VU-mode (Virtual User)
 * and exercises the RISC-V Hypervisor Extension (H-extension) features:
 *   - Two-stage address translation via vsatp (VS-stage) + hgatp (G-stage)
 *   - HLV.WU  : Hypervisor Load  Word Unsigned — data read  from guest memory
 *   - HSV.W   : Hypervisor Store Word          — data write to guest memory
 *   - HLVX.WU : Hypervisor Load  Word Unsigned — instruction fetch from guest code 
 *   - Trap delegation using medeleg (bits 8, 10, 12, 13, 15)
 *
 * Privilege levels in Spike log (digit after "core 0:"):
 *   3 = M-mode  (Machine)
 *   1 = HS-mode (Hypervisor Supervisor) — also shows as 1 for VS-mode when V=1
 *   0 = VU-mode (Virtual User)
 *
 * Full runtime mode-transition sequence:
 *   M → HS → VS → VU
 *   VU --ecall(a1=2)--> HS  [HLVX.WU: fetch_vs_inst]   --> VU (sepc+4)
 *   VU --ecall(a1=1)--> HS  [HLV.WU+HSV.W: mem_access] --> VS (vs_verify)
 *   VS --ecall---------> HS  [scause=10: hs_mode_exit]
 *   HS --ecall---------> M   [mcause=9: m_trap_vector]
 *   HS --> write_tohost=1   (PASS)
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
     * mtvec holds the address of m_trap_vector, which handles the single
     * M-mode trap in this test: the HS-mode ecall at test exit (mcause=9).
     * ---------------------------------------------------------------- */
    la t6, m_trap_vector       
    csrw mtvec, t6             

    /* ----------------------------------------------------------------
     * Delegate exceptions to HS-mode via medeleg.
     * 0xb500 = bits 15|13|12|10|8:
     *   bit  8 :Ecall from U-mode  (VU-mode ecall → HS-mode)
     *   bit 10 :Ecall from VS-mode (VS ecall    → HS-mode)
     *   bit 12 :Instruction page fault → HS-mode
     *   bit 13 :Load page fault        → HS-mode
     *   bit 15 :Store/AMO page fault   → HS-mode
     * ---------------------------------------------------------------- */
    li t0, 0xb500           
    csrw medeleg, t0

    /* ----------------------------------------------------------------
     * Initialize hgatp for G-stage (GPA → HPA) address translation.
     * hgatp format: MODE[63:60] | VMID[57:44] | PPN[43:0]
     *   MODE = 8 → Sv39x4 (42-bit guest-physical address space;
     *              root table is 4x normal size = 16 KB / 2048 entries)
     *   PPN  = Root_Page_Table_H >> 12
     * ---------------------------------------------------------------- */
    la t0, Root_Page_Table_H   /* physical address of host root page table */
    srli t0, t0, 12            /* PPN = PA >> 12                           */
    li   t1, (8 << 60)         /* MODE=8 selects Sv39x4                    */
    or   t0, t0, t1            /* combine MODE | PPN                       */
    csrw hgatp, t0             /* program G-stage page table root          */
    hfence.gvma                /* flush all G-stage TLB entries globally   */

    /* ----------------------------------------------------------------
     * 4. Jump to main for page table setup before switching to HS-mode
     * ---------------------------------------------------------------- */
    j main
    

/* ========================================================================
 * M-MODE TRAP HANDLER: m_trap_vector
 * Handles the single M-mode trap: the HS-mode ecall at test exit.
 *   Expected: mcause = 9 (Environment call from S-mode / HS-mode ecall)
 *   Action: advance mepc past the ecall (mepc += 4), then mret to M-mode.
 *   mret returns to m_mode_exit+4 which is "j write_tohost".
 *
 * Log evidence (lines 1051-1068):
 *   csrr t0, mcause → x5 = 0x9  (HS ecall confirmed)
 *   bne  t0, t1     → NOT taken (correct cause)
 *   addi t2, t2, 4  → mepc = 0x800002d0 (m_mode_exit ecall + 4)
 *   change privilege to M-mode
 *   mret            → returns to M-mode
 * ======================================================================== */
m_trap_vector:                               
    csrr t0, mcause            /* read Machine Cause Register              */
    li t1, 9                   /* expected: ecall from S-mode (HS ecall)   */
    bne t0, t1, fail           /* unexpected cause → test failure          */
    csrr t2, mepc              /* read faulting instruction address        */
    addi t2, t2, 4             /* skip past the 4-byte ecall instruction   */
    csrw mepc, t2              /* write updated return address             */
    li t0, (3 << 11)
    csrs mstatus, t0
    mret                       /* return to M-mode                         */


/* ========================================================================
 * HS-MODE TRAP HANDLER: hs_trap_vector
 *
 * Central handler for all exceptions delegated to HS-mode:
 *   scause = 10 → VS-mode ecall: test complete → jump to hs_mode_exit
 *   scause =  8 → VU-mode ecall: set hstatus.SPVP=1, then dispatch on a1:
 *       a1 = 1 → mem_access    : HLV.WU read / modify / HSV.W write
 *       a1 = 2 → fetch_vs_inst : HLVX.WU instruction fetch from VS code
 *
 * Using a1 as a command code allows a single VU ecall number to dispatch
 * multiple distinct hypervisor services without adding new ecall numbers.
 *
 * hstatus.SPVP is set to 1 (Supervisor privilege) before the dispatch
 * so that both HLV.WU and HLVX.WU use VS-supervisor privilege when
 * walking the two-stage page tables.
 *
 * ======================================================================== */
hs_trap_vector:
    csrr t0, scause            /* read Supervisor Cause Register           */
    li t1, 8                   /* cause 8 = ecall from VU-mode (U-mode)    */
    li t2, 10                  /* cause 10 = ecall from VS-mode            */
    beq t0, t2, hs_mode_exit   /* scause=10 → VS ecall → exit path         */
    bne t0, t1, fail           /* unexpected cause → fail                  */

    /* ----------------------------------------------------------------
     * scause = 8 (VU-mode ecall):
     * Set hstatus.SPVP = 1 (bit 8) so HLV/HLVX/HSV instructions use
     * Supervisor privilege for the two-stage address translation walk.
     * SPVP values:
     *   0 = User-level translation
     *   1 = Supervisor-level translation  ← set here
     * Supervisor privilege is needed because the vs_mode page is mapped
     * with U=0 (supervisor-only) in the guest page table.
     *
     * ---------------------------------------------------------------- */
    li t1, 0x100              /* SPVP is bit 8 of hstatus                  */
    csrr t2, hstatus           /* read current hstatus                     */
    or t1, t1, t2             /* set bit 8 (SPVP=1)                        */
    csrw hstatus, t1          /* write updated hstatus                     */

    /* a1 command code. */

    li  t3, 1                  /* RW_ACCESS  = 1                      */
    li t4, 2                   /* FETCH_INSTR = 2                      */
    beq a1, t3, rw_vs_access     /* a1==1 → HLV.WU + HSV.W handler          */
    beq a1, t4, fetch_vs_inst  /* a1==2 → HLVX.WU handler                 */
    j fail                     /* unknown command code → test failure      */


/* ========================================================================
 * fetch_vs_inst (a1 = 2)
 *
 * Uses HLVX.WU to fetch a 32-bit instruction word from a VS-mode code
 * virtual address (a0 = vs_mode page base = 0x80004000).
 *
 * How HLVX.WU differs from HLV.WU:
 *   HLV.WU  uses Read    permission bits during the two-stage page walk
 *   HLVX.WU uses Execute permission bits — simulates a CPU instruction
 *            fetch from the guest's perspective
 * The vs_mode page is mapped with perm 0xce which includes X=1 (execute),
 * so the HLVX.WU execute-permission walk succeeds.
 *
 * Return path: sepc is advanced by 4 so sret returns VU-mode to the
 * instruction immediately after the ecall (the "li a0, 0x80004088").
 *
 * ======================================================================== */
fetch_vs_inst:
    hlvx.wu t2, (a0)           /* fetch instruction from VS code GVA(a0)
                                 * execute-permission two-stage walk:
                                 * GVA(0x80004000) → GPA(vsatp) → HPA(hgatp) */
    csrr t0, sepc              /* sepc = address of the ecall that trapped  */
    addi t0, t0, 4             /* advance past the 4-byte ecall            */
    csrw sepc, t0              /* sepc now points to next VU instruction   */
    /* sstatus.SPP is already 0 (set during VS→VU sret), so sret returns
     * to VU-mode (priv=0) automatically. hstatus.SPV=1 keeps V=1 active. */
    sret                       /* return to VU-mode at ecall+4             */


/* ========================================================================
 * rw_access (a1 = 1)
 *
 * Reads from guest memory, modifies the value, writes it back:
 *   HLV.WU  Guest[a0]          → t2 = 0xDEADBEEF (zero-extended, no sign-ext)
 *   add t2, t2, 0x100          → t2 = 0xDEADBFEF
 *   HSV.W   t2 → Guest[a0]
 *
 * Both instructions perform the full two-stage walk:
 *   GVA (a0=0x80004088) → GPA via vsatp → HPA via hgatp
 *
 * After the write, sepc is set to vs_verify and sret returns to VS-mode
 * (not back to VU-mode) so the guest can verify the modification.
 * ======================================================================== */
rw_vs_access:
    /* HLV.WU: Hypervisor Load Word Unsigned
     * a0 = guest virtual address (0x80004088).
     * 'WU' = unsigned → 32-bit result zero-extended to 64 bits.
     * Using HLV.W (signed) would produce 0xFFFFFFFFDEADBEEF — incorrect. */
    hlv.wu t2, (a0)           /* t2 = zero-extended Guest[a0]              */

    /* Modify: 0xDEADBEEF + 0x100 = 0xDEADBFEF */
    li t3, 0x100
    add t2, t2, t3            /* compute modified value                    */

    /* HSV.W: Hypervisor Store Word
     * Writes the 32-bit value back through the same two-stage walk. */
    hsv.w t2, (a0)            /* Guest[a0] = 0xDEADBFEF                    */

    /* Redirect sret to vs_verify (VS-mode verification code).
     * Instead of returning to the VU-mode ecall site, we return to VS-mode
     * so it can confirm the written value. */
    la t0, vs_verify           /* address of VS-mode verification code     */
    csrw sepc, t0             /* set supervisor exception program counter  */

    /* Configure return to VS-mode:
     *   sstatus.SPP = 1 → sret returns to S-privilege (VS-mode due to SPV=1)
     *   hstatus.SPV = 1 → V=1 is set after sret → VS-mode not HS-mode */
    li t0, 0x100
    csrs sstatus, t0           /* set SPP=1 (return to supervisor/VS)      */
    li t0, 0x80
    csrs hstatus, t0           /* ensure SPV=1 (V=1 after sret)            */

    sret                       /* return to VS-mode at vs_verify           */


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

    /* Host L2 (root) PTE: maps vs_mode VA → Level_one_Page_Table_H (non-leaf pointer) */
    la a0, vs_mode             /* virtual address to map */
    la a1, Level_one_Page_Table_H  /* next-level page table PA */
    li a2, 0x00               /* no leaf permissions (non-leaf pointer PTE) */
    li a3, 2                  /* write into L2 (root) page table           */
    li a4, 0                  /* Host page table (a4=0)                    */
    jal pte_setup

    /* Host L1 PTE: maps vs_mode VA → Level_zero_Page_Table_H (non-leaf pointer) */
    la a0, vs_mode
    la a1, Level_zero_Page_Table_H
    li a2, 0x00               /* non-leaf pointer PTE                      */
    li a3, 1                  /* write into L1 page table                  */
    li a4, 0                  /* Host page table                           */
    jal pte_setup

    /* Host L0 (leaf) PTE: maps vs_mode VA → vs_mode PA (identity map)
     * Permission bits 0xde = 0b11011110:
     *   D=1(dirty), A=1(accessed), G=0, U=1(user), X=1(execute),
     *   W=1(write), R=1(read), V=1(valid, added by pte_setup) */
    la a0, vs_mode
    la a1, vs_mode            /* identity map: VA → same PA                */
    li a2, 0xde              /* RWX+User+Accessed+Dirty leaf PTE           */
    li a3, 0                 /* write into L0 page table                   */
    li a4, 0                 /* Host page table                            */
    jal pte_setup

    /* Host L0 leaf PTE: maps vu_mode VA → vu_mode PA (identity map) */
    la a0, vu_mode
    la a1, vu_mode
    li a2, 0xde              /* RWX+User+Accessed+Dirty leaf PTE           */
    li a3, 0
    li a4, 0                 /* Host page table                            */
    jal pte_setup

    /* ---- Guest Page Table Setup (page-table pages themselves) ----
     * Identity-map the guest page-table pages so vsatp can walk them
     * after V=1 is activated. a4=0 is used here because these PTEs are
     * set up before entering guest mode (still in M-mode). */

    /* Identity map Root_Page_Table_G into the Host tables */
    la a0, Root_Page_Table_G
    la a1, Root_Page_Table_G
    li a2, 0xde
    li a3, 0
    li a4, 0                 /* Host table — set up before entering guest  */
    jal pte_setup

    /* Identity map Level_one_Page_Table_G */
    la a0, Level_one_Page_Table_G
    la a1, Level_one_Page_Table_G
    li a2, 0xde
    li a3, 0
    li a4, 0
    jal pte_setup

    /* Identity map Level_zero_Page_Table_G */
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
 * Uses mret to drop from M-mode to HS-mode.
 * mstatus.MPP[12:11] = 01 → S-mode (HS-mode) target for mret.
 * ======================================================================== */
switch_hs:
    li t0, 0x00000800         /* MPP field: bits [12:11] = 01 → S-mode (HS) */
    csrs mstatus, t0          /* set MPP=1 in mstatus                      */
    la t0, hs_mode            /* address of HS-mode entry point            */
    csrw mepc, t0             /* mret will jump here                       */
    mret                      /* drop to HS-mode (privilege level 1)       */

/* ========================================================================
 * HS-MODE ENTRY: hs_mode  (Spike priv digit = 1, hstatus.V = 0)
 * Hypervisor Supervisor mode setup:
 *   1. Install HS-mode trap vector (hs_trap_vector) into stvec
 *   2. Configure vsatp for VS-stage translation (Sv39, guest root PT)
 *   3. Build guest-side page table entries (a4=1 selects Guest tables)
 *   4. Set hstatus.SPV=1 + sstatus.SPP=1, then sret → VS-mode
 * ======================================================================== */
hs_mode:
    /* setup HS-mode trap vector into stvec.
     * All traps taken in HS-mode (or delegated from VS/VU-mode) are
     * handled at hs_trap_vector. */
    la t0, hs_trap_vector
    csrw stvec, t0            /* Supervisor Trap-Vector Base-Address CSR   */

    /* Configure vsatp: VS-stage first-level page table (GVA → GPA).
     * vsatp format: MODE[63:60]=8 (Sv39) | ASID[59:44] | PPN[43:0] */
    la t0, Root_Page_Table_G
    srli t0, t0, 12           /* PPN = PA >> 12                            */
    li t1, (8 << 60)          /* MODE=8 → Sv39 for VS-stage                */
    or t0, t0, t1
    csrw vsatp, t0            /* program VS-stage translation root         */
    hfence.vvma               /* flush VS-stage TLB (all VMID/ASID entries) */

    /* ---- Guest (VS-stage) page table entries via pte_setup ----
     * a4=1 selects Guest page tables (Root/L1/L0_Page_Table_G).
     * These PTEs map GVAs as seen by the guest OS.                    */

    /* Guest L2 root PTE: vs_mode GVA → Level_one_Page_Table_G (non-leaf pointer) */
    la a0, vs_mode
    la a1, Level_one_Page_Table_G
    li a2, 0x00               /* non-leaf pointer PTE                      */
    li a3, 2
    li a4, 1                  /* Guest page table (a4=1)                   */
    jal pte_setup

    /* Guest L1 PTE: vs_mode GVA → Level_zero_Page_Table_G (non-leaf pointer) */
    la a0, vs_mode
    la a1, Level_zero_Page_Table_G
    li a2, 0x00               /* non-leaf pointer PTE                      */
    li a3, 1
    li a4, 1
    jal pte_setup

    /* Guest L0 leaf PTE: vs_mode GVA → vs_mode PA (identity map)
     * Permissions 0xce = 0b11001110:
     *   D=1(dirty), A=1(accessed), G=0, U=0(supervisor-only),
     *   X=1(execute), W=1(write), R=1(read)
     * U=0 → VU-mode cannot access vs_mode directly (must go via HLV/HSV)
     * X=1 → HLVX.WU (execute-permission fetch) will succeed on this page */
    la a0, vs_mode
    la a1, vs_mode
    li a2, 0xce              /* RWX+Supervisor+Accessed+Dirty              */
    li a3, 0
    li a4, 1
    jal pte_setup

    /* Guest L0 leaf PTE: vu_mode GVA → vu_mode PA (identity map)
     * Permissions 0xde includes U=1 → VU-mode can execute vu_mode code */
    la a0, vu_mode
    la a1, vu_mode
    li a2, 0xde              /* RWX+User+Accessed+Dirty                    */
    li a3, 0
    li a4, 1
    jal pte_setup

    /* ----------------------------------------------------------------
     * Perform sret to enter VS-mode (Virtual Supervisor).
     * hstatus.SPV=1 → V=1 is activated after sret (guest mode on)
     * sstatus.SPP=1 → return to S-privilege → VS-mode
     * sepc = vs_mode entry point
     * ---------------------------------------------------------------- */
    li t0, 0x80
    csrs hstatus, t0          /* set hstatus.SPV=1 (bit 7)                 */
    li t0, 0x100
    csrs sstatus, t0          /* set sstatus.SPP=1 (bit 8)                 */
    la t0, vs_mode            /* VS-mode entry point                       */
    csrw sepc, t0             /* supervisor exception PC                   */
    sret                      /* jump to VS-mode (V=1, S-privilege)        */


/* ========================================================================
 * HS-MODE EXIT: hs_mode_exit
 * Reached when hs_trap_vector sees scause=10 (VS-mode ecall).
 * Issues an ecall to escalate to M-mode (mcause=9 there).
 * After M-mode skips the ecall (mepc+=4) and mrets, execution resumes
 * at the next instruction: "j write_tohost".
 * ======================================================================== */
hs_mode_exit:
    ecall                      /* HS ecall → M-mode (mcause=9)             */
m_mode:
    j write_tohost             /* after mret from M-mode: write PASS       */


/* ========================================================================
 * PTE_SETUP SUBROUTINE
 * Builds and stores a single Page Table Entry.
 *
 * Arguments:
 *   a0 = Virtual address being mapped (used to extract VPN[2:0])
 *   a1 = Physical address of target (next-level PT or leaf page)
 *   a2 = Permission bits (e.g. 0xde=RWX+U+A+D, 0x00=non-leaf pointer)
 *   a3 = Page table level to write (2=root/L2, 1=L1, 0=L0/leaf)
 *   a4 = 0 → Host page tables, 1 → Guest page tables
 *
 * PTE format (Sv39, 8 bytes):
 *   [63:54] reserved | [53:10] PPN[2:0] | [9:8] RSW | [7]D | [6]A |
 *   [5]G | [4]U | [3]X | [2]W | [1]R | [0]V
 *
 * Steps:
 *   1. Extract VPN[0], VPN[1], VPN[2] from VA (9 bits each)
 *   2. Build PTE: PPN = a1>>12, PTE = (PPN<<10) | perms | V=1
 *   3. Compute entry address = table_base + VPN[level]*8
 *   4. Store 8-byte PTE with sd
 * ======================================================================== */
pte_setup:
    /* Extract virtual page numbers from the 39-bit VA (a0):
     * Sv39 layout: VPN[2][38:30] | VPN[1][29:21] | VPN[0][20:12] | offset[11:0] */
    srli t0, a0, 12            /* discard 12-bit page offset                */
    andi t1, t0, 0x1ff         /* VPN[0] = bits [20:12]  (9 bits)          */
    srli t0, t0, 9
    andi t2, t0, 0x1ff         /* VPN[1] = bits [29:21]  (9 bits)          */
    srli t3, t0, 9             /* VPN[2] = bits [38:30]  (9 bits)          */
        
    /* Build PTE value: PPN<<10 | permission_bits | V=1 */
    srli t4, a1, 12            /* PPN = target PA >> 12                    */
    slli t4, t4, 10            /* shift PPN to bits [53:10] of PTE         */
    or   t4, t4, a2            /* OR in permission bits (D,A,G,U,X,W,R)   */
    ori  t4, t4, 1             /* set V=1 (valid bit)                      */

    /* Dispatch to Host or Guest page table */
    bnez a4, guest             /* if a4!=0 → use guest tables              */

    /* ---- Host page tables (a4=0) ---- */
    la s1, Root_Page_Table_H
    slli t5, t3, 3             /* VPN[2] * 8 bytes/entry                   */
    add  t6, s1, t5            /* &Root_Page_Table_H[VPN[2]]               */
    li   t0, 2
    beq  a3, t0, L2            /* level=2 → store at root entry            */

    la s2, Level_one_Page_Table_H
    slli t5, t2, 3             /* VPN[1] * 8                               */
    add  t6, s2, t5            /* &Level_one_Page_Table_H[VPN[1]]          */
    li   t0, 1
    beq  a3, t0, L1            /* level=1 → store at L1 entry              */

    la s3, Level_zero_Page_Table_H
    slli t5, t1, 3             /* VPN[0] * 8                               */
    add  t6, s3, t5            /* &Level_zero_Page_Table_H[VPN[0]]         */
    sd   t4, 0(t6)             /* store the 8-byte leaf PTE                */
    ret

/* ---- Guest page tables (a4!=0) ---- */
guest:
    la s1, Root_Page_Table_G
    slli t5, t3, 3             /* VPN[2] * 8                               */
    add  t6, s1, t5            /* &Root_Page_Table_G[VPN[2]]               */
    li   t0, 2
    beq  a3, t0, L2            /* level=2 → write here                     */

    la s2, Level_one_Page_Table_G
    slli t5, t2, 3             /* VPN[1] * 8                               */
    add  t6, s2, t5            /* &Level_one_Page_Table_G[VPN[1]]          */
    li   t0, 1
    beq  a3, t0, L1            /* level=1 → write here                     */

    la s3, Level_zero_Page_Table_G
    slli t5, t1, 3             /* VPN[0] * 8                               */
    add  t6, s3, t5            /* &Level_zero_Page_Table_G[VPN[0]]         */
    sd   t4, 0(t6)             /* store the 8-byte PTE                     */
    ret

/* Common store points for root (L2) and level-1 (L1) PTEs */
L2:
    sd t4, 0(t6)               /* store non-leaf pointer PTE at root level  */
    ret
L1:
    sd t4, 0(t6)               /* store non-leaf pointer PTE at L1          */
    ret


/* ========================================================================
 * PASS / FAIL / WRITE_TOHOST
 * ======================================================================== */
pass:
    j write_tohost             /* jump to success write */
    
fail:
    la t1, base
    lw gp, 0(t1)              /* gp = 0xcafebeef                           */
    la t0, tohost
    sw gp, 0(t0)              /* tohost = 0xcafebeef → FAIL                */
    j fail                   
  
write_tohost:
    /* Write 1 to tohost → Spike reports PASS and terminates. */
    li gp, 1
    la t0, tohost
    sw gp, 0(t0)              
    j write_tohost            


/* ========================================================================
 * VS-MODE CODE SECTION
 * .align 12 = 4KB page alignment so vs_mode starts on its own page,
 * enabling it to be mapped as a single entry in both host and guest PTs.
 *
 * vs_mode   : Guest supervisor entry.
 *   1. Stores 0xDEADBEEF at 0x80004088 (vs_mode page + offset 0x88)
 *   2. Clears sstatus.SPP=0, sets sepc=vu_mode, sret → VU-mode
 *
 * vs_verify : VS-mode verification (reached after HS handles mem_access).
 *   1. LWU load from 0x80004088 → zero-extended 0x00000000DEADBFEF
 *   2. Compare with expected 0xDEADBFEF
 *   3. If match: ecall → HS-mode (scause=10) to signal test complete
 * ======================================================================== */
.text
.align 12                     /* 4KB alignment: vs_mode starts on page boundary */
vs_mode: 
    /* Store test value 0xDEADBEEF at guest VA 0x80004088.
     * 0x80004088 = vs_mode page base (0x80004000) + offset 0x88.
     * HS-mode will later read this via HLV.WU and write back 0xDEADBFEF. */
    li t0, 0x80004088          /* target guest virtual address             */
    li t1, 0xDEADBEEF          /* test pattern (MSB=1 tests sign-extension) */
    sw t1, 0(t0)               /* store 32-bit word into guest memory      */

    /* Transition to VU-mode:
     * Clear sstatus.SPP (bit 8) → sret returns to User mode.
     * With hstatus.SPV=1 still set, User mode = Virtual User (VU) mode. */
    li t0, 0x100
    csrc sstatus, t0           /* sstatus.SPP = 0 → next sret → VU-mode    */
    
    la t0, vu_mode             /* VU-mode entry point                      */
    csrw sepc, t0              /* set supervisor exception PC              */
    sret                       /* enter VU-mode (V=1, U-privilege)         */


/* vs_verify: reached after HS handles CMD_MEM_ACCESS and srets here.
 * Guest[0x80004088] has been updated to 0xDEADBFEF by HS via HSV.W.
 *
 * Uses LWU (Load Word Unsigned) directly — NOT LW.
 * LW would sign-extend: 0xDEADBFEF (bit31=1) → 0xFFFFFFFFDEADBFEF (wrong).
 * LWU zero-extends:     0xDEADBFEF           → 0x00000000DEADBFEF (correct).
 * The immediate loaded by "li t2, 0xDEADBFEF" is also zero-extended, so
 * both sides of the comparison are 0x00000000DEADBFEF → match → pass.
 *
 */
vs_verify:
    li t0, 0x80004088          /* guest virtual address of test word       */
    lwu t1, 0(t0)              /* LWU: 32-bit load, zero-extended to 64-bit */
    li t2, 0xDEADBFEF          /* expected: 0xDEADBEEF + 0x100             */
    bne t1, t2, fail           /* mismatch → test failure                  */
    ecall                      /* VS ecall → HS-mode (scause=10)           */


/* ========================================================================
 * VU-MODE CODE SECTION
 * .align 12 = 4KB page alignment so vu_mode is on its own page.
 * Mapped with U=1 in the guest page table so VU-mode can execute here.
 *
 * VU-mode makes TWO ecalls using a1 as a command code:
 *
 *   Ecall 1  a1=2  FETCH_INSTR:
 *     a0 = vs_mode address (VS code region, 0x80004000)
 *     → HS does HLVX.WU (execute-permission fetch from VS code page)
 *     → HS advances sepc by 4 and srets back to VU-mode (next instr)
 *
 *   Ecall 2  a1=1  RW_ACCESS:
 *     a0 = 0x80004088 (guest VA of the 0xDEADBEEF test word)
 *     → HS does HLV.WU + add 0x100 + HSV.W
 *     → HS redirects sepc to vs_verify (VS-mode), NOT back to VU-mode
 *
 * ======================================================================== */
.text
.align 12                     /* 4KB alignment for VU-mode page */
vu_mode:
    /* --- Ecall 1: FETCH_INSTR (a1=2) ---
     * a0 = base of vs_mode page (the VS code region to fetch from).
     * HS handles it via HLVX.WU, advances sepc by 4, srets back here+4.
     * uncomment below code to verify HLVX.WU */
     
    # la a0, vs_mode             /* a0 = 0x80004000 (VS code page base)      */
    # li a1, 2                   /* a1 = 2 = FETCH_INSTR                 */
    # ecall                      /* → HS fetch_vs_inst; sret returns to +4   */

    /* --- Ecall 2: RW_ACCESS (a1=1) ---
     * Execution reaches here because HS set sepc = address of this li.
     * HS will NOT return here — it redirects sepc to vs_verify. */
    li a0, 0x80004088          /* a0 = guest VA of test word               */
    li a1, 1                   /* a1 = 1 = RW_ACCESS                  */
    ecall                      /* → HS mem_access; HS redirects to VS      */


.align 12


/* ========================================================================
 * PAGE TABLE DATA SECTION
 * All page tables placed in .text with explicit alignment.
 *
 * Host (G-stage) page tables — walked by hgatp (GPA → HPA):
 *   Root_Page_Table_H       16KB  Sv39x4 root: 2048 entries × 8B
 *   Level_one_Page_Table_H   4KB  512 entries × 8B
 *   Level_zero_Page_Table_H  4KB  512 entries × 8B
 *
 * Guest (VS-stage) page tables — walked by vsatp (GVA → GPA):
 *   Root_Page_Table_G        4KB  512 entries × 8B  (standard Sv39 root)
 *   Level_one_Page_Table_G   4KB
 *   Level_zero_Page_Table_G  4KB
 *
 * Sv39x4 note: the G-stage root is 4× larger than Sv39 because two
 * extra GPA bits (bits 40:39) extend the address space to 42 bits.
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