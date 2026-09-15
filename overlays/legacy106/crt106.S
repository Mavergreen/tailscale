/*
 * crt106.S — minimal x86_64 C runtime startup for the 10.6 floor.
 *
 * Modern toolchains (min >= 10.8) emit LC_MAIN and embed startup in
 * libclang_rt; 10.6's dyld instead requires a classic _start symbol, which
 * Apple shipped as /usr/lib/crt1.10.6.o (dropped from every modern toolchain
 * and absent from the phracker SDKs). ld searches for it by name, so we
 * assemble this into <sdk106>/usr/lib/crt1.10.6.o at build time. Apple SDK
 * bytes are never committed; neither is this needed to be theirs.
 *
 * Kernel hands _start the initial stack: [argc][argv...][NULL][envp...][NULL].
 * Go's external linker provides `main`; we align the stack per the ABI, call
 * it, and exit with its status. No keymgr/GCC-eh setup: a Go+cgo binary on
 * 10.6 uses none of it (lazy binding resolves through dyld's own helper).
 */

.text
.globl _start
.globl start
_start:
start:
    pop    %rdi                    /* argc */
    mov    %rsp, %rsi              /* argv */
    lea    8(%rsi,%rdi,8), %rdx    /* envp */
    and    $-16, %rsp
    call   _main
    mov    %eax, %edi
    call   _exit
    hlt
.subsections_via_symbols
