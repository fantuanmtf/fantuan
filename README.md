# fantuan v3.0

用**十六进制 x86-64 机器码**写程序的恶搞语言工具链。

没有助记符，没有汇编器替你算偏移，没有语法糖，也没有可用性——源码就是你要运行的机器码，只是以文本十六进制写出来。`fantuan` 负责校验、回填标签、手写 ELF64 头，产出一个 **freestanding 静态可执行文件**（无 libc，只用 Linux syscall）。

工具链本身：**NASM 汇编主体 + C 外围**（命令行、文件、进程）。仅支持 Linux x86-64。

## 快速开始

```bash
make

./bin/fantuan run examples/hello.femboy        # 编译并运行
./bin/fantuan build examples/jump.femboy       # 默认输出 ./jump
./bin/fantuan check examples/loop.femboy       # 只校验
./bin/fantuan dump ./jump                   # 十六进制转储
```

## 源文件长什么样

```asm
; Hello, fantuan! —— write(1, 0a, 15); exit(0)
_start:
  b8 01 00 00 00       ;CK=b9 mov eax, 1
  bf 01 00 00 00       ;CK=c0 mov edi, 1
  be <0a>              ;CK=be mov esi, 0a
  ba 0f 00 00 00       ;CK=c9 mov edx, 15
  0f 05                ;CK=14 syscall
  b8 3c 00 00 00       ;CK=f4 mov eax, 60
  31 ff                ;CK=30 xor edi, edi
  0f 05                ;CK=14 syscall
0a:
  48 65 6c 6c 6f 2c 20 66 61 6e 74 75 61 6e 21 0a    ;CK=58
```

## 规则（没有 `--prank=0`，别找了）

| 规则 | 说明 |
|------|------|
| 小写十六进制 | 大写直接报错，机器码只认小写 |
| 单空格分隔 | Tab 会被阴阳怪气 |
| 每行 1–16 字节 | 超了自己反省 |
| `;CK=hh` | 每个字节行必须自带校验和 = 行内字节和 & 0xFF，注释写在 CK 后面 |
| 标签 | `_start` 或 1–8 位小写十六进制数字（如 `0a:`） |
| `<标签>` | 只能跟在白名单操作码之后，且必须是本行最后一个 token |

可重定位白名单：

| 写法 | 含义 |
|------|------|
| `eb <l>` | `jmp rel8` |
| `e8/e9 <l>` | `call/jmp rel32` |
| `70..7f <l>` | `jcc rel8` |
| `0f 80..8f <l>` | `jcc rel32` |
| `b8..bf <l>` | `mov r32, imm32`（标签的绝对地址） |

标签地址、跳转偏移、校验和全都要你自己算——工具只替你回填 `<标签>`。

## 挑战：三个

用手写机器码做点真能玩的东西：

1. **彩色 2D 三关吃豆人**
2. **加减乘除计算器**
3. **2D 平面火柴人跑酷**

题目、要求与提交方式见 [CHALLENGE.md](CHALLENGE.md)。走 [GitHub Issues](https://github.com/fantuanmtf/fantuan/issues/new) 提交（提之前先把单文件源码放进自己的仓库），每个挑战**第一位通过者**获得作者女装照一张（承诺不露脸）。

## 命令行

```
fantuan build <src.femboy> [-o <out>] [-e <label>]   编译成原生 ELF
fantuan run   <src.femboy> [-e <label>] [-- <args>]  编译到临时文件并执行
fantuan check <src.femboy> [-e <label>]              只校验不产出
fantuan dump  <file>                                 十六进制转储
```

## 产物布局

```
[ELF64 头 64B][程序头 56B][代码...]
基址 0x400000，单个 RWX PT_LOAD，无节表，无 libc
入口 = _start 标签地址
```

## 项目结构

```
src/core/     NASM 核心：词法/布局/重定位/ftcore.asm + ELF 打包/elf.asm
src/cli/      C 外围：main.c
include/      fantuan.h (C ABI)
examples/     .femboy 示例
tests/        golden 测试 (tests/run_tests.sh)
docs/         语言规范
```

## 构建与测试

```bash
make            # 需要 nasm + gcc
make test       # 跑 golden 测试
make clean
```

## 许可证

Unlicense（公有领域）。见 [LICENSE](LICENSE)。
