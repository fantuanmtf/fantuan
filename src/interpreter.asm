; ============================================
; interpreter.asm - NTF 虚拟 CPU 解释器
; 用法: ntfrun <program.bin>
; ============================================

default rel
%include "config.inc"

PROG_MAX_SIZE   equ 65536
STACK_SIZE      equ 256

section .bss
prog_buf        resb PROG_MAX_SIZE
prog_size       resq 1
prog_fd         resq 1
v_ax            resq 1
v_bx            resq 1
v_cx            resq 1
v_dx            resq 1
v_pc            resq 1
v_sp            resq 1
v_zf            resb 1
v_stack         resb STACK_SIZE
char_buf        resb 1

section .data
err_usage       db "Usage: ntfrun <program.bin>", 10, 0
err_open        db "Error: Cannot open program file", 10, 0
err_read        db "Error: Cannot read program file", 10, 0
err_halt        db "CPU Halted.", 10, 0

extern write_stderr

section .text
; ---- 入口 ----
global _start
_start:
    push rbp
    mov rbp, rsp
    mov rax, [rbp+8]
    lea r13, [rbp+16]
    cmp rax, 2
    jl usage

    mov rdi, [r13+8]
    xor rsi, rsi
    xor rdx, rdx
    sys_open
    test rax, rax
    js err_open_prog
    mov [prog_fd], rax

    mov rdi, rax
    load_addr rsi, prog_buf
    mov rdx, PROG_MAX_SIZE
    sys_read
    test rax, rax
    js err_read_prog
    mov [prog_size], rax

    mov rdi, [prog_fd]
    sys_close

    mov qword [v_ax], 0
    mov qword [v_bx], 0
    mov qword [v_cx], 0
    mov qword [v_dx], 0
    mov qword [v_pc], 0
    mov qword [v_sp], STACK_SIZE

fetch:
    mov r12, [v_pc]
    cmp r12, [prog_size]
    jge halt

    xor rax, rax
    mov al, [prog_buf + r12]
    mov r13, rax
    inc qword [v_pc]

    mov r14, r13
    shr r14, 4
    cmp r14, 0
    je do_nop
    cmp r14, 1
    je do_mov
    cmp r14, 2
    je do_add
    cmp r14, 3
    je do_sub
    cmp r14, 4
    je do_mul
    cmp r14, 5
    je do_inc
    cmp r14, 6
    je do_dec
    cmp r14, 7
    je do_xor
    cmp r13, 0x80
    je do_jmp
    cmp r13, 0x90
    je do_push
    cmp r13, 0xA0
    je do_pop
    jmp fetch

do_nop:
    jmp fetch

do_mov:
    mov al, r13b
    mov cl, al
    shr cl, 2
    and cl, 3
    and al, 3
    call get_vreg
    mov rdx, rax
    mov al, cl
    call set_vreg
    jmp fetch

do_add:
    mov al, r13b
    mov cl, al
    shr cl, 2
    and cl, 3
    and al, 3
    call get_vreg
    push rax
    mov al, cl
    call get_vreg
    pop rdx
    add rax, rdx
    mov rdx, rax
    mov al, cl
    call set_vreg
    jmp fetch

do_sub:
    mov al, r13b
    mov cl, al
    shr cl, 2
    and cl, 3
    and al, 3
    call get_vreg
    push rax
    mov al, cl
    call get_vreg
    pop rdx
    sub rax, rdx
    mov rdx, rax
    mov al, cl
    call set_vreg
    jmp fetch

do_mul:
    mov al, r13b
    mov cl, al
    shr cl, 2
    and cl, 3
    and al, 3
    call get_vreg
    push rax
    mov al, cl
    call get_vreg
    pop rdx
    imul rax, rdx
    mov rdx, rax
    mov al, cl
    call set_vreg
    jmp fetch

do_inc:
    mov al, r13b
    shr al, 2
    and al, 3
    call get_vreg
    inc rax
    mov rdx, rax
    call set_vreg
    jmp fetch

do_dec:
    mov al, r13b
    shr al, 2
    and al, 3
    call get_vreg
    dec rax
    mov rdx, rax
    call set_vreg
    jmp fetch

do_xor:
    mov al, r13b
    mov cl, al
    shr cl, 2
    and cl, 3
    and al, 3
    call get_vreg
    push rax
    mov al, cl
    call get_vreg
    pop rdx
    xor rax, rdx
    mov rdx, rax
    mov al, cl
    call set_vreg
    jmp fetch

do_jmp:
    mov rdx, [v_pc]
    xor rax, rax
    mov al, [prog_buf + rdx]
    mov [v_pc], rax
    jmp fetch

do_push:
    mov rdx, [v_pc]
    inc qword [v_pc]
    xor rax, rax
    mov al, [prog_buf + rdx]
    call get_vreg
    mov rdx, [v_sp]
    sub rdx, 8
    mov [v_sp], rdx
    mov [v_stack + rdx], rax
    jmp fetch

do_pop:
    mov rdx, [v_sp]
    mov rax, [v_stack + rdx]
    add rdx, 8
    mov [v_sp], rdx
    mov rdx, [v_pc]
    inc qword [v_pc]
    xor r8, r8
    mov r8b, [prog_buf + rdx]
    mov rdx, rax
    mov al, r8b
    call set_vreg
    jmp fetch

get_vreg:
    and al, 3
    cmp al, 0
    jne .g1
    mov rax, [v_ax]
    ret
.g1: cmp al, 1
    jne .g2
    mov rax, [v_bx]
    ret
.g2: cmp al, 2
    jne .g3
    mov rax, [v_cx]
    ret
.g3: mov rax, [v_dx]
    ret

set_vreg:
    and al, 3
    cmp al, 0
    jne .s1
    mov [v_ax], rdx
    ret
.s1: cmp al, 1
    jne .s2
    mov [v_bx], rdx
    ret
.s2: cmp al, 2
    jne .s3
    mov [v_cx], rdx
    ret
.s3: mov [v_dx], rdx
    ret

halt:
    load_addr rsi, err_halt
    call write_stderr
    xor rdi, rdi
    sys_exit

usage:
    load_addr rsi, err_usage
    call write_stderr
    mov rdi, 1
    sys_exit

err_open_prog:
    load_addr rsi, err_open
    call write_stderr
    mov rdi, 1
    sys_exit

err_read_prog:
    load_addr rsi, err_read
    call write_stderr
    mov rdi, 1
    sys_exit
