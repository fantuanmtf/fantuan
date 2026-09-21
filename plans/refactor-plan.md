# fantuan 全面重构计划 v1.0

## 1. 现状分析

### 当前架构痛点

当前 fantuan 是一个用 x86-64 NASM 汇编编写的**文本到汇编的编译器**：

```
输入 .01 文件（文本格式）
     │  00001 00x00001 00x00000
     ▼
parse.asm  →  逐行读取、分割 token
     │
     ▼
table.asm  →  硬编码的指令查找表
     │         12 条指令、每个单独的处理函数
     ▼
nop.asm / mov.asm / add.asm / ...  →  每个指令一个独立的 .asm 文件
     │
     ▼
output.asm  →  NASM 汇编输出
```

**主要局限：**
- ❌ **硬编码指令集** — 指令映射关系固化在 `table.asm` + 12 个指令处理文件，添加新指令需写汇编代码
- ❌ **自定义文本语法** — 使用 `00x00001` 这种非标准操作数编码，不直观
- ❌ **缺乏复用性** — 换一个 CPU 架构就得重写整个编译器
- ❌ **无中间表示** — 输入直接到输出，难以调试和分析

---

## 2. 重构目标架构

新架构的核心思想：**将"指令编码表"从代码中剥离，变成用户提供的声明式配置文件**，编译器只负责通用的"比特匹配 → 汇编输出"管道。

```
┌─────────────────────────────────────────────────────────────────────┐
│                        fantuan v2.0 架构                          │
└─────────────────────────────────────────────────────────────────────┘

                          ┌──────────────┐
                          │  cpu.hdr     │  ← 用户编写的 CPU 定义头文件
                          │  (声明式DSL)  │     描述指令编码规则
                          └──────┬───────┘
                                 │ 解析
                                 ▼
┌──────────────┐    ┌──────────────────────┐    ┌──────────────┐
│  输入文件     │    │  核心处理管道          │    │  输出文件     │
│              │    │                      │    │              │
│  .bin 二进制  │───▶│  Step1: 输入解析器    │    │  output.asm  │
│  .hex 十六进制│    │  读取原始字节          │    │  NASM 汇编   │
│  .txt 兼容旧版│    │                      │    │              │
│              │    │  Step2: CPU 解码器    │    └──────────────┘
└──────────────┘    │  比特模式匹配          │
                    │                      │    ┌──────────────┐
                    │  Step3: IR 生成      │───▶│  ir_output   │
                    │  中间表示输出(调试)     │    │  中间表示文件  │
                    │                      │    └──────────────┘
                    │  Step4: 代码生成器    │───▶ output.asm
                    │  IR → 汇编文本        │
                    └──────────────────────┘
```

### 核心模块划分

| 模块 | 文件 | 职责 |
|------|------|------|
| **入口/I/O** | `main.asm` | 命令行参数解析、多格式输入支持、输出管理 |
| **CPU 头解析器** | `cpuhdr.asm` (新) | 解析用户提供的 CPU 定义 DSL，构建内存中的查找表 |
| **输入解析器** | `input.asm` (新) | 支持 .bin / .hex / .txt 三种输入格式 |
| **指令解码器** | `decode.asm` (新) | 使用 CPU 定义表对原始字节进行比特模式匹配 |
| **IR 输出** | `ir.asm` (新) | 生成中间表示文件用于调试 |
| **代码生成器** | `codegen.asm` (新) | 将 IR 转换为 NASM 汇编文本 |
| **跨平台配置** | `config.inc` (保留) | Windows/Linux 系统调用宏 |

**废弃的旧文件：**
- `parse.asm` — 被 `input.asm` 替代
- `table.asm` — 被 `cpuhdr.asm` + `decode.asm` 替代
- `nop.asm` / `mov.asm` / `add.asm` / ... — 全部由 CPU 头文件 DSL 动态生成

---

## 3. CPU 头文件 DSL 设计

### 设计原则
- **声明式** — 只描述"是什么"，不描述"怎么做"
- **面向比特字段** — 直接对应 CPU 数据手册中的编码表
- **可扩展** — 支持任意指令长度、任意字段划分

### DSL 语法草案

```
; ============================================
; CPU 定义文件示例: my_cpu.hdr
; 语法: 指令 <名称> [操作数字段...]
;       字段 <名称> <位范围> [映射...]
; 注释以 ; 开头
; ============================================

; --- 全局设置 ---
arch "mycpu-8bit"          ; 架构名称
endian little               ; 字节序: little/big
insn_size fixed 1           ; 指令长度: fixed 1字节 / variable

; --- 指令编码表 ---
; 格式: 指令 <名称> <比特掩码> <匹配值> <要显示的操作数>
;
; 比特掩码 = 哪些位参与匹配 (1=匹配, 0=忽略)
; 匹配值   = 在这些位上期望的值
;
; 解释: mask=0xE0 (11100000), pattern=0x00 (00000000)
;       高3位为000时匹配 nop

指令 nop       mask=0xE0 pattern=0x00

指令 mov       mask=0xE0 pattern=0x20  operands=dst,src
指令 add       mask=0xE0 pattern=0x40  operands=dst,src
指令 sub       mask=0xE0 pattern=0x60  operands=dst,src
指令 mul       mask=0xE0 pattern=0x80  operands=dst,src
指令 inc       mask=0xE0 pattern=0xA0  operands=dst
指令 dec       mask=0xE0 pattern=0xC0  operands=dst
指令 xor       mask=0xE0 pattern=0xE0  operands=dst,src
指令 jmp       mask=0xFF pattern=0xD0  operands=target

; --- 16位指令示例 ---
指令 load      mask=0xF000 pattern=0x1000  operands=reg,imm
指令 store     mask=0xF000 pattern=0x2000  operands=reg,imm

; --- 操作数字段映射 ---
; 格式: 字段 <名称> <比特范围> <映射表...>
; 位范围: MSB:LSB (从高位到低位)

; 目的寄存器字段 [4:2] (字节中的第4-2位)
字段 dst       bits=4:2
    ax         value=000
    bx         value=001
    cx         value=010
    dx         value=011
    r8         value=100
    r9         value=101
    r10        value=110
    r11        value=111

; 源操作数字段 [1:0] (字节中的第1-0位)
字段 src       bits=1:0
    ax         value=00
    bx         value=01
    imm_0      value=00
    imm_1      value=01
    imm_5      value=10
    imm_10     value=11

; 16位指令中的寄存器字段 [11:8]
字段 reg       bits=11:8
    ax         value=0001
    bx         value=0010
    cx         value=0011
    dx         value=0100

; 跳转目标 (直接输出数值)
字段 target    bits=7:0  type=immediate
```

### DSL 行的内部表示

CPU 头文件被解析后，在内存中构建以下结构：

```c
// 伪代码: CPU 定义的内存结构
struct {
    // 指令表: 线性数组,每个条目描述一条指令的匹配规则
    instruction_table: [
        { mask: 0xE0, pattern: 0x00, name: "nop", operands: [] },
        { mask: 0xE0, pattern: 0x20, name: "mov", operands: ["dst", "src"] },
        ...
    ]
    
    // 字段表: 每个字段名 → 位范围 + 值映射表
    field_table: {
        "dst": {
            bits: [4, 2],  // 起始位, 结束位
            values: [
                { pattern: 0x00, name: "ax" },
                { pattern: 0x04, name: "bx" },
                ...
            ]
        },
        "src": {
            bits: [1, 0],
            values: [
                { pattern: 0x00, name: "ax" },
                { pattern: 0x01, name: "bx" },
                ...
            ]
        }
    }
}
```

---

## 4. 处理管道详解

### Step 1: 输入解析器 (`input.asm`)

支持三种输入格式：

| 格式 | 扩展名 | 说明 | 举例 |
|------|--------|------|------|
| **Raw Binary** | `.bin` | 直接读取原始字节流 | `FF 20 40 ...` (字节) |
| **Hex Text** | `.hex` | Intel HEX 格式或纯十六进制文本 | `:10000000FF20406080100A...` |
| **Plain Hex** | `.txt` / `.hex` | 空格分隔的十六进制字节 | `0xFF 0x20 0x40 0x60 ...` |
| **Legacy** | `.01` (兼容) | 旧版文本格式 | `00001 00x00001 00x00000` |

**模式选择**：通过命令行参数或文件扩展名自动识别。

```
compiler -b program.bin -c mycpu.hdr       # 二进制模式
compiler -x program.hex -c mycpu.hdr        # 十六进制模式
compiler -t program.01 -c mycpu.hdr         # 兼容旧格式
compiler program.bin -c mycpu.hdr           # 自动识别 (.bin/.hex/.01)
```

### Step 2: CPU 头解析器 (`cpuhdr.asm`)

**启动时一次性解析** CPU 头文件，在内存中构建：

1. **指令查找表** — 每个条目：`{ mask, pattern, name, operand_list }`
2. **字段查找表** — 每个字段：`{ bit_start, bit_end, value_map[] }`
3. **内部表示** — 使用固定大小的预分配数组（汇编中动态分配复杂）

数据结构设计（汇编 BSS 段）：
```asm
; 指令表条目大小
INSN_ENTRY_SIZE equ 32   ; mask(8) + pattern(8) + name_ptr(8) + operands(8)
MAX_INSTRUCTIONS equ 64   ; 最多 64 条指令

; 字段表条目大小  
FIELD_ENTRY_SIZE equ 32   ; name_ptr(8) + bitmask(8) + value_table_ptr(8) + count(8)
MAX_FIELDS equ 16         ; 最多 16 个字段

; 值映射条目大小
VALUE_ENTRY_SIZE equ 16   ; pattern(8) + name_ptr(8)
MAX_VALUES_PER_FIELD equ 16
```

### Step 3: 指令解码器 (`decode.asm`)

**核心算法**：

```text
for each byte (or word) in input:
    for each instruction in instruction_table:
        if (input_byte & instruction.mask) == instruction.pattern:
            // 匹配成功！
            create IR entry:
                mnemonic = instruction.name
                for each operand_field in instruction.operands:
                    field_def = field_table[operand_field]
                    raw_bits = (input_byte & field_def.bitmask) >> shift
                    operand_name = lookup_value(field_def, raw_bits)
                    if not found → operand_name = "0x" + hex(raw_bits)
                    IR.operands.append(operand_name)
            break
    if no match found:
        IR.mnemonic = "db"
        IR.operands = [hex(input_byte)]  // 未知字节，直接输出数据
```

**匹配优先规则**：精确匹配优先（掩码位更多的优先匹配），相同掩码按先定义优先。

### Step 4: 中间表示 (IR) (`ir.asm`)

IR 是管道中的**结构化数据通道**，也是**可选的调试输出文件**。

**内存中的 IR 表示**：
```asm
; IR 条目结构
IR_ENTRY_SIZE equ 48
; 偏移:  0 = mnemonic_ptr (8字节, 指向字符串)
; 偏移:  8 = operand_count (8字节)
; 偏移: 16 = operands[4] (每个8字节, 最多4个操作数)
; 偏移: 48 = raw_bytes[4] (原始字节, 用于调试)
```

**调试输出文件 `ir_output.txt`** 示例：
```
; IR 输出: program.bin → CPU: mycpu.hdr
; ============================================

[0x0000] mov ax, bx          ; 0x21
[0x0001] add cx, imm_1       ; 0x46
[0x0002] sub dx, imm_5       ; 0x6A
[0x0003] inc ax              ; 0xA0
[0x0004] jmp 0x10            ; 0xD0 0x10
```

### Step 5: 代码生成器 (`codegen.asm`)

将 IR 条目转换为 NASM 汇编文本，写回 `output.asm`。

输出示例：
```asm
; Generated by fantuan v2.0
; CPU: mycpu.hdr
; Source: program.bin
; ============================================

section .text
global _start

_start:
    mov ax, bx
    add cx, 1
    sub dx, 5
    inc ax
    jmp label_0x10

label_0x10:
    ; ... 继续解码
```

---

## 5. 数据流详解

```
命令行: compiler -b program.bin -c mycpu.hdr -i ir_debug.txt

流程:
┌─────────────────────────────────────────────────────────────────────┐
│  main.asm                                                          │
│                                                                     │
│  1. 解析命令行参数                                                  │
│     -b   → 二进制模式                                               │
│     -c   → CPU 头文件路径                                           │
│     -i   → IR 输出文件路径 (可选)                                   │
│     -o   → 输出文件路径 (默认 output.asm)                           │
│                                                                     │
│  2. 调用 cpuhdr.asm → 解析 CPU 头文件到内存                         │
│  3. 调用 input.asm  → 读取输入文件到输入缓冲区                       │
│  4. 主循环:                                                         │
│     a. input.asm  → 获取下一个字节/字                               │
│     b. decode.asm → 匹配指令, 生成 IR 条目                          │
│     c. ir.asm     → 如果开启, 写入 IR 调试文件                       │
│     d. codegen.asm → IR 条目 → 汇编文本 → write_char()               │
│  5. flush_output() → 写出 output.asm                                │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 6. 文件变更清单

### 新增文件

| 文件 | 说明 |
|------|------|
| `plans/refactor-plan.md` | 本计划文档 |
| `cpuhdr.asm` | CPU 头文件 DSL 解析器 |
| `input.asm` | 多格式输入解析器 (bin/hex/txt) |
| `decode.asm` | 指令解码器 (比特模式匹配) |
| `ir.asm` | 中间表示生成与输出 |
| `codegen.asm` | IR → NASM 汇编转换 |
| `cpu_examples/8bit_example.hdr` | 8位 CPU 定义示例 |
| `cpu_examples/riscv_example.hdr` | RISC-V 定义示例 |
| `tests/test_binary.bin` | 二进制测试文件 |
| `tests/test_hex.txt` | 十六进制测试文件 |

### 修改文件

| 文件 | 变更 |
|------|------|
| `main.asm` | 重写：CLI 参数、多格式输入调度、新管道控制 |
| `config.inc` | 保留，可添加新宏 |
| `build.sh` / `build_windows.sh` | 更新模块列表，移除旧模块 |

### 废弃文件

| 文件 | 替代 |
|------|------|
| `parse.asm` | `input.asm` + `decode.asm` |
| `table.asm` | `cpuhdr.asm` + `decode.asm` |
| `nop.asm` / `mov.asm` / `add.asm` ... | CPU 头文件 DSL |
| `print.asm` | CPU 头文件 + `codegen.asm` 共同处理 |

---

## 7. 实施阶段

### Phase 1: CPU 头文件 DSL 规范定稿
- 确定 DSL 语法细节（关键字、格式、注释规则）
- 编写 DSL 规范文档
- 创建 2-3 个示例 CPU 定义文件

### Phase 2: 核心框架重构
- 重写 `main.asm`：CLI 参数解析、管道调度
- 实现 `cpuhdr.asm`：DSL 解析器、内存表构建
- 实现 `input.asm`：多格式输入读取
- 实现 `decode.asm`：比特模式匹配引擎
- 实现 `codegen.asm`：IR → 汇编输出

### Phase 3: IR 与调试
- 实现 `ir.asm`：IR 条目生成与调试文件输出
- 添加 `-i` 命令行参数支持

### Phase 4: 测试与验证
- 创建二进制测试用例
- 使用旧版 .01 测试用例验证兼容性
- 端到端测试：二进制输入 → CPU 头 → output.asm

### Phase 5: 文档与清理
- 更新 README.md
- 清理废弃文件
- 添加使用示例和教程

---

## 8. 关键设计决策

### 8.1 为什么选择声明式 DSL 而非配置数组
- DSL 比数组更接近 CPU 数据手册的表达方式
- 支持注释和层级结构
- 可扩展为更复杂的规则（如变长指令）

### 8.2 为什么保留汇编实现而非改用 C/Rust
- 项目定位：展示汇编语言构建工具的完整能力
- 学习价值：深入理解计算机底层工作原理
- 保持与原始项目的一致性

### 8.3 字节序处理
- CPU 头文件中声明 `endian little` 或 `endian big`
- 多字节指令的字节序在解码时自动处理
- Intel HEX 格式本身包含地址信息，支持跨页解码

### 8.4 指令长度处理
- `fixed N`：所有指令等长，快速解码
- `variable`：变长指令，通过指令的掩码/模式确定长度
- 不定长指令通过第一条匹配指令的隐含信息推断长度

### 8.5 未匹配字节的处理
- 任何无法匹配 CPU 头中任意指令的字节，直接输出为 `db 0xNN`
- 这使得编译器可以处理包含数据段的二进制文件（如混合代码和数据的 ROM）
- 可以添加 `data` 伪指令标记数据区域（后续扩展）

---

## 9. 示例：完整使用流程

### 示例 1: 8位 CPU 程序

**CPU 头文件 `mycpu.hdr`**：
```
; 8位简单 CPU
指令 nop       mask=0xE0 pattern=0x00
指令 mov       mask=0xE0 pattern=0x20  operands=dst,src
指令 add       mask=0xE0 pattern=0x40  operands=dst,src
指令 jmp       mask=0xFF pattern=0xD0  operands=target

字段 dst       bits=4:2
    ax         value=000
    bx         value=001
    cx         value=010

字段 src       bits=1:0
    ax         value=00
    bx         value=01
    imm_1      value=10
    imm_5      value=11

字段 target    bits=7:0  type=immediate
```

**二进制输入 `program.bin`**（十六进制表示）：
```
21 46 D0 10
```

**解码过程**：
```
字节 0x21: mask=0xE0 → 0x20 → pattern=0x20 → "mov"
           dst 字段 [4:2] = 001 → "bx"
           src 字段 [1:0] = 01 → "bx"
           → mov bx, bx

字节 0x46: mask=0xE0 → 0x40 → pattern=0x40 → "add"
           dst 字段 [4:2] = 010 → "cx"
           src 字段 [1:0] = 10 → "imm_1"
           → add cx, 1

字节 0xD0: mask=0xFF → 0xD0 → pattern=0xD0 → "jmp"
           target 字段 [7:0] = 0x10 → 立即数 16
           → jmp 0x10

字节 0x10: 没有匹配 → db 0x10
```

**输出 `output.asm`**：
```asm
section .text
global _start

_start:
    mov bx, bx
    add cx, 1
    jmp 0x10
    db 0x10
```

---

## 10. CLI 命令行接口

```
compiler [选项] <输入文件>

选项:
  -b, --binary     输入为原始二进制格式 (默认按扩展名自动检测)
  -x, --hex        输入为十六进制文本格式
  -t, --text       输入为旧版 .01 文本格式
  -c, --cpu <file> CPU 定义头文件路径 (必须)
  -i, --ir <file>  输出中间表示到文件 (可选, 调试用)
  -o, --output <file>  输出文件路径 (默认: output.asm)
  -h, --help       显示帮助信息

示例:
  compiler -c mycpu.hdr program.bin
  compiler -c mycpu.hdr -x program.hex -i debug.txt
  compiler -c mycpu.hdr -t program.01
```

---

## 11. IR 输出格式规范

IR 文件用于调试，每行格式：

```
[地址] <指令助记符> [操作数...]  ; <原始字节>
```

地址格式：`0xXXXX` (16位) 或 `0xXXXXXXXX` (32位)，根据文件大小自动选择。

IR 条目也包含**比特字段展开**（可选详细模式）：
```
[0x0000] mov ax, bx          ; 0x21
         ├─ opcode [7:5] 00100 → mov
         ├─ dst    [4:2] 001   → bx
         └─ src    [1:0] 01    → bx
```

---

## 12. 与旧版的兼容性

旧版 .01 格式可以通过 `-t` 参数继续使用，但需要对应的 CPU 头文件将旧编码映射为汇编输出。例如：

```
; 兼容旧版的 CPU 头文件
指令 nop       mask=0xE0 pattern=0x00  ...对应 00000
指令 mov       mask=0xE0 pattern=0x20  ...对应 00001
```

旧版的 `00x00001` 操作数可视为特殊字段映射：
```
字段 operand1  bits=39:0
    ax         value=00x00001
    bx         value=00x00002
```
