    .align 4
    .globl _main

#include "../common/xnuspy_cache.h"

#include "xnuspy_ctl_tramp.h"

; This is the code an _enosys sysent was modified to point to. We mark the
; memory which holds the xnuspy_ctl image as executable and then br to it. Since
; this is the entrypoint of xnuspy_ctl, we need to preserve x0, x1, and x2.
_main:
    sub sp, sp, STACK
    stp x0, x1, [sp, STACK-0x10]
    stp x2, x19, [sp, STACK-0x20]
    stp x20, x21, [sp, STACK-0x30]
    stp x22, x23, [sp, STACK-0x40]
    stp x24, x25, [sp, STACK-0x40]
    stp x26, x27, [sp, STACK-0x50]

    adr x27, ADDRESS_OF_XNUSPY_CACHE
    ldr x27, [x27]

    ldr x19, [x27, XNUSPY_CTL_IS_RX]
    cbnz x19, handoff

    str xzr, [sp, L1_TTE]
    str xzr, [sp, L2_TTE]
    str xzr, [sp, L3_PTE]

    ldr x19, [x27, XNUSPY_CTL_CODESTART]
    ldr x20, [x27, XNUSPY_CTL_CODESZ]
    ; we don't need to worry about this not being page aligned. Clang always
    ; page-aligns __TEXT_EXEC,__text for the xnuspy_ctl image
    add x20, x19, x20

    mrs x0, ttbr1_el1 
    ; mask for baddr
    and x0, x0, 0xfffffffffffe
    ldr x22, [x27, PHYSTOKV]
    blr x22
    mov x21, x0

    ; For pteloop:
    ;   X19: current page of xnuspy_ctl code
    ;   X20: end of last page of xnuspy_ctl code
    ;   X21: virtual address of TTBR1_EL1 translation table base
    ;   X22 - X26: scratch registers
    ;   X27: xnuspy cache pointer

pteloop:
    lsr x22, x19, ARM_TT_L1_SHIFT
    and x22, x22, 0x7
    add x22, x21, x22, lsl 0x3
    ldr x22, [x22]
    str x22, [sp, L1_TTE]
    and x0, x22, ARM_TTE_TABLE_MASK
    ldr x22, [x27, PHYSTOKV]
    blr x22
    mov x22, x0
    lsr x23, x19, ARM_TT_L2_SHIFT
    and x23, x23, 0x7ff
    add x23, x22, x23, lsl 0x3
    ldr x23, [x23]
    str x23, [sp, L2_TTE]
    and x0, x23, ARM_TTE_TABLE_MASK
    ldr x22, [x27, PHYSTOKV]
    blr x22
    mov x22, x0
    lsr x23, x19, ARM_TT_L3_SHIFT
    and x23, x23, 0x7ff
    add x23, x22, x23, lsl 0x3

    ; X23 == pointer to PTE for this page
    ldr x24, [x23]
    str x24, [sp, L3_PTE]

    ; ~(ARM_PTE_PNXMASK | ARM_PTE_NXMASK)
    mov x25, 0xff9fffffffffffff
    ; XXX contiguous hint prevents us from executing the code when we've
    ; turned off XN and PXN??
    ; ~(ARM_PTE_PNXMASK | ARM_PTE_NXMASK | ARM_PTE_HINT_MASK)
    ; mov x25, 0xff8fffffffffffff
    and x24, x24, x25
    str x24, [x27, NEW_PTE_SPACE]

    ; save original PTE contents for comparing later
    mov x26, x23
    ldr x25, [x26]

    mov x0, x23
    ldr x23, [x27, KVTOPHYS]
    blr x23
    mov x24, x0

    add x0, x27, NEW_PTE_SPACE
    blr x23

    ; X0 == pa of NEW_PTE_SPACE
    mov x1, x24
    mov w2, 0x8
    ldr x23, [x27, BCOPY_PHYS]
    blr x23

    dsb ish
    isb sy
    ; ldr x0, [x27, XNUSPY_CTL_CODESTART]
    mov x0, x19
    ldr w1, [x27, XNUSPY_CTL_CODESZ]
    ldr x23, [x27, FLUSH_MMU_TLB_REGION]
    blr x23

    ; dmb ish
    ; dsb ish
    ; dsb sy

    ; tlbi vmalle1is
    ; dsb ish
    ; isb sy
    ; dmb ish
    ; dsb ish
    ; isb sy


    ; X1 == L1 tte
    ldr x1, [sp, L1_TTE]
    ; X2 == L2 tte
    ldr x2, [sp, L2_TTE]
    ; X3 == L3 pte
    ldr x3, [sp, L3_PTE]
    ; X4 == original PTE contents
    mov x4, x25
    ; X5 == (hopefully) modified PTE contents
    ldr x5, [x26]

    ; dsb sy
    ; tlbi vmalle1
    ; dsb sy
    ; isb

    ; dc cvau, x19
    ; dsb ish
    ; ic ivau, x19
    ; dsb ish
    ; isb

    ; dsb sy
    ; tlbi vmalle1
    ; XXX this below is an undefined kernel instruction
    ; tlbi vmalls12e1
    ; dsb sy
    ; isb

    ; dsb ishst
    ; tlbi vmalle1is
    ; dsb ish
    ; isb

    ; bcopy_phys succeeds on 13.6.1 a11, not 14.x a10
    ; mov x0, 0x1234
    ; mov x1, 0x5678
    ; brk 0
    ; isb
    ; dsb sy
    ; ic iallu
    ; dsb sy
    ; isb

nextpage:
    mov w22, 0x1
    add x19, x19, x22, lsl 0xe
    subs xzr, x20, x19
    b.ne pteloop

    ; dsb sy
    ; isb
    ; tlbi vmalle1
    ; dsb sy
    ; isb


    ; ldr x0, [x27, XNUSPY_CTL_CODESTART]
    ; ldr w1, [x27, XNUSPY_CTL_CODESZ]
    ; ldr x19, [x27, FLUSH_MMU_TLB_REGION]
    ; blr x19

    ; tlbi vmalle1
    ; dsb ish
    ; isb

    str x22, [x27, XNUSPY_CTL_IS_RX]
    ; fall thru

handoff:
    mov x7, x27
    ; ldp x0, x1, [sp, STACK-0x10]
    ; ldp x2, x19, [sp, STACK-0x20]
    ; ldp x20, x21, [sp, STACK-0x30]
    ; ldp x22, x23, [sp, STACK-0x40]
    ; ldp x24, x25, [sp, STACK-0x40]
    ; ldp x26, x27, [sp, STACK-0x50]
    add sp, sp, STACK
    ldr x7, [x7, XNUSPY_CTL_ENTRYPOINT]
    br x7
    ; not reached
