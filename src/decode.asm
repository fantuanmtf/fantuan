; ============================================
; decode.asm - 比特模式匹配指令解码器 (跨平台版)
; ============================================
; 功能: 
;   1. 从 input.asm 读取原始字节
;   2. 使用 cpuhdr.asm 解析的 CPU 定义表进行位模式匹配
;   3. 生成 IR (中间表示) 条目
;
; IR 条目结构 (在内存中):
;   IR_ENTRY: 
;     +0:  mnemonic_ptr  (8字节, 指向助记符字符串)
;     +8:  operand_ptrs  (8*4=32字节, 最多4个操作数指针)
;    +40:  op_count      (8字节)
;    +48:  raw_bytes[4]  (4字节)
;    +52:  insn_size     (1字节)
;    +53:  (padding 3字节)
;    = 56 字节每个条目
;
; IR 缓冲区: 循环队列, 最大 256 条目
;
; 导出的函数:
;   decode_next_instruction() → rax=0(成功)/-1(EOF)
;   get_ir_entry(rdi=索引) → rax=IR条目指针
;   ir_entry_count → 当前 IR 条目数
;   clear_ir_buffer()
; ============================================

default rel

%include "config.inc"
%include "cpu_defs.inc"
%include "ir_defs.inc"

; ============================================
; 导出符号
; ============================================
global decode_next_instruction
global get_ir_entry
global ir_entry_count
global clear_ir_buffer
global IR_ENTRY_SIZE

; ============================================
; 外部引用
; ============================================
extern read_next_byte
extern find_insn_by_bits
extern lookup_field_value
extern insn_table
extern insn_count
extern field_table
extern field_count
extern write_stderr
extern format_hex_byte
extern nybble_to_hex

; ============================================
; BSS
; ============================================
section .bss
ir_buffer       resb MAX_IR_ENTRIES * IR_ENTRY_SIZE
ir_entry_count  resq 1
ir_write_pos    resq 1         ; 当前写入位置 (字节偏移)

; 临时 IR 条目 (用于构建)
temp_ir         resb IR_ENTRY_SIZE

; 默认字符串
str_unknown     resb 16        ; "unknown" 存储空间
str_hex_prefix  resb 16        ; "0x" 存储空间

section .text

; ============================================
; decode_next_instruction: 解码下一条指令
; 输出: rax = 0 (成功), -1 (EOF)
;
; 处理流程:
;   1. 从 input.asm 读取下一个字节
;   2. 在 insn_table 中查找匹配的指令
;   3. 如果匹配: 提取操作数, 构建 IR 条目
;   4. 如果不匹配: 创建 "db 0xNN" IR 条目
;   5. 将 IR 条目写入 ir_buffer
; ============================================
decode_next_instruction:
    push rbp
    mov rbp, rsp
    sub rsp, 64
    push r12
    push r13
    push r14
    push r15

    ; DEBUG: iteration marker
    push rax
    push rsi
    push rdi
%ifdef DEBUG
    load_addr rsi, debug_iter_msg
    call write_stderr
%endif
    pop rdi
    pop rsi
    pop rax

    ; 读取下一个字节
    call read_next_byte
    cmp rax, -1
    je .eof

    mov r12, rax           ; r12 = 原始字节值

    ; 清零临时 IR 条目
    load_addr rdi, temp_ir
    mov rcx, IR_ENTRY_SIZE / 8
    xor rax, rax
    rep stosq
    ; 确保最后几个字节也清零
    mov byte [temp_ir + IR_SIZE_OFF], 1  ; 默认指令大小=1

    ; 在指令表中查找
    mov rax, r12
    call find_insn_by_bits
    ; DEBUG: find_insn_by_bits result
    push rax
    push rsi
    push rdi
    push rax
%ifdef DEBUG
    load_addr rsi, debug_find_result_msg
    call write_stderr
%endif
    pop rax
    test rax, rax
    jz .debug_not_found
%ifdef DEBUG
    load_addr rsi, debug_find_nonzero_msg
    call write_stderr
%endif
    jmp .debug_done
.debug_not_found:
%ifdef DEBUG
    load_addr rsi, debug_find_zero_msg
    call write_stderr
%endif
.debug_done:
    pop rdi
    pop rsi
    pop rax
    test rax, rax
    jz .unknown_byte      ; 未找到 → db 0xNN

    mov r13, rax           ; r13 = 指令条目指针

    ; --- 匹配成功: 构建 IR ---

    ; 1. 设置助记符
    mov rax, [r13 + INSN_NAME_OFF]
    load_addr rbx, temp_ir
    mov [rbx + IR_MNEMONIC_OFF], rax

    ; 2. 设置原始字节
    mov [rbx + IR_RAW_OFF], r12b

    ; 3. 设置操作数计数 (使用 r15 保存, 避免 rcx 被后续操作覆盖)
    xor r15, r15
    mov r15b, [r13 + INSN_OPCOUNT_OFF]
    mov [rbx + IR_OPCOUNT_OFF], r15

    ; DEBUG: print op_count
    push rax
    push rsi
    push rdi
%ifdef DEBUG
    load_addr rsi, debug_op_count_msg
    call write_stderr
%endif
    mov al, r15b
    add al, '0'
    mov [debug_tmp_char], al
%ifdef DEBUG
    load_addr rsi, debug_tmp_char
    call write_stderr
    load_addr rsi, debug_newline_str
    call write_stderr
%endif
    pop rdi
    pop rsi
    pop rax

    ; 4. 解析操作数字段
    test r15, r15
    jz .finish_entry       ; 没有操作数

    xor r14, r14           ; 操作数索引
.op_loop:
    cmp r14, 4             ; 最多4个操作数
    jge .finish_entry
    cmp r14, r15           ; 使用 r15 中的 op_count (非易失寄存器, 不被 read_next_byte 修改)
    jge .finish_entry

    ; DEBUG: op_count and operand index
    push rax
    push rsi
    push rdi
%ifdef DEBUG
    load_addr rsi, debug_op_info_msg
    call write_stderr
%endif
    mov al, r14b
    add al, '0'
    mov [debug_tmp_char], al
%ifdef DEBUG
    load_addr rsi, debug_tmp_char
    call write_stderr
    load_addr rsi, debug_newline_str
    call write_stderr
%endif
    pop rdi
    pop rsi
    pop rax

    ; 获取字段索引 (直接使用 al, 避免覆盖 r15)
    mov al, [r13 + INSN_OPS_OFF + r14]

    ; DEBUG: field index value
    push rax
    push rsi
    push rdi
%ifdef DEBUG
    load_addr rsi, debug_field_idx_msg
    call write_stderr
%endif
    mov al, [r13 + INSN_OPS_OFF + r14]
    add al, '0'
    mov [debug_tmp_char], al
%ifdef DEBUG
    load_addr rsi, debug_tmp_char
    call write_stderr
    load_addr rsi, debug_newline_str
    call write_stderr
%endif
    pop rdi
    pop rsi
    pop rax

    ; 获取字段条目指针
    load_addr rbx, field_table
    movzx rax, al
    imul rax, FIELD_ENTRY_SIZE
    add rbx, rax            ; rbx = 字段条目指针

    ; DEBUG: check is_imm flag
    push rax
    push rsi
    push rdi
%ifdef DEBUG
    load_addr rsi, debug_is_imm_msg
    call write_stderr
%endif
    mov al, [rbx + FIELD_IS_IMM_OFF]
    add al, '0'
    mov [debug_tmp_char], al
%ifdef DEBUG
    load_addr rsi, debug_tmp_char
    call write_stderr
    load_addr rsi, debug_newline_str
    call write_stderr
%endif
    pop rdi
    pop rsi
    pop rax

    ; 从原始字节中提取字段值
    mov rax, [rbx + FIELD_BITMASK_OFF]   ; bitmask
    and rax, r12                          ; 应用掩码
    xor rcx, rcx
    mov cl, [rbx + FIELD_SHIFT_OFF]       ; shift
    shr rax, cl                           ; 右移对齐 (只能用 CL 或立即数)

    ; 检查是否是立即数字段
    cmp byte [rbx + FIELD_IS_IMM_OFF], 0
    jne .as_immediate

    ; DEBUG: about to call lookup_field_value
    push rax
    push rsi
    push rdi
%ifdef DEBUG
    load_addr rsi, debug_lookup_call_msg
    call write_stderr
%endif
    pop rdi
    pop rsi
    pop rax

    ; 查找字段值名称
    mov rdi, rbx
    call lookup_field_value

    ; DEBUG: lookup result
    push rax
    push rsi
    push rdi
%ifdef DEBUG
    load_addr rsi, debug_lookup_result_msg
    call write_stderr
%endif
    pop rdi
    pop rsi
    pop rax

    test rax, rax
    jnz .store_operand

    ; DEBUG: lookup returned 0
    push rax
    push rsi
    push rdi
%ifdef DEBUG
    load_addr rsi, debug_lookup_zero_msg
    call write_stderr
%endif
    pop rdi
    pop rsi
    pop rax

    ; 未找到 → 作为十六进制值输出
    ; 构建 "0xNN" 字符串
    jmp .as_immediate

.store_operand:
    ; 存储操作数指针到 IR 条目
    load_addr rbx, temp_ir
    mov [rbx + IR_OP1_OFF + r14 * 8], rax
    inc r14
    jmp .op_loop

.as_immediate:
    ; 立即数操作数: 读取下一个字节作为立即数值
    push r14

    call read_next_byte

    pop r14

    cmp rax, -1
    je .eof

    ; 将立即数值先存入 raw_bytes (使用 IR_SIZE_OFF 作为偏移，支持多立即数)
    load_addr rbx, temp_ir
    movzx rcx, byte [rbx + IR_SIZE_OFF]
    mov [rbx + IR_RAW_OFF + rcx], al
    add byte [rbx + IR_SIZE_OFF], 1

    ; 保存立即数值到栈上 (rax 是 caller-saved)
    push rax              ; [rsp] = 立即数值

    ; 格式化 "0xNN" 到 temp_ir 内联缓冲区
    load_addr rbx, temp_ir
    lea rdi, [rbx + IR_INLINE_STR_OFF + r14 * 8]
    push r12              ; 保存 r12 (原始操作码)
    mov r12, [rsp + 8]   ; 立即数值 (1 push above = 8 字节偏移)
    push r14
    call format_hex_byte
    pop r14
    pop r12               ; 恢复 r12 (原始操作码)

    ; 弹出立即数值
    pop rax

    ; 存储操作数指针到 IR 条目
    load_addr rbx, temp_ir
    lea rax, [rbx + IR_INLINE_STR_OFF + r14 * 8]
    mov [rbx + IR_OP1_OFF + r14 * 8], rax

    inc r14

    jmp .op_loop

.finish_entry:
    ; 将临时 IR 条目写入 IR 缓冲区
    call write_ir_entry

    xor rax, rax
    jmp .exit

.unknown_byte:
    ; 未匹配: 创建 "db 0xNN" 条目
    load_addr rbx, temp_ir

    ; 助记符 = "db"
    load_addr rax, str_db
    mov [rbx + IR_MNEMONIC_OFF], rax

    ; 操作数 = "0xNN" - 格式化到内联缓冲区 (temp_ir + IR_INLINE_STR_OFF)
    lea rdi, [rbx + IR_INLINE_STR_OFF]
    call format_hex_byte    ; r12 = 字节值

    ; 操作数指针指向 temp_ir 中的内联缓冲区
    ; (write_ir_entry 会在复制后修正此指针)
    lea rax, [rbx + IR_INLINE_STR_OFF]
    mov [rbx + IR_OP1_OFF], rax
    mov qword [rbx + IR_OPCOUNT_OFF], 1

    ; 原始字节
    mov [rbx + IR_RAW_OFF], r12b

    call write_ir_entry
    xor rax, rax
    jmp .exit

.eof:
    mov rax, -1

.exit:
    pop r15
    pop r14
    pop r13
    pop r12
    leave
    ret

; ============================================
; write_ir_entry: 将 temp_ir 写入 ir_buffer
; ============================================
write_ir_entry:
    push rbp
    mov rbp, rsp
    sub rsp, 32
    push r12
    push r13

    ; 检查是否已满
    load_addr rbx, ir_entry_count
    mov rax, [rbx]
    cmp rax, MAX_IR_ENTRIES
    jge .exit

    ; 计算写入位置
    load_addr r12, ir_buffer
    imul rax, IR_ENTRY_SIZE
    add r12, rax

    ; 复制 temp_ir 到 ir_buffer
    load_addr rsi, temp_ir
    mov rdi, r12
    mov rcx, IR_ENTRY_SIZE / 8
    rep movsq

    ; 修正所有 4 个操作数指针 (IR_OP1_OFF ~ IR_OP4_OFF)
    ; 如果指向 temp_ir 内部, 重定向到 ir_buffer 对应位置
    load_addr rax, temp_ir            ; rax = temp_ir 基地址
    xor r13, r13                      ; r13 = 操作数索引
.patch_loop:
    ; 计算当前操作数指针的偏移: IR_OP1_OFF + r13 * 8
    lea rcx, [r12 + IR_OP1_OFF + r13 * 8]
    mov rbx, [rcx]                    ; rbx = 当前操作数指针值
    test rbx, rbx
    jz .patch_next                    ; 空指针跳过
    
    sub rbx, rax                      ; rbx = 指针相对于 temp_ir 的偏移
    cmp rbx, IR_ENTRY_SIZE
    jae .patch_next                   ; 不在 temp_ir 范围内, 跳过
    
    ; 在范围内: 修正为指向 ir_buffer 中的对应位置
    add rbx, r12
    mov [rcx], rbx
    
.patch_next:
    inc r13
    cmp r13, 4
    jl .patch_loop

    ; 更新计数
    load_addr rbx, ir_entry_count
    inc qword [rbx]

.exit:
    pop r13
    pop r12
    leave
    ret

; ============================================
; get_ir_entry: 获取 IR 条目指针
; 输入: rdi = 索引 (0-based)
; 输出: rax = IR 条目指针 (0 = 越界)
; ============================================
get_ir_entry:
    push rbp
    mov rbp, rsp
    sub rsp, 32

    load_addr rbx, ir_entry_count
    mov rax, [rbx]
    cmp rdi, rax
    jge .out_of_range

    load_addr rax, ir_buffer
    imul rdi, IR_ENTRY_SIZE
    add rax, rdi

    leave
    ret

.out_of_range:
    xor rax, rax
    leave
    ret

; ============================================
; clear_ir_buffer: 清空 IR 缓冲区
; ============================================
clear_ir_buffer:
    push rbp
    mov rbp, rsp
    sub rsp, 32

    load_addr rbx, ir_entry_count
    mov qword [rbx], 0

    leave
    ret

; ============================================
; 静态数据
; ============================================
section .data
str_db:          db "db", 0
debug_find_result_msg: db "DEBUG: find_insn_by_bits result = ", 0
debug_find_zero_msg: db "0 (NOT FOUND)", 10, 0
debug_find_nonzero_msg: db "non-zero (FOUND)", 10, 0
debug_imm_msg:   db "DEBUG: imm_byte=", 0
debug_newline_str: db 10, 0
debug_iter_msg:  db "DEBUG: decode_next_instruction called", 10, 0
debug_op_info_msg: db "DEBUG: operand index = ", 0
debug_field_idx_msg: db "DEBUG: field index = ", 0
debug_is_imm_msg: db "DEBUG: is_imm flag = ", 0
debug_lookup_call_msg: db "DEBUG: calling lookup_field_value", 10, 0
debug_lookup_result_msg: db "DEBUG: lookup_field_value result = non-zero (found name)", 10, 0
debug_lookup_zero_msg: db "DEBUG: lookup_field_value returned 0 (NOT FOUND)", 10, 0
debug_op_count_msg: db "DEBUG: op_count = ", 0

; ============================================
; BSS (续)
; ============================================
section .bss
temp_hex_str    resb 16
debug_tmp_char  resb 2
