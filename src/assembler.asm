; ============================================
; assembler.asm - fantuan 汇编器 (跨平台版)
; 功能: 将 .fantuan 汇编源码编译为 .bin 二进制
; ============================================
; 用法:
;   assembler -c <cpu.hdr> <input.fantuan> -o <output.bin>
; ============================================

default rel

%include "config.inc"
%include "cpu_defs.inc"

; ============================================
; 常量
; ============================================
ASM_LINE_BUF_SIZE   equ 512
ASM_TOKEN_SIZE      equ 64
ASM_MAX_LABELS      equ 128
ASM_OUT_BUF_SIZE    equ 65536

; ============================================
; 导出符号
; ============================================
global _start
global assemble

; ============================================
; 外部引用
; ============================================
extern parse_cpu_header
extern find_insn_by_name
extern find_value_by_name
extern insn_table
extern insn_count
extern field_table
extern field_count
extern write_stderr

; ============================================
; BSS
; ============================================
section .bss
; 文件句柄
in_fd           resq 1
out_fd          resq 1
hdr_fd_tmp      resq 1

; 汇编行缓冲
asm_line        resb ASM_LINE_BUF_SIZE
asm_token       resb ASM_TOKEN_SIZE
asm_token2      resb ASM_TOKEN_SIZE
char_buf        resb 1
asm_pushback    resb 1          ; CRLF 回退字符
asm_has_pb      resq 1          ; 是否有回退字符

; 输出二进制缓冲
out_bin         resb ASM_OUT_BUF_SIZE
out_pos         resq 1

; 标签表
label_names     resb ASM_MAX_LABELS * 32
label_addrs     resq ASM_MAX_LABELS
label_count     resq 1

; 命令行参数 (在 .data 段，因为需要初始化为 0)
; ============================================
; DATA
; ============================================
section .data
input_path      dq 0
output_path     dq 0
cpu_path        dq 0
default_out     db "output.bin", 0
default_cpu     db "cpu.hdr", 0

err_usage       db "Usage: assembler -c <cpu.hdr> <input.fantuan> -o <output.bin>", 10, 0
err_no_cpu      db "Error: No CPU header specified", 10, 0
err_no_input    db "Error: No input file specified", 10, 0
err_open_cpu    db "Error: Cannot open CPU header", 10, 0
err_open_input  db "Error: Cannot open input file", 10, 0
err_open_out    db "Error: Cannot open output file", 10, 0
err_unknown_op  db "Error: Unknown mnemonic: ", 0
err_unknown_val db "Error: Unknown operand: ", 0
err_newline     db 10, 0
str_space       db " ", 0

; ============================================
; _start: 入口点
; ============================================
section .text
_start:
    push rbp
    mov rbp, rsp
    sub rsp, 80

    ; Linux: 从栈获取 argc/argv
    mov rax, [rbp + 8]        ; argc
    mov r12, rax
    lea r13, [rbp + 16]       ; argv

    cmp r12, 2
    jl .show_usage

    ; 解析参数
    xor r14, r14
    inc r14                   ; 跳过 argv[0]

.parse_args:
    cmp r14, r12
    jge .check_args

    mov rdi, [r13 + r14 * 8]
    inc r14

    mov al, [rdi]
    cmp al, '-'
    jne .is_input

    cmp byte [rdi + 1], 'c'
    je .opt_c
    cmp byte [rdi + 1], 'o'
    je .opt_o
    jmp .show_usage

.opt_c:
    cmp r14, r12
    jge .show_usage
    mov rdi, [r13 + r14 * 8]
    inc r14
    load_addr rbx, cpu_path
    mov [rbx], rdi
    jmp .parse_args

.opt_o:
    cmp r14, r12
    jge .show_usage
    mov rdi, [r13 + r14 * 8]
    inc r14
    load_addr rbx, output_path
    mov [rbx], rdi
    jmp .parse_args

.is_input:
    load_addr rbx, input_path
    mov [rbx], rdi
    jmp .parse_args

.check_args:
    ; 检查必需参数
    load_addr rbx, cpu_path
    mov rax, [rbx]
    test rax, rax
    jnz .has_cpu
    load_addr rax, default_cpu
    mov [rbx], rax
.has_cpu:

    load_addr rbx, input_path
    mov rax, [rbx]
    test rax, rax
    jnz .has_input
    load_addr rsi, err_no_input
    call write_stderr
    jmp .show_usage
.has_input:

    ; 默认输出路径
    load_addr rbx, output_path
    mov rax, [rbx]
    test rax, rax
    jnz .has_output
    load_addr rax, default_out
    mov [rbx], rax
.has_output:

    ; ============================================
    ; Step 1: 解析 CPU 头文件
    ; ============================================
    load_addr rbx, cpu_path
    mov rdi, [rbx]
    call parse_cpu_header
    test rax, rax
    jnz .err_cpu

    ; ============================================
    ; Step 2: 汇编
    ; ============================================
    load_addr rbx, input_path
    mov rdi, [rbx]
    load_addr rbx, output_path
    mov rsi, [rbx]
    call assemble
    test rax, rax
    jnz .err_asm

    ; 成功
    xor rdi, rdi
    sys_exit

.err_cpu:
    load_addr rsi, err_open_cpu
    call write_stderr
    mov rdi, 1
    sys_exit

.err_asm:
    mov rdi, 1
    sys_exit

.show_usage:
    load_addr rsi, err_usage
    call write_stderr
    mov rdi, 1
    sys_exit

; ============================================
; assemble: 主汇编函数
; 输入: rdi = 输入 .fantuan 文件路径, rsi = 输出 .bin 文件路径
; 输出: rax = 0 成功, -1 失败
; ============================================
assemble:
    push rbp
    mov rbp, rsp
    sub rsp, 64
    push r12
    push r13
    push r14

    mov r12, rdi           ; r12 = 输入路径
    mov r13, rsi           ; r13 = 输出路径

    ; 初始化
    load_addr rbx, out_pos
    mov qword [rbx], 0
    load_addr rbx, label_count
    mov qword [rbx], 0

    ; 打开输入文件
    mov rdi, r12
    xor rsi, rsi           ; O_RDONLY
    xor rdx, rdx
    sys_open
    test rax, rax
    js .error
    load_addr rbx, in_fd
    mov [rbx], rax

    ; 打开输出文件
    mov rdi, r13
    mov rsi, 0x241         ; O_WRONLY | O_CREAT | O_TRUNC
    mov rdx, 0644o
    sys_open
    test rax, rax
    js .error_out
    load_addr rbx, out_fd
    mov [rbx], rax

    ; ============================================
    ; Pass 1: 逐行汇编
    ; ============================================
.asm_loop:
    call read_asm_line
    test rax, rax
    jz .pass_done           ; EOF
    js .pass_done

    ; 跳过空行和注释
    load_addr rsi, asm_line
    mov al, [rsi]
    cmp al, 0
    je .asm_loop
    cmp al, ';'
    je .asm_loop
    cmp al, 10
    je .asm_loop

    ; 检查标签 (以 : 结尾的标识符)
    call parse_label
    cmp rax, 0
    jne .asm_loop           ; 是标签行，已处理

    ; 解析助记符
    load_addr rsi, asm_line
    load_addr rdi, asm_token
    call get_asm_token
    mov r10, rax            ; 保存更新后的行位置 (用于操作数解析)

    load_addr rsi, asm_token
    mov al, [rsi]
    cmp al, 0
    je .asm_loop            ; 空 token，跳过

    ; 查找指令
    mov rdi, rsi            ; rdi = 助记符
    call find_insn_by_name
    test rax, rax
    jnz .insn_found

    ; 未知助记符
    load_addr rsi, err_unknown_op
    call write_stderr
    load_addr rsi, asm_token
    call write_stderr
    load_addr rsi, err_newline
    call write_stderr
    jmp .asm_loop

.insn_found:
    mov r14, rax            ; r14 = 指令条目指针

    ; 获取操作数数量和字段列表
    xor r15, r15
    mov r15b, [r14 + INSN_OPCOUNT_OFF]

    ; 打包指令位
    ; 起始值 = pattern
    mov rax, [r14 + INSN_PATTERN_OFF]
    push rax                ; [rsp] = 累积的指令字

    ; 恢复操作数解析的起始位置
    mov rsi, r10            ; r10 = get_asm_token 返回的行位置

    ; 处理每个操作数
    xor r12, r12            ; r12 = 操作数索引
.op_loop:
    cmp r12, r15
    jge .emit_insn

    ; 获取字段索引
    mov al, [r14 + INSN_OPS_OFF + r12]
    cmp al, MAX_FIELDS
    jae .skip_op

    ; 获取字段条目指针
    movzx rax, al
    load_addr rbx, field_table
    imul rax, FIELD_ENTRY_SIZE
    add rbx, rax            ; rbx = 字段条目

    ; 解析操作数 token
    push rsi
    push rdi
    load_addr rdi, asm_token2
    call get_asm_token      ; 从当前 rsi 位置解析操作数
    mov r8, rax             ; r8 = 更新后的 rsi (下一个操作数位置)
    pop rdi
    pop rsi

    ; 检查是否是立即数字段
    cmp byte [rbx + FIELD_IS_IMM_OFF], 0
    jne .parse_immediate

    ; 查找命名值
    push r8
    load_addr rsi, asm_token2
    mov rdi, rbx
    call find_value_by_name
    pop r8

    cmp rax, -1
    je .err_val

    ; 将值移到正确的位位置
    xor rcx, rcx
    mov cl, [rbx + FIELD_SHIFT_OFF]
    shl rax, cl

    ; OR 到指令字中
    pop rdx                 ; rdx = 当前指令字
    or rdx, rax
    push rdx                ; 保存更新后的指令字
    jmp .next_op

.parse_immediate:
    ; 解析十进制或十六进制立即数
    push r8
    load_addr rsi, asm_token2
    call parse_number
    pop r8

    xor rcx, rcx
    mov cl, [rbx + FIELD_SHIFT_OFF]
    shl rax, cl

    pop rdx
    or rdx, rax
    push rdx
    jmp .next_op

.err_val:
    ; 未知操作数值，作为立即数尝试
    push r8
    load_addr rsi, asm_token2
    call parse_number
    pop r8
    cmp rax, -1
    je .skip_op

    xor rcx, rcx
    mov cl, [rbx + FIELD_SHIFT_OFF]
    shl rax, cl

    pop rdx
    or rdx, rax
    push rdx
    jmp .next_op

.skip_op:
    add rsp, 8              ; 弹出指令字
    jmp .next_op_skip

.next_op:
    mov rsi, r8             ; rsi = 下一个操作数位置
.next_op_skip:
    inc r12
    jmp .op_loop

.emit_insn:
    ; 弹出最终指令字
    pop rax                 ; rax = 打包后的指令

    ; 写入输出缓冲
    load_addr rbx, out_pos
    load_addr rcx, out_bin
    mov rdx, [rbx]
    mov [rcx + rdx], al     ; 写入低字节
    inc qword [rbx]

    jmp .asm_loop

.pass_done:
    ; ============================================
    ; 写入输出文件
    ; ============================================
    load_addr rbx, out_pos
    mov rdx, [rbx]
    test rdx, rdx
    jz .done

    load_addr rbx, out_fd
    mov rdi, [rbx]
    load_addr rsi, out_bin
    sys_write

.done:
    ; 关闭文件
    load_addr rbx, in_fd
    mov rdi, [rbx]
    sys_close

    load_addr rbx, out_fd
    mov rdi, [rbx]
    sys_close

    xor rax, rax
    jmp .exit

.error:
    mov rax, -1
    jmp .exit

.error_out:
    load_addr rbx, in_fd
    mov rdi, [rbx]
    sys_close
    mov rax, -1

.exit:
    pop r14
    pop r13
    pop r12
    leave
    ret

; ============================================
; read_asm_line: 从输入读取一行汇编源码
; 输出: rax = 行长度 (0 = EOF)
; ============================================
read_asm_line:
    push rbp
    mov rbp, rsp
    push r12
    sub rsp, 32

    ; 清空行缓冲
    load_addr rdi, asm_line
    mov rcx, ASM_LINE_BUF_SIZE
    xor rax, rax
    rep stosb

    xor r12, r12
.read_loop:
    ; 检查回退字符
    load_addr rbx, asm_has_pb
    cmp qword [rbx], 0
    jz .do_read
    load_addr rbx, asm_pushback
    mov al, [rbx]
    load_addr rcx, asm_has_pb
    mov qword [rcx], 0
    jmp .have_char

.do_read:
    load_addr rbx, in_fd
    mov rdi, [rbx]
    load_addr rsi, char_buf
    mov rdx, 1
    sys_read

    test rax, rax
    jz .eof
    js .eof

    load_addr rbx, char_buf
    mov al, [rbx]

.have_char:
    cmp al, 10
    je .line_end
    cmp al, 13
    je .line_end_cr

    load_addr rbx, asm_line
    mov [rbx + r12], al
    inc r12
    cmp r12, ASM_LINE_BUF_SIZE - 2
    jl .read_loop

.line_end_cr:
    ; CR 读取 — 尝试消费后续的 LF
    load_addr rbx, in_fd
    mov rdi, [rbx]
    load_addr rsi, char_buf
    mov rdx, 1
    sys_read
    test rax, rax
    jz .line_end_cr_done
    js .line_end_cr_done
    load_addr rbx, char_buf
    mov al, [rbx]
    cmp al, 10               ; LF？
    je .line_end             ; 是 LF，已消费
    ; 不是 LF — 保存为回退字符
    load_addr rbx, asm_pushback
    mov [rbx], al
    load_addr rbx, asm_has_pb
    mov qword [rbx], 1
.line_end_cr_done:

.line_end:
    load_addr rbx, asm_line
    mov byte [rbx + r12], 0
    mov rax, r12
    jmp .exit

.eof:
    xor rax, rax

.exit:
    add rsp, 32
    pop r12
    leave
    ret

; ============================================
; get_asm_token: 从行中提取下一个 token
; 输入: rsi = 源字符串, rdi = 目标缓冲
; 输出: rax = 更新后的源指针
; ============================================
get_asm_token:
    push rbp
    mov rbp, rsp
    sub rsp, 32

    cmp rdi, 0
    je .exit
    mov byte [rdi], 0
    cmp rsi, 0
    je .exit

    ; 跳过前导空格
.skip:
    mov al, [rsi]
    cmp al, 0
    je .exit
    cmp al, ' '
    je .skip_inc
    cmp al, 9
    je .skip_inc
    cmp al, ','
    je .skip_inc
    jmp .copy

.skip_inc:
    inc rsi
    jmp .skip

    ; 复制 token
.copy:
    mov [rdi], al
    inc rdi
    inc rsi
    mov al, [rsi]

    cmp al, 0
    je .done
    cmp al, ' '
    je .done
    cmp al, 9
    je .done
    cmp al, ','
    je .done
    cmp al, 10
    je .done
    cmp al, 13
    je .done

    jmp .copy

.done:
    mov byte [rdi], 0

    ; 跳过结尾逗号
    cmp al, ','
    jne .exit
    inc rsi

.exit:
    mov rax, rsi
    leave
    ret

; ============================================
; parse_label: 检查并解析标签 (简化版)
; 输出: rax = 0 不是标签, 非0 = 处理了标签行
; ============================================
parse_label:
    push rbp
    mov rbp, rsp
    push rbx

    load_addr rsi, asm_line
    ; 跳过前导空格
.skip_sp:
    mov al, [rsi]
    cmp al, ' '
    jne .check
    inc rsi
    jmp .skip_sp
.check:
    ; 找冒号
    xor rbx, rbx
.find:
    mov al, [rsi + rbx]
    cmp al, 0
    je .not_label
    cmp al, ':'
    je .is_label
    inc rbx
    cmp rbx, 64
    jl .find
    jmp .not_label

.is_label:
    test rbx, rbx
    jz .not_label
    ; 记录标签地址
    load_addr rcx, label_count
    mov rax, [rcx]
    cmp rax, ASM_MAX_LABELS
    jge .done_label
    
    ; 存储标签地址 = 当前 out_pos
    load_addr rdx, out_pos
    mov rdx, [rdx]
    load_addr rcx, label_addrs
    mov [rcx + rax * 8], rdx
    load_addr rcx, label_count
    inc qword [rcx]

.done_label:
    mov rax, 1            ; 表示处理了标签
    jmp .exit

.not_label:
    xor rax, rax

.exit:
    pop rbx
    leave
    ret

; ============================================
; parse_number: 解析十进制或十六进制数字
; 输入: rsi = 数字字符串
; 输出: rax = 数值, -1 = 解析失败
; ============================================
parse_number:
    push rbp
    mov rbp, rsp
    push rbx

    xor rax, rax
    mov bl, [rsi]
    test bl, bl
    jz .fail

    ; 检查 0x 前缀
    cmp word [rsi], '0x'
    je .parse_hex
    cmp word [rsi], '0X'
    je .parse_hex

    ; 十进制
.parse_dec:
    mov bl, [rsi]
    test bl, bl
    jz .done
    cmp bl, '0'
    jb .done
    cmp bl, '9'
    ja .done
    imul rax, 10
    sub bl, '0'
    add al, bl
    inc rsi
    jmp .parse_dec

.parse_hex:
    add rsi, 2             ; 跳过 0x
.hex_loop:
    mov bl, [rsi]
    test bl, bl
    jz .done
    cmp bl, '0'
    jb .done
    cmp bl, '9'
    jbe .hex_digit
    cmp bl, 'A'
    jb .done
    cmp bl, 'F'
    jbe .hex_upper
    cmp bl, 'a'
    jb .done
    cmp bl, 'f'
    jbe .hex_lower
    jmp .done

.hex_digit:
    shl rax, 4
    sub bl, '0'
    or al, bl
    inc rsi
    jmp .hex_loop

.hex_upper:
    shl rax, 4
    sub bl, 'A'
    add bl, 10
    or al, bl
    inc rsi
    jmp .hex_loop

.hex_lower:
    shl rax, 4
    sub bl, 'a'
    add bl, 10
    or al, bl
    inc rsi
    jmp .hex_loop

.fail:
    mov rax, -1

.done:
    pop rbx
    leave
    ret
