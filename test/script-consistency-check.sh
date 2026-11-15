#!/usr/bin/env bash
# ============================================================
# script-consistency-check.sh —— 关口六任务 3：Lua 脚本双源一致性检查
#
# 背景：脚本有双源——`kong/plugins/rate-limit-advanced/lib/redis.lua` 内嵌
#       字符串（运行时 EVALSHA 加载）与 `redis/*.lua` 独立文件（redis-cli
#       裸跑/矩阵测试用）。两者语义必须一致。
# 本检查：提取内嵌脚本字面量与对应文件，剥离注释与空行后逐字节 diff。
#       注释允许双源不同（文件版含使用说明、内嵌版含审查编号注释），
#       代码行必须一致。不改变任何运行时加载方式（纯只读检查）。
# 用法：bash test/script-consistency-check.sh（需 python3 或无依赖亦可，
#       用 awk/grep 实现，无 python 依赖）
# ============================================================
set -euo pipefail
cd "$(dirname "$0")/.."

LIB=kong/plugins/rate-limit-advanced/lib/redis.lua
PASS=0; FAIL=0
ok()  { printf '\033[32m%s\033[0m\n' "$*"; PASS=$((PASS+1)); }
bad() { printf '\033[31m%s\033[0m\n' "$*" >&2; FAIL=$((FAIL+1)); }

# strip_code：剥离 Lua 注释（-- 起至行尾）与空行，去除行尾空白
strip_code() {
    awk '{ sub(/--.*/, ""); sub(/[[:space:]]+$/, ""); } 1' "$1" \
        | sed '/^[[:space:]]*$/d'
}

check_pair() { # check_pair <lua文件名> <内嵌变量名>
    local fname="$1" var="$2" tmp
    tmp=$(mktemp /tmp/opencode/emb.XXXXXX.lua)
    # 提取 `local VAR = [[ ... ]]` 之间的内嵌文本
    awk -v var="$var" '
        $0 ~ ("local[[:space:]]+" var "[[:space:]]*=[[:space:]]*\\[\\[") { inblk=1; next }
        inblk && /\]\]/ { exit }
        inblk { print }
    ' "$LIB" > "$tmp"
    if [ ! -s "$tmp" ]; then
        bad "内嵌脚本 $var 提取失败（lib/redis.lua 中未找到）"
        rm -f "$tmp"
        return
    fi
    local ftmp norm
    ftmp=$(mktemp /tmp/opencode/fc.XXXXXX.lua)
    norm=$(mktemp /tmp/opencode/nc.XXXXXX.lua)
    strip_code "redis/$fname" > "$ftmp"
    strip_code "$tmp" > "$norm"
    if diff -q "$ftmp" "$norm" >/dev/null; then
        ok "一致：redis/$fname ↔ 内嵌 $var（剥离注释/空行后代码逐行一致）"
    else
        bad "不一致：redis/$fname ↔ 内嵌 $var（diff 如下）"
        diff "$ftmp" "$norm" >&2 || true
        FAIL=$((FAIL+1))
    fi
    rm -f "$tmp" "$ftmp" "$norm"
}

check_pair token_bucket.lua TOKEN_BUCKET
check_pair multi_bucket.lua  GRANT_MULTI
check_pair grant_lease.lua   GRANT_LEASE
check_pair return_lease.lua  RETURN_LEASE

printf '\n===== 汇总: PASS=%s FAIL=%s =====\n' "$PASS" "$FAIL"
[ "$FAIL" = "0" ]
