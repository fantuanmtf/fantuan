; ============================================
; input.asm - 多格式输入解析器 (跨平台版)
; ============================================
; 功能: 支持三种输入格式:
;   1. 原始二进制 (.bin) - 直接读取字节流
;   2. 十六进制文本 (.hex) - Intel HEX 或纯十六进制
;   3. 旧版文本 (.01) - 兼容旧格式
;
; 导出的函数:
;   open_input(rdi=路径, rsi=格式标志) → rax=0(成功)/-1(失败)
;   read_next_byte() → rax=字节值 (高位=0), rax=-1 (EOF)
;   get_input_format() → rax=格式代码
;   close_input()
;
; 格式标志:
;   INPUT_FMT_BIN  = 0  (二进制)
;   INPUT_FMT_HEX  = 1  (十六进制文本)
;   INPUT_FMT_TEXT = 2  (旧版 .01 文本)
;   INPUT_FMT_AUTO = 3  (自动检测)
; ============================================

default rel

%include "config.inc"

; ============================================
; 导出符号
; ============================================
global open_input
global read_next_byte
global get_input_format
global close_input
global input_format
global input_byte_count

global INPUT_FMT_BIN
global INPUT_FMT_HEX
global INPUT_FMT_TEXT
global INPUT_FMT_AUTO

; ============================================
; 常量
; ============================================
INPUT_FMT_BIN  equ 0
INPUT_FMT_HEX  equ 1
INPUT_FMT_TEXT equ 2
INPUT_FMT_AUTO equ 3

INPUT_BUF_SIZE equ 4096

; DEBUG strings (only for debugging)
section .data
debug_open_input_entry db "DEBUG: entered open_input", 10, 0
debug_refill_start db "DEBUG: refill called", 10, 0
debug_refill_ok db "DEBUG: refill OK", 10, 0
debug_refill_fail db "DEBUG: refill FAIL/EOF", 10, 0
debug_read_bin_entry db "DEBUG: read_from_bin entry", 10, 0
debug_read_bin_have db "DEBUG: read_from_bin have_data", 10, 0
debug_read_bin_eof db "DEBUG: read_from_bin EOF", 10, 0
debug_read_bin_byte db "DEBUG: byte=0x", 0
debug_newline db 10, 0
debug_hex_chars db "0123456789ABCDEF", 0
debug_tmp_byte_str db "XX", 10, 0   ; 2 hex chars + newline + null

extern write_stderr

HEX_LINE_BUF   equ 256

; ============================================
; BSS
; ============================================
section .bss
input_fd        resq 1           ; 输入文件句柄
input_format    resq 1           ; 当前输入格式
input_byte_count resq 1          ; 已读取的字节数
input_buf       resb INPUT_BUF_SIZE  ; 原始二进制缓冲区
input_buf_pos   resq 1           ; 缓冲区当前位置
input_buf_end   resq 1           ; 缓冲区有效数据结尾
hex_line_buf    resb HEX_LINE_BUF    ; 十六进制行缓冲区
char_buf        resb 1
input_pushback  resb 1          ; CRLF 回退字符
input_has_pb    resq 1          ; 是否有回退字符

; 旧版文本解析状态
text_line_buf   resb 256
text_token_buf  resb 64
text_token2     resb 64
text_token3     resb 64
text_state      resq 1           ; 0=读行, 1=从行中读字节

section .text

; ============================================
; open_input: 打开并准备输入文件
; 输入: rdi = 文件路径, rsi = 格式标志
; 输出: rax = 0 (成功), -1 (失败)
; ============================================
open_input:
    push rbp
    mov rbp, rsp
    sub rsp, 56
    push r12

    ; DEBUG
    push rdi
    push rsi
    push rax
%ifdef DEBUG
    load_addr rsi, debug_open_input_entry
    call write_stderr
%endif
    pop rax
    pop rsi
    pop rdi

    mov r12, rsi         ; 保存格式标志

    ; 打开文件
    xor rsi, rsi         ; O_RDONLY
    xor rdx, rdx
    sys_open
    test rax, rax
    js .error

    load_addr rbx, input_fd
    mov [rbx], rax

    ; 确定格式
    mov rax, r12
    cmp rax, INPUT_FMT_AUTO
    jne .set_format

    ; 自动检测: 根据文件扩展名
    mov rdi, [rbx]       ; 但我们需要文件名... 
    ; 简化: 默认使用二进制格式，后续可通过读取前几个字节判断
    mov rax, INPUT_FMT_BIN

.set_format:
    load_addr rbx, input_format
    mov [rbx], rax

    ; 初始化状态
    load_addr rbx, input_byte_count
    mov qword [rbx], 0
    load_addr rbx, input_buf_pos
    mov qword [rbx], 0
    load_addr rbx, input_buf_end
    mov qword [rbx], 0
    load_addr rbx, text_state
    mov qword [rbx], 0

    ; 如果是二进制格式，预加载缓冲区
    cmp rax, INPUT_FMT_BIN
    jne .done

    call refill_input_buffer

.done:
    xor rax, rax
    jmp .exit

.error:
    mov rax, -1

.exit:
    pop r12
    leave
    ret

; ============================================
; read_next_byte: 读取下一个字节
; 输出: rax = 字节值 (0-255), -1 (EOF)
; ============================================
read_next_byte:
    push rbp
    mov rbp, rsp
    sub rsp, 32

    load_addr rbx, input_format
    mov rax, [rbx]

    cmp rax, INPUT_FMT_BIN
    je .read_bin

    cmp rax, INPUT_FMT_HEX
    je .read_hex

    cmp rax, INPUT_FMT_TEXT
    je .read_text

    ; 默认二进制
    jmp .read_bin

; --- 二进制格式读取 ---
.read_bin:
    call read_from_binary_buffer
    jmp .exit

; --- 十六进制格式读取 ---
.read_hex:
    call read_hex_byte
    jmp .exit

; --- 旧版文本格式读取 ---
.read_text:
    call read_text_byte
    jmp .exit

.exit:
    ; 更新字节计数 (如果 rax != -1)
    cmp rax, -1
    je .done
    load_addr rbx, input_byte_count
    inc qword [rbx]

.done:
    leave
    ret

; ============================================
; 二进制缓冲区读取
; ============================================
read_from_binary_buffer:
    push rbp
    mov rbp, rsp
    sub rsp, 32
    push r12

    ; DEBUG
    push rsi
%ifdef DEBUG
    load_addr rsi, debug_read_bin_entry
    call write_stderr
%endif
    pop rsi

    ; 检查缓冲区是否为空
    load_addr rbx, input_buf_pos
    mov rax, [rbx]
    load_addr rcx, input_buf_end
    mov rcx, [rcx]
    cmp rax, rcx
    jl .have_data

    ; 重新填充缓冲区
    call refill_input_buffer
    cmp rax, 0
    je .eof               ; 没有更多数据

.have_data:
    ; 从缓冲区读取一个字节
    load_addr rbx, input_buf
    load_addr rcx, input_buf_pos
    mov rdx, [rcx]
    xor rax, rax
    mov al, [rbx + rdx]
    inc qword [rcx]       ; input_buf_pos++

    ; DEBUG: 输出读取的字节值到 stderr (十六进制)
    push rax              ; 字节值保存到栈 [rsp+0]
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi              ; 现在字节值在 [rsp+40] (6次push后)
    ; 输出 "DEBUG: byte=0x"
%ifdef DEBUG
    load_addr rsi, debug_read_bin_byte
    call write_stderr
%endif
    ; 从栈中恢复字节值 ([rsp+40] 处), 避免使用易失性寄存器 r8
    ; 高4位
    mov rax, [rsp + 40]
    shr al, 4
    and al, 0x0F
    movzx rcx, al
    load_addr rbx, debug_hex_chars
    mov al, [rbx + rcx]
%ifdef DEBUG
    load_addr rsi, debug_tmp_byte_str
    mov [rsi], al
    ; 低4位
    mov rax, [rsp + 40]
    and al, 0x0F
    movzx rcx, al
    load_addr rbx, debug_hex_chars
    mov al, [rbx + rcx]
    load_addr rsi, debug_tmp_byte_str
    mov [rsi + 1], al
    mov byte [rsi + 2], 10
    mov byte [rsi + 3], 0
    call write_stderr
%endif
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax               ; 恢复原始字节值

    pop r12
    leave
    ret

.eof:
    ; DEBUG
    push rsi
%ifdef DEBUG
    load_addr rsi, debug_read_bin_eof
    call write_stderr
%endif
    pop rsi

    mov rax, -1
    pop r12
    leave
    ret

; ============================================
; refill_input_buffer: 从文件填充输入缓冲区
; 输出: rax = 读取的字节数 (0 = EOF)
; ============================================
refill_input_buffer:
    push rbp
    mov rbp, rsp
    sub rsp, 32

    ; DEBUG
    push rsi
%ifdef DEBUG
    load_addr rsi, debug_refill_start
    call write_stderr
%endif
    pop rsi

    ; sys_read(rdi=input_fd, rsi=input_buf, rdx=INPUT_BUF_SIZE)
    load_addr rbx, input_fd
    mov rdi, [rbx]
    load_addr rsi, input_buf
    mov rdx, INPUT_BUF_SIZE
    sys_read

    test rax, rax
    js .error
    jz .eof

    ; DEBUG
    push rsi
    push rax
%ifdef DEBUG
    load_addr rsi, debug_refill_ok
    call write_stderr
%endif
    pop rax
    pop rsi

    ; 更新缓冲区指针
    load_addr rbx, input_buf_pos
    mov qword [rbx], 0
    load_addr rbx, input_buf_end
    mov [rbx], rax

    leave
    ret

.error:
.eof:
    ; DEBUG
    push rsi
%ifdef DEBUG
    load_addr rsi, debug_refill_fail
    call write_stderr
%endif
    pop rsi

    xor rax, rax
    leave
    ret

; ============================================
; 十六进制格式读取
; 逐行读取十六进制文本，每两个十六进制字符=1字节
; 支持格式:
;   "FF 20 40" (空格分隔)
;   "FF204060" (连续十六进制)
;   ":10000000FF204060..." (Intel HEX - 简化处理)
; ============================================
read_hex_byte:
    push rbp
    mov rbp, rsp
    sub rsp, 32
    push r12
    push r13

    ; 使用静态变量跟踪十六进制解析状态
    load_addr r12, hex_state_pos
    load_addr r13, hex_state_count

    ; 如果当前行已耗尽，读取新行
    mov rax, [r12]          ; hex_state_pos
    mov rcx, [r13]          ; hex_state_count
    cmp rax, rcx
    jl .have_hex_data

    ; 读取新行
    call read_hex_line
    test rax, rax
    jz .eof

    ; 重置位置并设置行长度
    mov qword [r12], 0       ; hex_state_pos = 0
    mov [r13], rax           ; hex_state_count = line_length

.have_hex_data:
    ; 从 hex_line_buf 读取两个十六进制字符
    load_addr rbx, hex_line_buf
    mov rdx, [r12]          ; 当前位置

    ; 跳过空格
.skip_spaces:
    mov al, [rbx + rdx]
    cmp al, ' '
    jne .check_digit
    inc rdx
    jmp .skip_spaces

.check_digit:
    cmp al, 0
    je .eof
    cmp al, 10
    je .eof
    cmp al, 13
    je .eof
    cmp al, ':'
    je .skip_intel_hex

    ; 读取第一个十六进制字符
    mov cl, al
    inc rdx

    ; 读取第二个十六进制字符
    mov al, [rbx + rdx]
    cmp al, ' '
    je .single_digit      ; 单个十六进制字符后跟空格
    cmp al, 0
    je .single_digit
    cmp al, 10
    je .single_digit

    ; 两个字符
    mov ch, al
    inc rdx

    ; 转换第一个字符
    mov al, cl
    call hex_to_val
    shl al, 4
    mov cl, al

    ; 转换第二个字符
    mov al, ch
    call hex_to_val
    or al, cl

    ; 更新位置
    mov [r12], rdx

    pop r13
    pop r12
    leave
    ret

.single_digit:
    ; 只有一个有效十六进制字符
    mov al, cl
    call hex_to_val
    mov [r12], rdx

    pop r13
    pop r12
    leave
    ret

.skip_intel_hex:
    ; 跳过 Intel HEX 行 (以 : 开头)
    ; 直接跳到行尾
    inc rdx
.check_eol:
    mov al, [rbx + rdx]
    cmp al, 0
    je .end_of_line
    cmp al, 10
    je .end_of_line
    cmp al, 13
    je .end_of_line
    inc rdx
    jmp .check_eol
.end_of_line:
    mov [r12], rdx
    ; 重新读取
    jmp .have_hex_data

.eof:
    mov rax, -1
    pop r13
    pop r12
    leave
    ret

; ============================================
; read_hex_line: 读取一行十六进制文本
; 输出: rax = 行长度 (0 = EOF)
; ============================================
read_hex_line:
    push rbp
    mov rbp, rsp
    push r12
    sub rsp, 32

    ; 清空行缓冲区
    load_addr rdi, hex_line_buf
    mov rcx, HEX_LINE_BUF
    xor rax, rax
    rep stosb

    xor r12, r12
.read_loop:
    ; 检查回退字符
    load_addr rbx, input_has_pb
    cmp qword [rbx], 0
    jz .do_read
    load_addr rbx, input_pushback
    mov al, [rbx]
    load_addr rcx, input_has_pb
    mov qword [rcx], 0
    jmp .have_char

.do_read:
    load_addr rbx, input_fd
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

    load_addr rbx, hex_line_buf
    mov [rbx + r12], al
    inc r12
    cmp r12, HEX_LINE_BUF - 2
    jl .read_loop

.line_end_cr:
    ; CR 读取 — 尝试消费后续 LF
    load_addr rbx, input_fd
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
    load_addr rbx, input_pushback
    mov [rbx], al
    load_addr rbx, input_has_pb
    mov qword [rbx], 1
.line_end_cr_done:

.line_end:
    load_addr rbx, hex_line_buf
    mov byte [rbx + r12], 0
    mov rax, r12
    jmp .exit

.eof:
    xor rax, rax

.exit:
    add rsp, 32
    pop r12
    pop rbp
    ret

; ============================================
; 旧版文本格式读取 (.01)
; 每行格式: <5位二进制操作码> [操作数1 [操作数2]]
; 需要将文本解析为等效的二进制字节
; ============================================
read_text_byte:
    push rbp
    mov rbp, rsp
    sub rsp, 32
    push r12
    push r13

    load_addr r12, text_state
    mov rax, [r12]
    cmp rax, 0
    jne .from_existing_line

    ; 读取新行
    call read_text_line
    test rax, rax
    jz .eof

    ; 解析操作码 (5位二进制)
    load_addr rsi, text_line_buf
    call parse_binary_5bit
    ; rax = 0-31 的数值
    ; 转换为我们的格式: 将 5-bit opcode 放在高5位
    shl al, 5

    ; 存储到 text_token_buf 作为操作码字节
    load_addr rbx, text_byte_buf
    mov [rbx], al
    mov qword [r12], 1      ; text_state = 1 (有操作码字节待读取)
    load_addr rbx, text_op_count
    mov qword [rbx], 0      ; 操作数计数器

    ; 读取操作数
    call parse_text_operands

    ; 返回操作码字节
    mov al, [text_byte_buf]

    pop r13
    pop r12
    leave
    ret

.from_existing_line:
    ; 从已解析的行返回下一个操作数字节
    load_addr rbx, text_op_count
    mov rax, [rbx]
    cmp rax, 2
    jge .next_line         ; 操作数已耗尽

    ; 返回操作数字节 (从 text_op_buf 读取)
    load_addr rbx, text_op_buf
    load_addr rcx, text_op_index
    mov rcx, [rcx]
    mov al, [rbx + rcx]
    load_addr rbx, text_op_index
    inc qword [rbx]
    load_addr rbx, text_op_count
    inc qword [rbx]

    pop r13
    pop r12
    leave
    ret

.next_line:
    mov qword [r12], 0     ; text_state = 0 (读取下一行)
    ; 递归调用自己，读取下一行
    jmp read_text_byte

.eof:
    mov rax, -1
    pop r13
    pop r12
    leave
    ret

; ============================================
; read_text_line: 读取一行 .01 格式文本
; ============================================
read_text_line:
    push rbp
    mov rbp, rsp
    push r12
    sub rsp, 32

    load_addr rdi, text_line_buf
    mov rcx, 256
    xor rax, rax
    rep stosb

    xor r12, r12
.read_loop:
    ; 检查回退字符
    load_addr rbx, input_has_pb
    cmp qword [rbx], 0
    jz .do_read
    load_addr rbx, input_pushback
    mov al, [rbx]
    load_addr rcx, input_has_pb
    mov qword [rcx], 0
    jmp .have_char

.do_read:
    load_addr rbx, input_fd
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

    load_addr rbx, text_line_buf
    mov [rbx + r12], al
    inc r12
    cmp r12, 254
    jl .read_loop

.line_end_cr:
    ; CR 读取 — 尝试消费后续 LF
    load_addr rbx, input_fd
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
    load_addr rbx, input_pushback
    mov [rbx], al
    load_addr rbx, input_has_pb
    mov qword [rbx], 1
.line_end_cr_done:

.line_end:
    load_addr rbx, text_line_buf
    mov byte [rbx + r12], 0
    mov rax, r12
    jmp .exit

.eof:
    xor rax, rax

.exit:
    add rsp, 32
    pop r12
    pop rbp
    ret

; ============================================
; parse_binary_5bit: 解析 5 位二进制字符串
; 输入: rsi = 指向 "00000" 格式的字符串
; 输出: al = 0-31 的数值
; ============================================
parse_binary_5bit:
    push rbp
    mov rbp, rsp
    xor rax, rax
    mov rcx, 5
.loop:
    shl al, 1
    mov bl, [rsi]
    cmp bl, '1'
    jne .zero
    or al, 1
.zero:
    inc rsi
    loop .loop
    leave
    ret

; ============================================
; parse_text_operands: 解析旧版操作数
; 从 text_line_buf 中提取操作数 token
; 结果存入 text_op_buf
; ============================================
parse_text_operands:
    push rbp
    mov rbp, rsp
    sub rsp, 32
    push r12

    load_addr r12, text_op_buf
    mov qword [text_op_index], 0

    ; 跳过操作码 (前5个字符 + 空格)
    load_addr rsi, text_line_buf
    ; 跳过5位二进制
    add rsi, 5
    ; 跳过空格
.skip_spaces:
    mov al, [rsi]
    cmp al, ' '
    jne .parse_op1
    inc rsi
    jmp .skip_spaces

.parse_op1:
    cmp al, 0
    je .done
    cmp al, 10
    je .done
    ; 简化: 操作数直接复制到 op_buf
    ; 实际使用中，操作数会被 decode.asm 进一步处理
    xor rcx, rcx
.copy_op1:
    mov al, [rsi + rcx]
    cmp al, ' '
    je .done_op1
    cmp al, 0
    je .done_op1
    cmp al, 10
    je .done_op1
    mov [r12 + rcx], al
    inc rcx
    jmp .copy_op1
.done_op1:
    mov byte [r12 + rcx], 0
    add r12, 64
    add rsi, rcx

    ; 跳过空格
.skip_spaces2:
    mov al, [rsi]
    cmp al, ' '
    jne .parse_op2
    inc rsi
    jmp .skip_spaces2

.parse_op2:
    cmp al, 0
    je .done
    cmp al, 10
    je .done
    xor rcx, rcx
.copy_op2:
    mov al, [rsi + rcx]
    cmp al, ' '
    je .done_op2
    cmp al, 0
    je .done_op2
    cmp al, 10
    je .done_op2
    mov [r12 + rcx], al
    inc rcx
    jmp .copy_op2
.done_op2:
    mov byte [r12 + rcx], 0

.done:
    pop r12
    leave
    ret

; ============================================
; hex_to_val: 十六进制字符转数值
; 输入: al = 字符
; 输出: al = 数值
; ============================================
hex_to_val:
    push rbp
    mov rbp, rsp
    cmp al, '0'
    jb .invalid
    cmp al, '9'
    jbe .digit
    cmp al, 'A'
    jb .invalid
    cmp al, 'F'
    jbe .upper
    cmp al, 'a'
    jb .invalid
    cmp al, 'f'
    jbe .lower
.invalid:
    xor al, al
    jmp .exit
.digit:
    sub al, '0'
    jmp .exit
.upper:
    sub al, 'A'
    add al, 10
    jmp .exit
.lower:
    sub al, 'a'
    add al, 10
.exit:
    leave
    ret

; ============================================
; get_input_format: 获取当前输入格式
; 输出: rax = 格式代码
; ============================================
get_input_format:
    load_addr rax, input_format
    mov rax, [rax]
    ret

; ============================================
; close_input: 关闭输入文件
; ============================================
close_input:
    push rbp
    mov rbp, rsp
    sub rsp, 32
    load_addr rbx, input_fd
    mov rdi, [rbx]
    sys_close
    leave
    ret

; ============================================
; 静态数据段
; ============================================
section .data
hex_state_pos   dq 0     ; 十六进制解析当前位置
hex_state_count dq 0     ; 十六进制解析数据长度

; ============================================
; BSS (续)
; ============================================
section .bss
text_byte_buf   resb 1   ; 当前操作码字节
text_op_buf     resb 128 ; 操作数字节缓冲 (最多2个操作数, 每个64字节)
text_op_index   resq 1   ; 操作数索引
text_op_count   resq 1   ; 已返回的操作数计数
