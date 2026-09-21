; ============================================================
; ftcore.asm - fantuan v3 核心
; 职责: hex 源文本 -> 字节流 -> 重定位 -> ELF64 镜像
;
; 导出 (C ABI):
;   long ft_build(const char *src, unsigned long srclen,
;                 const char *entry,
;                 unsigned char *out, unsigned long outcap,
;                 char *err);
;
; 源语言规则:
;   - 每个字节行必须以 ";CK=hh" 结尾 (hh = 行内字面字节和 & 0xFF)
;   - 字节必须是小写十六进制、单空格分隔、每行 1-16 个
;   - 标签: _start 或 1-8 位小写十六进制数字
;   - 标签引用 <name> 必须位于可重定位操作码之后且是本行最后一个 token
;   - 可重定位白名单:
;       EB <l>          rel8
;       E8/E9 <l>       rel32
;       70..7F <l>      rel8
;       0F 80..8F <l>   rel32
;       B8..BF <l>      imm32 绝对地址
; ============================================================
default rel

%define CODE_BASE   0x400078
%define HDR_SIZE    120
%define MAX_LABELS  1024
%define MAX_RELOCS  2048

%define KIND_REL8   1
%define KIND_REL32  2
%define KIND_ABS32  3

section .bss
align 8
g_src        resq 1
g_srclen     resq 1
g_out        resq 1
g_outcap     resq 1
g_err        resq 1
g_line       resq 1
g_outlen     resq 1
g_entry      resb 16

g_lsum       resq 1
g_lcount     resq 1
g_ck         resq 1
g_hasck      resq 1
g_reloc      resq 1
g_hasrel     resq 1

label_names  resq MAX_LABELS
label_offs   resq MAX_LABELS
label_count  resq 1

rel_off      resq MAX_RELOCS
rel_kind     resq MAX_RELOCS
rel_name     resq MAX_RELOCS
rel_line     resq MAX_RELOCS
reloc_count  resq 1

global ft_label_count
global ft_byte_count
ft_label_count resq 1
ft_byte_count  resq 1

section .rodata
str_hexdigits:  db "0123456789abcdef"
str_lineprefix: db 231, 172, 172, 32, 0                         ; "第 "
str_linemid:    db 32, 232, 161, 140, 58, 32, 0                 ; " 行: "
str_ckbad1:     db 32, 232, 161, 140, 58, 32
                db "校验和应为 0x", 0
str_ckbad2:     db "，实际 0x", 0
str_ckbad3:     db "。重敲吧", 0

str_err_tab:     db "有 Tab？用空格，文明点", 0
str_err_ckfmt:   db ";CK= 后面得跟 2 位小写十六进制", 0
str_err_ckempty: db "空行写什么校验和？", 0
str_err_label:   db "标签只能是小写十六进制（1-8 位，_start 除外）: ", 0
str_err_dup:     db "标签重复了，你想覆盖谁？: ", 0
str_err_manylab: db "标签太多（上限 1024），克制一点: ", 0
str_err_token:   db "这玩意儿我认不出来: ", 0
str_err_upper:   db "大写字母？机器码只认小写", 0
str_err_toomany: db "一行最多 16 个字节，你当内存不要钱？", 0
str_err_nock:    db "缺 ;CK=，你以为校验和会自动生成吗？", 0
str_err_reloc:   db "这个操作码不配用标签，自己手算偏移去", 0
str_err_relast:  db "标签后面不能再塞字节", 0
str_err_nolabel: db "标签不存在，你从哪编出来的？", 0
str_err_range:   db "rel8 装不下，自己换 E9", 0
str_err_noentry: db "找不到入口 _start，程序从梦里开始执行吗？", 0
str_err_big:     db "程序太大，穷", 0
str_err_manyrel: db "重定位太多（上限 2048），克制一点", 0

section .text
global ft_build
extern ft_elf_write

; ------------------------------------------------------------
; hexval: al -> al (0..15)，非法返回 0xFF。只改 al。
; ------------------------------------------------------------
hexval:
    cmp al, '0'
    jb .bad
    cmp al, '9'
    jbe .digit
    cmp al, 'a'
    jb .bad
    cmp al, 'f'
    ja .bad
    sub al, 'a' - 10
    ret
.digit:
    sub al, '0'
    ret
.bad:
    mov al, 0xFF
    ret

; ------------------------------------------------------------
; pack_name: rdi=名字指针, rsi=长度(<=8) -> rax=零填充的 8 字节
; 保留 rbx/r12-r15
; ------------------------------------------------------------
pack_name:
    xor rax, rax
    xor rcx, rcx
.loop:
    cmp rcx, rsi
    jae .done
    movzx rdx, byte [rdi + rcx]
    push rcx
    shl rcx, 3
    shl rdx, cl
    pop rcx
    or rax, rdx
    inc rcx
    jmp .loop
.done:
    ret

; ------------------------------------------------------------
; validate_name: rdi=名字指针, rsi=长度 -> eax 0=合法, -1=非法
; ------------------------------------------------------------
validate_name:
    cmp rsi, 6
    jne .hexcheck
    cmp dword [rdi], 0x6174735F       ; "_sta"
    jne .hexcheck
    cmp word [rdi + 4], 0x7472        ; "rt"
    jne .hexcheck
    xor eax, eax
    ret
.hexcheck:
    test rsi, rsi
    jz .bad
    cmp rsi, 8
    ja .bad
    xor rcx, rcx
.loop:
    cmp rcx, rsi
    jae .ok
    mov al, [rdi + rcx]
    call hexval
    cmp al, 0xFF
    je .bad
    inc rcx
    jmp .loop
.ok:
    xor eax, eax
    ret
.bad:
    mov eax, -1
    ret

; ------------------------------------------------------------
; append_z: rdi=目标, rsi=字符串 -> rax=新目标指针
; ------------------------------------------------------------
append_z:
    mov al, [rsi]
    test al, al
    jz .done
    mov [rdi], al
    inc rdi
    inc rsi
    jmp append_z
.done:
    mov rax, rdi
    ret

; ------------------------------------------------------------
; fmt_u64: rdi=目标, rsi=数值 -> rax=新目标指针
; ------------------------------------------------------------
fmt_u64:
    push rbx
    push r12
    mov r12, rdi
    sub rsp, 32
    lea rbx, [rsp + 31]
    mov byte [rbx], 0
    mov rax, rsi
    test rax, rax
    jnz .loop
    dec rbx
    mov byte [rbx], '0'
    jmp .copy
.loop:
    xor rdx, rdx
    mov rcx, 10
    div rcx
    add dl, '0'
    dec rbx
    mov [rbx], dl
    test rax, rax
    jnz .loop
.copy:
    mov rdi, r12
    mov rsi, rbx
.next:
    mov al, [rsi]
    test al, al
    jz .done
    mov [rdi], al
    inc rdi
    inc rsi
    jmp .next
.done:
    mov rax, rdi
    add rsp, 32
    pop r12
    pop rbx
    ret

; ------------------------------------------------------------
; fmt_hex_byte: rdi=目标, rsi=值 -> rax=新目标指针
; ------------------------------------------------------------
fmt_hex_byte:
    lea rdx, [str_hexdigits]
    mov eax, esi
    shr eax, 4
    and eax, 0x0F
    mov cl, [rdx + rax]
    mov [rdi], cl
    mov eax, esi
    and eax, 0x0F
    mov cl, [rdx + rax]
    mov [rdi + 1], cl
    lea rax, [rdi + 2]
    ret

; ------------------------------------------------------------
; err_plain: rdi = 消息 -> 写入 g_err
; ------------------------------------------------------------
err_plain:
    mov rdx, [g_err]
.copy:
    mov al, [rdi]
    mov [rdx], al
    inc rdi
    inc rdx
    test al, al
    jnz .copy
    ret

; ------------------------------------------------------------
; err_line: rdi = 消息，带上 "第 N 行: " 前缀
; ------------------------------------------------------------
err_line:
    push r12
    mov r12, rdi
    mov rdi, [g_err]
    lea rsi, [str_lineprefix]
    call append_z
    mov rdi, rax
    mov rsi, [g_line]
    call fmt_u64
    mov rdi, rax
    lea rsi, [str_linemid]
    call append_z
    mov rdi, rax
    mov rsi, r12
    call append_z
    mov byte [rax], 0
    pop r12
    ret

; ------------------------------------------------------------
; err_line_tok: rdi=消息, rsi=token 指针, rdx=token 长度
; ------------------------------------------------------------
err_line_tok:
    push rbx
    push r12
    push r13
    mov r12, rsi
    mov r13, rdx
    call err_line
    ; err_line 结果结尾在 g_err 里，找末尾
    mov rdi, [g_err]
.findend:
    cmp byte [rdi], 0
    je .append
    inc rdi
    jmp .findend
.append:
    xor rcx, rcx
.loop:
    cmp rcx, r13
    jae .done
    mov al, [r12 + rcx]
    mov [rdi], al
    inc rdi
    inc rcx
    jmp .loop
.done:
    mov byte [rdi], 0
    pop r13
    pop r12
    pop rbx
    ret

; ------------------------------------------------------------
; err_ck: rdi=应有值, rsi=实际值
; ------------------------------------------------------------
err_ck:
    push r12
    push r13
    mov r12, rdi
    mov r13, rsi
    mov rdi, [g_err]
    lea rsi, [str_lineprefix]
    call append_z
    mov rdi, rax
    mov rsi, [g_line]
    call fmt_u64
    mov rdi, rax
    lea rsi, [str_ckbad1]
    call append_z
    mov rdi, rax
    mov rsi, r12
    call fmt_hex_byte
    mov rdi, rax
    lea rsi, [str_ckbad2]
    call append_z
    mov rdi, rax
    mov rsi, r13
    call fmt_hex_byte
    mov rdi, rax
    lea rsi, [str_ckbad3]
    call append_z
    mov byte [rax], 0
    pop r13
    pop r12
    ret

; ------------------------------------------------------------
; append_byte: al = 字节 -> eax 0/-1
; ------------------------------------------------------------
append_byte:
    mov rcx, [g_outlen]
    add rcx, HDR_SIZE
    cmp rcx, [g_outcap]
    jae .over
    mov rdx, [g_out]
    add rdx, rcx
    mov [rdx], al
    inc qword [g_outlen]
    xor eax, eax
    ret
.over:
    lea rdi, [str_err_big]
    call err_plain
    mov eax, -1
    ret

; ------------------------------------------------------------
; find_label_q: rdi = 零填充名字 -> rax = 偏移 或 -1
; ------------------------------------------------------------
find_label_q:
    push rbx
    push r12
    mov rbx, rdi
    lea r12, [label_names]
    xor rcx, rcx
    mov rdx, [label_count]
.loop:
    cmp rcx, rdx
    jae .no
    cmp rbx, [r12 + rcx * 8]
    je .yes
    inc rcx
    jmp .loop
.yes:
    lea rdi, [label_offs]
    mov rax, [rdi + rcx * 8]
    pop r12
    pop rbx
    ret
.no:
    mov rax, -1
    pop r12
    pop rbx
    ret

; ------------------------------------------------------------
; add_label: rdi=名字指针, rsi=长度 -> eax 0/-1
; ------------------------------------------------------------
add_label:
    push rbx
    push r12
    push r13
    push r14
    mov r12, rdi
    mov r13, rsi
    call pack_name
    mov r14, rax
    mov rdi, r14
    call find_label_q
    cmp rax, -1
    jne .dup
    mov rax, [label_count]
    cmp rax, MAX_LABELS
    jae .many
    lea rdi, [label_names]
    mov [rdi + rax * 8], r14
    lea rdi, [label_offs]
    mov rdx, [g_outlen]
    mov [rdi + rax * 8], rdx
    inc qword [label_count]
    xor eax, eax
    jmp .ret
.dup:
    lea rdi, [str_err_dup]
    mov rsi, r12
    mov rdx, r13
    call err_line_tok
    mov eax, -1
    jmp .ret
.many:
    lea rdi, [str_err_manylab]
    call err_line
    mov eax, -1
.ret:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ------------------------------------------------------------
; record_reloc: 校验本行操作码并登记重定位、追加占位
; 依赖: g_lcount / g_lreloc / g_line / g_outlen
; 返回: eax 0/-1
; ------------------------------------------------------------
record_reloc:
    push rbx
    mov rbx, [g_out]
    mov rsi, [g_outlen]
    mov rcx, [g_lcount]
    cmp rcx, 1
    je .one
    cmp rcx, 2
    je .two
    jmp .bad
.one:
    mov al, [rbx + HDR_SIZE + rsi - 1]
    cmp al, 0xEB
    je .rel8
    cmp al, 0xE8
    je .rel32
    cmp al, 0xE9
    je .rel32
    cmp al, 0x70
    jb .not_jcc
    cmp al, 0x7F
    jbe .rel8
.not_jcc:
    cmp al, 0xB8
    jb .bad
    cmp al, 0xBF
    jbe .abs32
    jmp .bad
.two:
    mov al, [rbx + HDR_SIZE + rsi - 2]
    cmp al, 0x0F
    jne .bad
    mov al, [rbx + HDR_SIZE + rsi - 1]
    cmp al, 0x80
    jb .bad
    cmp al, 0x8F
    ja .bad
    jmp .rel32
.rel8:
    mov r8, KIND_REL8
    mov r9, 1
    jmp .store
.rel32:
    mov r8, KIND_REL32
    mov r9, 4
    jmp .store
.abs32:
    mov r8, KIND_ABS32
    mov r9, 4
    jmp .store
.store:
    mov rax, [reloc_count]
    cmp rax, MAX_RELOCS
    jae .manyrel
    lea rdi, [rel_off]
    mov [rdi + rax * 8], rsi
    lea rdi, [rel_kind]
    mov [rdi + rax * 8], r8
    mov rdx, rax
    shl rdx, 3
    lea rdi, [rel_name]
    mov rcx, [g_reloc]
    mov [rdi + rdx], rcx
    lea rdi, [rel_line]
    mov rcx, [g_line]
    mov [rdi + rdx], rcx
    inc qword [reloc_count]
    xor r10, r10
.ph:
    cmp r10, r9
    jae .ok
    xor eax, eax
    call append_byte
    test eax, eax
    js .fail
    inc r10
    jmp .ph
.ok:
    pop rbx
    xor eax, eax
    ret
.bad:
    lea rdi, [str_err_reloc]
    call err_line
    pop rbx
    mov eax, -1
    ret
.manyrel:
    lea rdi, [str_err_manyrel]
    call err_line
    pop rbx
    mov eax, -1
    ret
.fail:
    pop rbx
    ret

; ------------------------------------------------------------
; process_line: rdi=行指针, rsi=行长度 -> eax 0/-1
; 保留 rbx/r12-r15
; ------------------------------------------------------------
process_line:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r12, rdi
    mov r13, rsi
    inc qword [g_line]

    mov qword [g_lsum], 0
    mov qword [g_lcount], 0
    mov qword [g_hasck], 0
    mov qword [g_hasrel], 0
    mov qword [g_reloc], 0

    test r13, r13
    jz .done
    cmp byte [r12 + r13 - 1], 13
    jne .no_cr
    dec r13
.no_cr:
    test r13, r13
    jz .done

    ; Tab 检查
    xor rcx, rcx
.tabscan:
    cmp rcx, r13
    jae .tabok
    cmp byte [r12 + rcx], 9
    je .err_tab
    inc rcx
    jmp .tabscan
.tabok:
    ; 找注释起点
    mov r14, r13
    xor rcx, rcx
.semiscan:
    cmp rcx, r13
    jae .semidone
    cmp byte [r12 + rcx], ';'
    je .semifound
    inc rcx
    jmp .semiscan
.semifound:
    mov r14, rcx
    lea rbx, [rcx + 6]
    cmp r13, rbx
    jb .semidone                    ; 不足 6 字符，按普通注释
    cmp byte [r12 + rcx + 1], 'C'
    jne .semidone
    cmp byte [r12 + rcx + 2], 'K'
    jne .semidone
    cmp byte [r12 + rcx + 3], '='
    jne .semidone
    mov al, [r12 + rcx + 4]
    call hexval
    cmp al, 0xFF
    je .err_ckfmt
    mov r8b, al
    mov al, [r12 + rcx + 5]
    call hexval
    cmp al, 0xFF
    je .err_ckfmt
    shl r8b, 4
    or r8b, al
    movzx r8, r8b
    mov [g_ck], r8
    mov qword [g_hasck], 1
.semidone:
    ; 去掉代码部分尾部空格
.trim:
    test r14, r14
    jz .trimmed
    cmp byte [r12 + r14 - 1], ' '
    jne .trimmed
    dec r14
    jmp .trim
.trimmed:
    ; 跳到第一个非空格
    xor r15, r15
.skipsp:
    cmp r15, r14
    jae .empty_code
    cmp byte [r12 + r15], ' '
    jne .at_code
    inc r15
    jmp .skipsp
.empty_code:
    cmp qword [g_hasck], 0
    jne .err_ckempty
    jmp .done

.at_code:
    ; 尝试解析标签
    mov rdi, r15
.tok0:
    cmp rdi, r14
    jae .tok0end
    cmp byte [r12 + rdi], ' '
    je .tok0end
    inc rdi
    jmp .tok0
.tok0end:
    mov rbx, rdi
    cmp byte [r12 + rdi - 1], ':'
    jne .tokens
    ; 标签名 = [r15, rdi-1)
    mov rsi, rdi
    sub rsi, r15
    dec rsi
    lea rdi, [r12 + r15]
    test rsi, rsi
    jz .err_label
    cmp rsi, 8
    ja .err_label
    call validate_name
    test eax, eax
    jnz .err_label
    lea rdi, [r12 + r15]
    call add_label
    test eax, eax
    js .fail
    mov r15, rbx

    ; 字节 / 重定位 token 循环
.tokens:
.tokloop:
    cmp r15, r14
    jae .tokens_done
    cmp byte [r12 + r15], ' '
    jne .tokstart
    inc r15
    jmp .tokloop
.tokstart:
    mov rdi, r15
.tokscan:
    cmp rdi, r14
    jae .tokend
    cmp byte [r12 + rdi], ' '
    je .tokend
    inc rdi
    jmp .tokscan
.tokend:
    mov rbx, rdi
    mov rsi, rdi
    sub rsi, r15
    cmp byte [r12 + r15], '<'
    jne .isbyte

    ; --- 标签引用 ---
    cmp byte [r12 + rdi - 1], '>'
    jne .err_token
    mov rax, rsi
    sub rax, 2
    cmp rax, 1
    jb .err_token
    cmp rax, 8
    ja .err_token
    lea rdi, [r12 + r15 + 1]
    mov rsi, rax
    call validate_name
    test eax, eax
    jnz .err_token
    lea rdi, [r12 + r15 + 1]
    mov rsi, rbx
    sub rsi, r15
    sub rsi, 2
    call pack_name
    mov [g_reloc], rax
    mov qword [g_hasrel], 1
    mov r15, rbx
.check_tail:
    cmp r15, r14
    jae .tokens_done
    cmp byte [r12 + r15], ' '
    jne .err_relast
    inc r15
    jmp .check_tail

    ; --- 字节 ---
.isbyte:
    cmp rsi, 2
    jne .err_token
    mov al, [r12 + r15]
    call .check_upper
    mov al, [r12 + r15 + 1]
    call .check_upper
    mov al, [r12 + r15]
    call hexval
    cmp al, 0xFF
    je .err_token
    mov r8b, al
    mov al, [r12 + r15 + 1]
    call hexval
    cmp al, 0xFF
    je .err_token
    shl r8b, 4
    or r8b, al
    movzx r8, r8b
    add [g_lsum], r8
    inc qword [g_lcount]
    cmp qword [g_lcount], 16
    ja .err_toomany
    mov al, r8b
    call append_byte
    test eax, eax
    js .fail
    mov r15, rbx
    jmp .tokloop

.check_upper:
    cmp al, 'A'
    jb .not_upper
    cmp al, 'F'
    jbe .is_upper
.not_upper:
    ret
.is_upper:
    pop rax
    jmp .err_upper

.tokens_done:
    cmp qword [g_hasrel], 0
    je .ck_check
    call record_reloc
    test eax, eax
    js .fail
.ck_check:
    cmp qword [g_lcount], 0
    je .done
    cmp qword [g_hasck], 0
    je .err_nock
    movzx rax, byte [g_lsum]
    cmp rax, [g_ck]
    jne .err_badck
    jmp .done

.done:
    xor eax, eax
    jmp .ret
.fail:
    mov eax, -1
.ret:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

.err_tab:
    lea rdi, [str_err_tab]
    call err_line
    jmp .fail
.err_ckfmt:
    lea rdi, [str_err_ckfmt]
    call err_line
    jmp .fail
.err_ckempty:
    lea rdi, [str_err_ckempty]
    call err_line
    jmp .fail
.err_label:
    lea rdi, [str_err_label]
    lea rsi, [r12 + r15]
    mov rdx, rbx
    sub rdx, r15
    call err_line_tok
    jmp .fail
.err_token:
    lea rdi, [str_err_token]
    lea rsi, [r12 + r15]
    mov rdx, rbx
    sub rdx, r15
    call err_line_tok
    jmp .fail
.err_upper:
    lea rdi, [str_err_upper]
    call err_line
    jmp .fail
.err_toomany:
    lea rdi, [str_err_toomany]
    call err_line
    jmp .fail
.err_nock:
    lea rdi, [str_err_nock]
    call err_line
    jmp .fail
.err_relast:
    lea rdi, [str_err_relast]
    call err_line
    jmp .fail
.err_badck:
    mov rdi, [g_ck]
    movzx rsi, byte [g_lsum]
    call err_ck
    jmp .fail

; ------------------------------------------------------------
; patch_relocs: 回填全部重定位 -> eax 0/-1
; ------------------------------------------------------------
patch_relocs:
    push rbx
    push r12
    push r13
    push r14
    push r15
    xor r12, r12
.loop:
    cmp r12, [reloc_count]
    jae .done
    mov rdx, r12
    shl rdx, 3
    lea rcx, [rel_off]
    mov r13, [rcx + rdx]
    lea rcx, [rel_kind]
    mov r14, [rcx + rdx]
    lea rcx, [rel_name]
    mov rbx, [rcx + rdx]
    mov rdi, rbx
    call find_label_q
    cmp rax, -1
    je .err_unknown
    mov rdi, [g_out]
    lea rdi, [rdi + HDR_SIZE + r13]
    cmp r14, KIND_REL8
    je .rel8
    cmp r14, KIND_REL32
    je .rel32
    ; abs32
    add rax, CODE_BASE
    mov [rdi], eax
    jmp .next
.rel8:
    mov rcx, rax
    sub rcx, r13
    dec rcx
    cmp rcx, -128
    jl .err_range
    cmp rcx, 127
    jg .err_range
    mov [rdi], cl
    jmp .next
.rel32:
    mov rcx, rax
    sub rcx, r13
    sub rcx, 4
    mov [rdi], ecx
.next:
    inc r12
    jmp .loop
.done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    xor eax, eax
    ret
.err_unknown:
    mov rdx, r12
    shl rdx, 3
    lea rcx, [rel_line]
    mov rax, [rcx + rdx]
    mov [g_line], rax
    lea rdi, [str_err_nolabel]
    call err_line
    jmp .failed
.err_range:
    mov rdx, r12
    shl rdx, 3
    lea rcx, [rel_line]
    mov rax, [rcx + rdx]
    mov [g_line], rax
    lea rdi, [str_err_range]
    call err_line
.failed:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    mov eax, -1
    ret

; ------------------------------------------------------------
; ft_build: 主入口
; ------------------------------------------------------------
ft_build:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov [g_src], rdi
    mov [g_srclen], rsi
    mov [g_out], rcx
    mov [g_outcap], r8
    mov [g_err], r9

    ; 拷贝入口名 (最多 8 字符)
    lea rdi, [g_entry]
    mov rcx, 16
    xor eax, eax
    rep stosb
    mov rsi, rdx
    xor rcx, rcx
.cp_entry:
    cmp rcx, 8
    jae .cp_done
    mov al, [rsi + rcx]
    test al, al
    jz .cp_done
    lea rdi, [g_entry]
    mov [rdi + rcx], al
    inc rcx
    jmp .cp_entry
.cp_done:
    mov qword [label_count], 0
    mov qword [reloc_count], 0
    mov qword [g_outlen], 0
    mov qword [g_line], 0

    xor r12, r12
.line_loop:
    cmp r12, [g_srclen]
    jae .lines_done
    mov rdi, [g_src]
    add rdi, r12
    mov r13, r12
.find_nl:
    cmp r13, [g_srclen]
    jae .have_line
    mov rbx, [g_src]
    cmp byte [rbx + r13], 10
    je .have_line
    inc r13
    jmp .find_nl
.have_line:
    mov rsi, r13
    sub rsi, r12
    call process_line
    test eax, eax
    js .fail
    mov r12, r13
    cmp r12, [g_srclen]
    jae .lines_done
    inc r12
    jmp .line_loop

.lines_done:
    call patch_relocs
    test eax, eax
    js .fail
    mov rdi, [g_entry]
    call find_label_q
    cmp rax, -1
    je .err_entry
    mov r14, rax
    mov rdi, [g_out]
    mov rsi, [g_outlen]
    add rsi, HDR_SIZE
    lea rdx, [r14 + CODE_BASE]
    call ft_elf_write
    mov rax, [g_outlen]
    mov [ft_byte_count], rax
    mov rax, [label_count]
    mov [ft_label_count], rax
    mov rax, [g_outlen]
    add rax, HDR_SIZE
    jmp .ret
.err_entry:
    lea rdi, [str_err_noentry]
    call err_plain
.fail:
    mov rax, -1
.ret:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

section .note.GNU-stack noalloc noexec nowrite progbits
