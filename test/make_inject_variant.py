#!/usr/bin/env python3
"""生成 RETURN_LEASE 的"提交点后失败"注入变体：
   在幂等提交点（RETURNED 标记）之后、桶更新之前注入 redis.error_reply，
   用于确定性验证"标记成功、桶更新失败 ⇒ 重试不重复归还"。
   仅测试用途：修改的是测试变体，生产脚本不动。"""
import sys

SRC = "redis/return_lease.lua"
ANCHOR = "redis.call('HSET', lkey, 'status', 'RETURNED', 'return_requested', requested)"

src = open(SRC, encoding="utf-8").read()
if ANCHOR not in src:
    sys.exit("anchor not found in " + SRC)
injected = src.replace(
    ANCHOR,
    ANCHOR + '\ndo return redis.error_reply("INJECTED_FAILURE") end',
    1,
)
out = sys.argv[1] if len(sys.argv) > 1 else "/tmp/rl_inject.txt"
open(out, "w", encoding="utf-8").write(injected)
print("variant ok ->", out)
