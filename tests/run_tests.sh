#!/usr/bin/env bash
# fantuan v3 golden 测试
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/bin/fantuan"
pass=0
fail=0

for dir in "$ROOT"/tests/cases/*/; do
    name="$(basename "$dir")"
    src="$dir/src.femboy"

    if [ -f "$dir/expect_fail" ]; then
        if "$BIN" check "$src" >/dev/null 2>&1; then
            echo "FAIL $name: 本该编译失败，却过了"
            fail=$((fail + 1))
        else
            echo "PASS $name (预期失败)"
            pass=$((pass + 1))
        fi
        continue
    fi

    exp_out="$(cat "$dir/expected_stdout" 2>/dev/null || true)"
    exp_exit="$(cat "$dir/expected_exit" 2>/dev/null || echo 0)"
    out="$("$BIN" run "$src" 2>/dev/null)"
    rc=$?

    if [ "$out" != "$exp_out" ]; then
        echo "FAIL $name: stdout 不符"
        echo "  期望: [$exp_out]"
        echo "  实际: [$out]"
        fail=$((fail + 1))
        continue
    fi
    if [ "$rc" != "$exp_exit" ]; then
        echo "FAIL $name: 退出码 $rc != $exp_exit"
        fail=$((fail + 1))
        continue
    fi
    echo "PASS $name"
    pass=$((pass + 1))
done

echo "==== $pass 过, $fail 挂 ===="
[ "$fail" -eq 0 ]
