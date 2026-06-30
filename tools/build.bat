@echo off
REM ============================================
REM build.bat - NTF-Demo v2.0 Windows 构建脚本
REM 适用于 Windows cmd 原生环境
REM 需要: nasm.exe, gcc.exe (MinGW) 在 PATH 中
REM ============================================

echo ==========================================
echo Building NTF-Demo v2.0 (Windows x64)
echo ==========================================

REM 检查 NASM
where nasm.exe >nul 2>nul
if %ERRORLEVEL% NEQ 0 (
    echo Error: nasm.exe not found in PATH.
    echo Please install NASM or add it to your PATH.
    exit /b 1
)

set NASMFLAGS=-f win64 -DTARGET_WIN64 -i include/

echo [1/3] Assembling core modules...

nasm %NASMFLAGS% src\main.asm    -o main.o    || exit /b 1
nasm %NASMFLAGS% src\cpuhdr.asm  -o cpuhdr.o  || exit /b 1
nasm %NASMFLAGS% src\input.asm   -o input.o   || exit /b 1
nasm %NASMFLAGS% src\decode.asm  -o decode.o  || exit /b 1
nasm %NASMFLAGS% src\codegen.asm -o codegen.o || exit /b 1
nasm %NASMFLAGS% src\util.asm    -o util.o    || exit /b 1

if not exist bin mkdir bin

echo [2/3] Linking...

gcc -m64 -nostdlib -static ^
    main.o cpuhdr.o input.o decode.o codegen.o util.o ^
    -o bin\compiler.exe ^
    -lkernel32 ^
    -Wl,-e,_start ^
    -Wl,--subsystem,console

if %ERRORLEVEL% EQU 0 (
    copy /Y bin\compiler.exe compiler.exe >nul
    echo.
    echo ==========================================
    echo Build successful!
    echo ==========================================
    echo Binary: bin\compiler.exe
    echo.
    echo Usage:
    echo   compiler.exe -c cpu_defs\8bit_example.hdr tests\test_binary.bin
    echo   type output.asm
    dir /-C bin\compiler.exe
) else (
    echo.
    echo gcc linking failed, trying ld directly...
    ld -e _start ^
       --subsystem console ^
       main.o cpuhdr.o input.o decode.o codegen.o util.o ^
       -o bin\compiler.exe ^
       -lkernel32
    if %ERRORLEVEL% EQU 0 (
        copy /Y bin\compiler.exe compiler.exe >nul
        echo Build successful with ld!
        dir /-C bin\compiler.exe
    ) else (
        echo Linking failed!
        exit /b 1
    )
)
