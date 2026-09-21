#!/bin/bash
# ============================================
# build.sh - fantuan v2.0 Linux 构建脚本
# ============================================

echo "=========================================="
echo "Building fantuan v2.0 (Linux x86_64)"
echo "=========================================="

# 检查 NASM
if ! command -v nasm &> /dev/null; then
    echo "Error: NASM not found."
    exit 1
fi

# 确保 bin 目录存在
mkdir -p bin

echo "[1/2] Assembling core modules..."

# 编译核心模块
nasm -f elf64 -i include/ src/main.asm    -o main.o    || exit 1
nasm -f elf64 -i include/ src/cpuhdr.asm  -o cpuhdr.o  || exit 1
nasm -f elf64 -i include/ src/input.asm   -o input.o   || exit 1
nasm -f elf64 -i include/ src/decode.asm  -o decode.o  || exit 1
nasm -f elf64 -i include/ src/codegen.asm -o codegen.o || exit 1
nasm -f elf64 -i include/ src/util.asm    -o util.o    || exit 1

echo "[2/2] Linking..."

# 链接
ld -m elf_x86_64 \
    main.o cpuhdr.o input.o decode.o codegen.o util.o \
    -o bin/compiler

if [ $? -eq 0 ]; then
    cp bin/compiler compiler
    chmod +x bin/compiler compiler
    echo ""
    echo "=========================================="
    echo "Build successful!"
    echo "=========================================="
    echo "Binary: bin/compiler"
    echo ""
    echo "Usage:"
    echo "  ./compiler -c cpu_defs/8bit_example.hdr tests/test_binary.bin"
    echo "  cat output.asm"
    ls -la bin/compiler
else
    echo "Linking failed!"
    exit 1
fi
