; ============================================
; util.asm - 共享工具函数 (write_stderr, format_hex_byte, nybble_to_hex)
; ============================================
; 被 main.asm, assembler.asm, cpuhdr.asm, decode.asm 等模块共用
; ============================================

default rel

%include "config.inc"

global write_stderr
global format_hex_byte
global nybble_to_hex

; ============================================
; BSS
; ============================================
section .bss
util_char_buf   resb 1
util_hex_buf    resb 8

; ============================================
; write_stderr: 写入 null-terminated 字符串到 stderr
; 输入: rsi = 字符串指针
; ============================================
section .text
write_stderr:
    push rbp
    mov rbp, rsp
    sub rsp, 40

    push rsi
    xor rdx, rdx
.len_loop:
    cmp byte [rsi + rdx], 0
    je .have_len
    inc rdx
    jmp .len_loop
.have_len:
    mov rax, 2              ; stderr fd
    mov rdi, rax
    sys_write
    pop rsi

    leave
    ret

; ============================================
; nybble_to_hex: 半字节转十六进制字符
; 输入: al = 0-15
; 输出: al = '0'-'9' 或 'A'-'F'
; ============================================
nybble_to_hex:
    push rbp
    mov rbp, rsp
    cmp al, 9
    jbe .digit
    add al, 'A' - 10
    jmp .exit
.digit:
    add al, '0'
.exit:
    leave
    ret

; ============================================
; format_hex_byte: 格式化字节为十六进制字符串
; 输入: rdi = 目标缓冲区 (至少 5 字节)
;        r12 = 字节值
; 输出: 写入 "0xNN\0" 到缓冲区
; ============================================
format_hex_byte:
    push rbp
    mov rbp, rsp
    push rbx

    mov [rdi], byte '0'
    mov [rdi+1], byte 'x'
    mov [rdi+4], byte 0

    mov al, r12b
    shr al, 4
    call nybble_to_hex
    mov [rdi+2], al

    mov al, r12b
    and al, 0x0F
    call nybble_to_hex
    mov [rdi+3], al

    pop rbx
    leave
    ret
