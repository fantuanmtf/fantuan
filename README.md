# fantuan v2.0 — 自定义 CPU 编译器工具链

[![Platform](https://img.shields.io/badge/platform-Linux%20%7C%20Windows-blue)]()
[![Language](https://img.shields.io/badge/language-x86__64%20Assembly-red)]()
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)

用 **x86-64 汇编** 编写的完整编译器工具链，支持自定义 CPU 架构。

## 快速开始

```bash
# 构建反汇编器
make

# 反汇编二进制文件
./bin/compiler -c cpu_defs/8bit_example.hdr tests/test_binary.bin
cat output.asm
```

## 项目结构

```
fantuan/
├── src/            # 编译器源码 (NASM x86-64)
│   ├── main.asm        # 入口、CLI、缓冲 I/O
│   ├── cpuhdr.asm      # CPU 定义 (.hdr) 解析器
│   ├── decode.asm      # 通用解码器 → IR
│   ├── codegen.asm     # IR → 汇编输出
│   └── input.asm       # 多格式输入读取
├── include/        # 头文件
│   ├── config.inc      # 跨平台宏 (Linux/Windows)
│   ├── ir_defs.inc     # IR 数据结构常量
│   └── cpu_defs.inc    # CPU 定义数据结构常量
├── cpu_defs/       # CPU 架构定义文件 (.hdr)
├── examples/       # .fantuan 示例程序
├── tests/          # 测试用例
├── tools/          # 构建脚本
├── docs/           # 详细文档
├── Makefile
└── README.md
```

## 命令行使用

```bash
# 反汇编二进制文件
compiler -c <cpu.hdr> [options] <input>

选项:
  -c <file>     CPU 定义文件 (.hdr)
  -x            输入为十六进制文本
  -i <file>     导出 IR 调试信息
  -o <file>     指定输出文件 (默认: output.asm)
```

## 构建

```bash
make            # 标准构建
make DEBUG=1    # 调试构建 (输出详细日志)
make clean      # 清理
make test       # 构建并测试
```

## 示例

输入 `tests/test_binary.bin` (15字节原始二进制):
```
0x00 0x10 0x15 0x2A 0x3F 0x50 0x64 0x78 0x80 0x10 0x90 0x00 0xA0 0x01 0x00
```

输出 `output.asm`:
```asm
section .text
global _start
_start:
    nop
    mov ax, ax
    mov bx, bx
    add cx, cx
    ...
```

## 许可证

MIT — 详见 [LICENSE](LICENSE)
