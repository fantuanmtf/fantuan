; ============================================================
; elf.asm - 手写 ELF64 可执行文件头
; 导出: ft_elf_write
; 调用: rdi = 输出缓冲, rsi = 文件总大小, rdx = 入口虚拟地址
; 镜像布局: [ELF 头 64][程序头 56][代码...]
; 基址 0x400000，单个 RWX PT_LOAD，无节表。
; ============================================================
default rel

%define BASE_ADDR 0x400000

section .text
global ft_elf_write

ft_elf_write:
    ; --- ELF 头 (64 字节) ---
    mov dword [rdi + 0], 0x464C457F      ; 7F 'E' 'L' 'F'
    mov byte  [rdi + 4], 2               ; ELFCLASS64
    mov byte  [rdi + 5], 1               ; ELFDATA2LSB
    mov byte  [rdi + 6], 1               ; EV_CURRENT
    mov byte  [rdi + 7], 0               ; ELFOSABI_SYSV
    mov qword [rdi + 8], 0               ; ABI 保留
    mov word  [rdi + 16], 2              ; ET_EXEC
    mov word  [rdi + 18], 0x3E           ; EM_X86_64
    mov dword [rdi + 20], 1              ; EV_CURRENT
    mov qword [rdi + 24], rdx            ; e_entry
    mov qword [rdi + 32], 64             ; e_phoff
    mov qword [rdi + 40], 0              ; e_shoff
    mov dword [rdi + 48], 0              ; e_flags
    mov word  [rdi + 52], 64             ; e_ehsize
    mov word  [rdi + 54], 56             ; e_phentsize
    mov word  [rdi + 56], 1              ; e_phnum
    mov word  [rdi + 58], 0              ; e_shentsize
    mov word  [rdi + 60], 0              ; e_shnum
    mov word  [rdi + 62], 0              ; e_shstrndx

    ; --- 程序头 (56 字节, 偏移 64) ---
    mov dword [rdi + 64], 1              ; PT_LOAD
    mov dword [rdi + 68], 7              ; PF_R | PF_W | PF_X
    mov qword [rdi + 72], 0              ; p_offset
    mov qword [rdi + 80], BASE_ADDR      ; p_vaddr
    mov qword [rdi + 88], BASE_ADDR      ; p_paddr
    mov qword [rdi + 96], rsi            ; p_filesz
    mov qword [rdi + 104], rsi           ; p_memsz
    mov qword [rdi + 112], 0x1000        ; p_align
    ret

section .note.GNU-stack noalloc noexec nowrite progbits
