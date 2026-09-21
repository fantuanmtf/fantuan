#!/bin/bash
# ============================================
# build_windows.sh - fantuan v2.0 Windows 构建脚本
# ============================================

echo "=========================================="
echo "Building fantuan v2.0 (Windows x64)"
echo "=========================================="

# 检查 NASM
NASM="nasm"
if ! command -v nasm &> /dev/null; then
    for p in /usr/bin/nasm /usr/local/bin/nasm D:/mys32/usr/bin/nasm.exe; do
        if [ -f "$p" ]; then
            NASM="$p"
            echo "Found NASM at: $NASM"
            break
        fi
    done
    if [ "$NASM" = "nasm" ]; then
        echo "Error: NASM not found."
        exit 1
    fi
fi

NASMFLAGS="-f win64 -DTARGET_WIN64 -i include/"

echo "[1/3] Assembling core modules..."
$NASM $NASMFLAGS src/main.asm    -o main.o    || exit 1
$NASM $NASMFLAGS src/cpuhdr.asm  -o cpuhdr.o  || exit 1
$NASM $NASMFLAGS src/input.asm   -o input.o   || exit 1
$NASM $NASMFLAGS src/decode.asm  -o decode.o  || exit 1
$NASM $NASMFLAGS src/codegen.asm -o codegen.o || exit 1
$NASM $NASMFLAGS src/util.asm    -o util.o    || exit 1

mkdir -p bin

echo "[2/3] Linking..."
if gcc -m64 -nostdlib -static \
    main.o cpuhdr.o input.o decode.o codegen.o util.o \
    -o bin/compiler.exe \
    -lkernel32 \
    -Wl,-e,_start \
    -Wl,--subsystem,console; then
    cp bin/compiler.exe compiler.exe
    echo ""
    echo "=========================================="
    echo "Build successful!"
    echo "=========================================="
    echo "Binary: bin/compiler.exe"
    echo ""
    echo "Usage:"
    echo "  compiler.exe -c cpu_defs/8bit_example.hdr tests/test_binary.bin"
    echo "  type output.asm"
    ls -la bin/compiler.exe
else
    echo ""
    echo "gcc linking failed, trying ld directly..."
    ld -e _start \
       --subsystem console \
       main.o cpuhdr.o input.o decode.o codegen.o util.o \
       -o bin/compiler.exe \
       -lkernel32 && \
    cp bin/compiler.exe compiler.exe && \
    echo "Build successful with ld!" && \
    ls -la bin/compiler.exe || \
    echo "Linking failed!"
fi
