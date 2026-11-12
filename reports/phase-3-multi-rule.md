# 测试报告 —— Phase 3 多规则联合判定（α 强一致模式）

## 1. 测试目的

验证 `rules` 多规则模式的核心语义（spec 5 条 ADDED 需求）：

1. **多桶全或无原子**：一空一有 ⇒ 429 且双桶 tokens 均不变；全够 ⇒ 各扣 1 放行。
2. **组键结构与组指纹**：组内同 hash tag；改任一规则 ⇒ 整组换桶。
3. **强一致模式配置约束**：rules+limit_by 互斥 / batch∈{0,1} / ≤8 条，违反下发即 400。
4. **多规则响应语义**：放行头瓶颈口径；429 体 `rule` 字段 + Retry-After 封顶。
5. **单规则形态零回归**：dims.sh / quota.sh / 故障双路径与既有锚点一致。

## 2. 修改文件

| 文件 | 内容 |
|---|---|
| `kong/plugins/rate-limit-advanced/schema.lua` | `rules` 数组字段 + custom_entity_check（互斥/batch/header_name 三约束合一） |
| `kong/plugins/rate-limit-advanced/lib/algorithm.lua` | 组键构造（组指纹 + r<i> 段）、`check_multi()`、`validate_rules()` 运行时兜底 |
| `kong/plugins/rate-limit-advanced/lib/redis.lua` | 内嵌 `GRANT_MULTI` 多键脚本、`grant_multi()`、`parse_multi_grant_response()` 防御校验 |
| `kong/plugins/rate-limit-advanced/handler.lua` | 多规则响应语义（瓶颈头 / 429 rule 字段 / reject_cap 封顶） |
| `redis/multi_bucket.lua` | 独立裸跑多键脚本（与内嵌双源同步） |
| `bench/rules.sh` | 5 场景 14 断言验证脚本（新增） |
| README / docs/design.md / docs/architecture.md / rule.md | 文档同步 |

## 3. 修改内容（对应 design D1–D6）

- **D1（α 决策）**：`check()` 入口检测 `conf.rules` 非空 → `check_multi()`——无本地库存（不触碰 store）、无 batch 租约，每请求一次 `grant_multi` 多键原子 Lua。
- **D2（配置模型）**：`rules` 数组（元素 limit/window/burst/limit_by/header_name，len_max=8）+ 三条前置约束经 `custom_entity_check`（含 init 期 userdata 防御）；`build_key` 入口 `validate_rules` 运行时兜底（双保险）。
- **D3（组键）**：`kong:rl:{<ns>:g=<组指纹>:r<i>:<dim>=<val>:…}`，组指纹 = 全部规则参数 FNV-1a 按序拼接。
- **D4（多键脚本）**：KEYS=r1..rN 桶键、ARGV=[n, 各规则 rate/burst/ttl]；逐桶 refill（TIME 单调/burst 封顶，与单桶同公式）→ 全检 → 全扣/全不扣；返回 `{1, tokens_i, wait_i,…}` 或 `{0, 规则序号, wait,…}`。
- **D5（响应语义）**：放行 remaining=min(各桶剩余)/reset=瓶颈桶下一令牌时刻/multi_limit=瓶颈规则 limit；429 retry_after=max(不足桶 wait) 封顶 max(不足桶 window)、体含 `rule` 人读标识、判定日志含 reject。
- **D6（兼容）**：单规则路径一行不动（dims.sh/quota.sh 全绿为证）；`redis/multi_bucket.lua` 与内嵌脚本 diff 为空。

## 4. 测试环境

与 Phase 1/2 一致：3× Kong 3.6 DB-less（kong1/2/3，代理 8030/8010/8020）+ Redis 7 + http-echo；
k6 v0.54.0（quota.sh 回归用）；Docker 29.3.0 / compose v5.1.0。

## 5. 测试参数

- 场景用 rules：`[{limit:10,window:60},{limit:5,window:60,limit_by:[consumer,path]}]`（各场景独立 namespace）
- 预置桶：`HSET tokens <v> ts <now+30>`（冻结 refill，断言值精确）
- 配额基线：limit=100 / window=3600 / batch=1 / per_node=150

## 6. 测试命令

```bash
./bench/rules.sh                                 # 5 场景 14 断言
./bench/dims.sh                                  # 单规则回归（8 断言）
./bench/quota.sh -l 100 -b 1 -p 150              # batch=1 基线
# 故障双路径：docker compose stop redis → 默认 503 / 容错配置 200+degraded
# redis-cli --eval redis/multi_bucket.lua ...  # 独立脚本裸跑（3.2）
# resty 单测：parse_multi_grant_response / validate_rules
```

## 7. 测试结果

| # | 验证 | 结果 | 预期 | 状态 |
|---|---|---|---|---|
| 1 | 1.2 互斥语义（rules+显式 limit_by=["consumer"]） | 400 + 互斥文案 | 下发即拒 | ✅ |
| 2 | 1.2 近似语义（rules+省略/显式 ["ip"]） | 201 / 201 | 默认值视为未设置（D2 声明） | ✅ |
| 3 | 1.2 仅 limit_by（无 rules） | 201 | 不误伤 | ✅ |
| 4 | 2.1 rules+顶层 limit_by 同现 | 400 | 三类坏配置之一 | ✅ |
| 5 | 2.1 rules+batch=20 | 400（`config.batch: rules 模式下 batch 必须为 0 或 1`） | 下发即拒 | ✅ |
| 6 | 2.1 9 条规则 | 400（len_max=8） | 下发即拒 | ✅ |
| 7 | 2.1 合法 2 规则 | 201 | 正常下发 | ✅ |
| 8 | 2.2 旧配置回归 | 仅 limit_by+batch=20 → 201；dims 场景配置下发成功 | 零影响 | ✅ |
| 9 | 3.1 双源 diff | 空 | GRANT_MULTI ≡ multi_bucket.lua | ✅ |
| 10 | 3.2 裸跑一空一有 | `{0, 规则1, wait≈9.5}`，双桶 0/5 不变 | 全不扣 | ✅ |
| 11 | 3.2 裸跑全够 | `{1, 4.04, 0, 4.08, 0}`，各桶恰好减 1 | 各扣 1 | ✅ |
| 12 | 3.3 parse 防御单测 | 21/21（19 畸形全拒 + 2 组合法解包） | 畸形 → nil+err | ✅ |
| 13 | 4.1 组键形状 | `kong:rl:{p3-shape:g=3acf5710:r1:consumer=anon}` / `…r2:…:path=/echo`，同 tag，跨节点复用 | 组指纹+r<i> 段+同 slot | ✅ |
| 14 | 4.2 E2E 一空一有 | 429，体 `{"rule":"rules[1]:consumer","retry_after":6,…}`，Retry-After=6=ceil(5.04)，Reset=now+6，R1/R2=0/5 不变，multi_reject 判定日志 | spec 核心场景 | ✅ |
| 15 | 4.2 放行瓶颈头（R1=5,R2=1.5 冻结） | 200，Remaining=0（floor 0.5）、Reset−now=6、Limit=5（瓶颈 r2） | 瓶颈口径 | ✅ |
| 16 | 4.2 429 rule 指向（R1=0.2 冻结） | Retry-After=5=ceil(4.8)、body rule=rules[1] | max(wait) | ✅ |
| 17 | 4.2 Retry-After 封顶 | 3600（= max window，不更大） | cap | ✅ |
| 18 | 4.3 兜底单测 | 8/8（batch>1/9 条/header 缺名全拒；8 条/batch=1/合法通过；build_key 注入 → nil+kerr） | 双保险 | ✅ |
| 19 | 5.2 rules.sh 全量 | PASS=14 FAIL=0（一次全绿） | 全部场景 | ✅ |
| 20 | 6.1 dims.sh 回归 | PASS=8 FAIL=0 | 与 Phase 2 锚点一致 | ✅ |
| 21 | 6.1 quota.sh batch=1 | allowed=100 / limited=350 / other=0，每节点 150 断言 | 恰好 100 | ✅ |
| 22 | 6.1 故障双路径 | 默认 503；容错 200+degraded | 与 Phase 1 一致 | ✅ |

## 8. 日志分析

- 多规则拒绝判定日志：`multi_reject keys=… reject=rules[1]:consumer wait=5.04…`（notice 级）与放行日志 `multi_grant keys=… remaining=… bottleneck=r2` 可检索区分；handler 的 429 日志含 `reject=` 段。
- 组 4 期间曾出现 `redis grant_multi failed: malformed multi eval response`（eval 参数错位 bug，见 §9-1），修复后零重现。

## 9. 发现的问题（执行中新发现）

| # | 问题 | 处置 |
|---|---|---|
| 1 | **eval 参数错位 bug**：`r:eval(script, n, unpack(keys), unpack(argv))` 中 `unpack(keys)` 处于参数列表中间被 Lua 截成 1 个值 → KEYS 丢失、ARGV 左移（n 变成首个 rate）→ 脚本静默返回 `{1}` 无写入。以 resty 注入 debug 定位（`#KEYS=2/n=0.1`） | 已修：显式拼平 args 数组后 `unpack(args)` 置于末尾；修复后 E2E 全绿 |
| 2 | **init 期 userdata**：声明式配置加载时 `entity.config.rules` 是 userdata 代理，fn 内 `#rules` 直接让 Kong 启动崩溃 | 已修：`type(rules) ~= "table"` 防御（校验期才是纯 table） |
| 3 | `build_group_keys` 失败时错误信息被丢弃（`return nil, nil`） | 已修：正确展开第二个返回值 |
| 4 | 测试场景设计错误：预置 R2=0.8（<1）却预期放行——实测 429（wait=2.4→Retry-After=3）头与日志完全自洽 | 非实现问题；改用 R2=1.5 场景后放行路径吻合 |
| 5 | E2E 无法注入 Redis 畸形返回（同 Phase 2 §9-5） | 防御校验以 resty 纯函数单测覆盖（21 断言）；独立脚本 redis-cli 裸跑提供真实 Redis 侧证据 |
| 6 | 新环境缺 k6 | 已装 k6 v0.54.0（~/.local/bin），quota.sh 回归不受阻 |

## 10. 风险分析

- **组指纹重置语义**：改任一条规则 = 整组配额重置（满血新桶），已写进 README/design/rule.md；逃生门仍是 namespace。
- **每请求 1 RTT**：α 的直接代价（用户已拍板）；多规则模式尚未纳入 Phase 4 性能矩阵，届时作为独立测点量化。
- **Cluster 前提**：组内同 slot 由组键保证（单实例 Redis 下无感）；若运维把多规则键手动改出组外，多键 EVAL 将在 Cluster 下失败——文档已标注硬前提。
- **429 `rule` 字段暴露规则结构**：人读标识（`rules[2]:consumer+path`）而非内部序号裸值，诊断价值大于信息泄露风险。
- **init 期 userdata 防御**：校验期语义依赖 Admin API / `kong validate` 路径；`kong.yml` 内嵌 rules 的声明式文件在 init 期不触发该检查（取决于 Kong 加载路径），生产建议以 Admin API 下发（现有部署形态即如此）。

## 11. 是否通过验收

**通过（自验）。** spec 5 条 ADDED 需求 × scenario 对照：多桶全或无原子（§7-10/11/14）、组键与组指纹（§7-13 + rules.sh 场景③）、配置约束（§7-1~8）、响应语义（§7-15~17）、单规则零回归（§7-20~22）。**无 NOT RUN 项**（§9-5 记录测试方式差异：单测替代 E2E 注入）。

人工验收待用户确认；建议抽跑 `./bench/rules.sh` 与 Phase 2 手册 429 Case 做对照。

## 12. 下一阶段建议

1. **Phase 4（性能与库存生命周期）**：EVALSHA+NOSCRIPT（多键脚本一并迁）、batch×RPS 矩阵（多规则模式作为独立测点）、非均匀流量滞留量化、单规则 batch>1 的 L2 优雅归还（防重复归还）。
2. **Phase 5（工程化）**：Prometheus 指标（多规则维度建议按瓶颈规则标注）、结构化日志（替换 RL-DEBUG）、L3 租约对账、长稳验收。
3. **β 增强（独立 change）**：多规则本地多池租约 + 扣-验-滚，复用 α 的组键与脚本骨架。
