# 测试报告 —— Phase 2 多维语义与可观测基线

## 1. 测试目的

验证 `phase2-dimensions-and-semantics` 的 11 条 ADDED 需求全部落地：多维限流行为（7 维 + 组合）、响应头语义（Reset/Retry-After）、可观测性（429 日志/降级告警）、防御性行为（畸形 Redis 返回）、配置前置校验（header_name），并确认 Phase 1 已验证行为零回归。

## 2. 修改文件

| 文件 | 类型 |
|---|---|
| `kong/plugins/rate-limit-advanced/schema.lua` | 修改（entity_checks：conditional + contains） |
| `kong/plugins/rate-limit-advanced/handler.lua` | 修改（init_worker 降级告警、429 分支重写：cap/同口径 Reset/判定日志、新增 store 依赖） |
| `kong/plugins/rate-limit-advanced/lib/redis.lua` | 修改（wait 公式统一、parse_grant_response 防御校验） |
| `kong/plugins/rate-limit-advanced/lib/algorithm.lua` | 修改（reset 按口径计算、remaining 口径注释） |
| `redis/token_bucket.lua` | 修改（双源同步） |
| `bench/dims.sh` | 新增（7 场景 8 断言的多维验证） |
| `bench/common.sh` | 修改（kong_config_json 第 6 参 limit_by） |
| `README.md` / `docs/design.md` / `rule.md` | 修改（语义与 key 格式同步） |

## 3. 修改内容（对应 design D1–D9）

1. **D1 Reset 语义**：慢路径 `Reset = now + wait`（脚本 wait 统一为 `max(0,(1−tokens)/rate)`）；快路径 `remaining>0 → now`、`=0 → now+⌈1/rate⌉`；429 由 handler 用封顶后的 Retry-After 推导。
2. **D2 Retry-After 上限**：`min(max(1,ceil(wait)), floor(window))`。
3. **D3 防御校验**：`parse_grant_response(res, want)` 纯函数（3 元数组、granted 整数 ∈[0,want]、tokens/wait 数值、wait≥0），畸形 → close + nil,err → 故障分支。
4. **D4 前置校验**：`entity_checks = {{ conditional = { if_field="config.limit_by", if_match={contains="header"}, then_field="config.header_name", then_match={required=true} } }}`；主方案一次通过，无 fallback。
5. **D5 降级告警**：`init_worker()` 检查 `store.backend()`，非 shared_dict 即 warn。
6. **D6/D7 dims.sh**：7 场景独立 namespace + FLUSHDB + 断言；consumer 场景自带 key-auth（anonymous 指向匿名 consumer）+ alice/bob 的完整声明式配置。
7. **D8/D9 文档**：README 响应头语义表、design §7/§9、rule.md §3 key 格式（`p=` 指纹全量示例更新）。
8. **spec 修正**：header 缺失哨兵桶场景的首个"无头"请求预期由 429 修正为 200（独立哨兵桶，规划时笔误，实现前已修正）。

## 4. 测试环境

与 Phase 1 相同：WSL2（mirrored 网络）、3× Kong 3.6.1 DB-less（每节点 2 worker、kong_rl 32m）、Redis 7 单实例（6380→6379）、Docker Engine 29.1.5、k6 v2.3.0。变更期间容器经历多次重启（schema/代码生效所需）。

## 5. 测试参数

| 验证 | 配置 |
|---|---|
| 429 同口径 | limit=100 window=3600 batch=1 |
| cap 边界 | limit=1 window=3600 |
| 快/慢路径头 | limit=1000 window=60 batch=20 |
| entity_checks | limit_by=[header]（缺/有 header_name）、[ip] |
| dims 7 场景 | 各自 limit 与 limit_by（见 dims.sh），全部 batch=1 |
| consumer | key-auth anonymous=anon-visitor；alice/bob 各持 key；limit=1 |
| 回归 | batch=1 基线 / 故障双路径 / 同 namespace 切 limit 1000→100 |

## 6. 测试命令

```bash
./bench/dims.sh                                    # 多维 7 场景
./bench/quota.sh -l 100 -b 1 -p 150                # Phase 1 回归
docker compose exec kong1 resty -e '...parse_grant_response 样例...'   # 防御校验单测
docker compose exec kong1 resty -e '...policy_fingerprint 顺序断言...'
curl -X POST :8031/config -d '<坏/好配置>'          # entity_check 实测
docker run --name p2degrade -e KONG_DATABASE=off ... kong:3.6   # 降级启动告警
```

## 7. 测试结果

| # | 验证 | 结果 | 预期 | 状态 |
|---|---|---|---|---|
| 1 | dims 场景1 [ip,path] | 200200200200429429 | 两路径独立 | ✅ |
| 2 | dims 场景2 [method] | 200200429429 | GET/POST 分桶 | ✅ |
| 3 | dims 场景3 [header] | 200200429429200429 | 双租户独立 + 缺失哨兵独立 | ✅ |
| 4 | dims 场景4 [route] | key 含 `route=a0233861-…`，200/429 | route.id 进 key | ✅ |
| 5 | dims 场景5 [service] | key 含 `service=adbd70b3-…`，200/429 | service.id 进 key | ✅ |
| 6 | dims 场景6 [consumer] | 200429200429200429（alice/bob/anon） | 认证身份分桶 + anon 独立 | ✅ |
| 7 | consumer 无 Lua 异常 | attempt to call = 0 | key-auth 先于限流 | ✅ |
| 8 | dims 场景7 指纹顺序 | 25c15179 ≠ 51a445f1 | 顺序参与指纹 | ✅ |
| 9 | 429 同口径 | Retry-After=36 且 Reset−now=36 | ±1s 一致 | ✅ |
| 10 | Retry-After 上限 | limit=1/w=3600 → Retry-After=3600 | ≤ window | ✅ |
| 11 | 快/慢路径 Reset | 均为当前 Unix 秒（有库存 ⇒ 下一令牌已可用） | Unix 秒、本节点视角 | ✅ |
| 12 | entity_check 拒绝 | 坏配置 400（`header_name: required field missing`） | 下发即拒 | ✅ |
| 13 | entity_check 放行 | 合法 header 配置 201、既有 ip 配置 201 | 不误伤 | ✅ |
| 14 | 防御校验单测 | 10 类畸形全拒 + 2 合法通过 | 畸形 → nil+err | ✅ |
| 15 | 降级告警（负向） | 正常启动 0 条 | 不误报 | ✅ |
| 16 | 降级告警（正向） | 无 shared dict 启动 → `[warn] ... 降级为 worker_table`（两 worker 各一条） | 启动即告警 | ✅ |
| 17 | 回归：batch=1 基线 | 100/350/0 + 每节点 150 断言 | 与 Phase 1 一致 | ✅ |
| 18 | 回归：故障双路径 | 默认 503；显式容错 200+degraded | 与 Phase 1 一致 | ✅ |
| 19 | 回归：指纹隔离 | 同 ns 切 limit 1000→100 → 恰 100×200；双指纹 `8039753e`/`50780f62` 与锚点一致 | 零继承 | ✅ |

## 8. 日志分析

- 429 判定日志：`rate-limit-advanced: 429 key=<key> limit=100 batch=1`（notice 级，实测出现），与故障路径的 error/warn 日志可检索区分。
- consumer 场景（key-auth 在前）全程无 `attempt to call` 异常。
- 降级告警仅在缺失 shared dict 的启动出现（正向 2 条/实例、负向 0 条）。
- entity_check 的 400 错误体含可读字段定位（`config.header_name: required field missing`）。

## 9. 发现的问题（执行中新发现）

| # | 问题 | 处置 |
|---|---|---|
| 1 | `kong_config_json` 硬编码 `limit_by:["ip"]`，无 limit_by 参数——dims 场景 1 首跑全部按 ip 计数而 FAIL | 已修：增加第 6 参（默认 `["ip"]` 保持既有调用兼容） |
| 2 | spec 场景笔误：header 缺失哨兵桶的首个"无头"请求应放行（全新桶）而非 429 | 实现前发现，delta 已修正；dims 场景 3 按修正后预期通过 |
| 3 | 组 6 回归脚本 `mk()` limit 硬编码 100，首跑"回归 3"实为两轮同 limit 换 ns（无效验证） | 如实记录；已参数化重跑，修正版结果见 §7-19 |
| 4 | dims 场景 3 初版配置（无 header_name）被 400 拒绝 | 非问题——恰为前置校验的又一实证（配置生成器遗漏字段即被拦截） |
| 5 | E2E 无法注入 Redis 畸形返回 | 防御校验以 resty 纯函数单测覆盖（10 畸形 + 2 合法）；grant→check→fail 分支的接线为直接代码路径，fail 分支行为已由 Phase 1 停 Redis 实测佐证 |

## 10. 风险分析

- `Reset=now` 可能被客户端误读为"窗口已重置"——语义是"下一令牌已可用"，README/design 已明确令牌桶模型与"本节点视角"。
- 快路径 `Reset=now+⌈1/rate⌉` 为保守近似（Redis 何时再授予本地不可知）。
- 防御校验面仅覆盖 EVAL 返回结构（不涉业务语义），误判面极小；`wait<0` 也纳入畸形（合法路径恒 ≥0）。
- 429 notice 日志在高拒绝率下放大日志量（与 RL-DEBUG 同量级），Phase 5 结构化日志统一治理。

## 11. 是否通过验收

**通过（自验）。** spec 11 条 ADDED 需求 × scenario 对照：§7-1/3（多维组合）、§7-2（method）、§7-3（header）、§7-6/7（consumer）、§7-4/5（route/service）、§7-12/13（前置校验）、§7-9/11（Reset 语义）、§7-10（Retry-After 上限）、§7-8（429 可观测）、§7-14（防御校验）、§7-15/16（降级告警）；Phase 1 回归 §7-17/18/19 全绿。**无 NOT RUN 项**（§9-5 记录测试方式差异：单测替代 E2E 注入）。

人工验收待用户确认；确认后提交组 6 commit（本报告所在组）。

## 12. 下一阶段建议

1. **Phase 4（性能与库存生命周期）**：EVALSHA+NOSCRIPT、batch×RPS 矩阵（M0/1/5/20/auto × RPS）、非均匀流量滞留量化、节点重启场景、库存回收设计（以矩阵数据为输入）、`bench/results.md` 填充 design.md §8 的三个 ⟨TODO⟩。
2. **Phase 5（工程化）**：Prometheus 指标、结构化日志（替换 RL-DEBUG）、长稳验收 final-acceptance.md。
3. **rule.md 遗留待做**：特殊字符转义/拼接歧义、规则级 ID、路径归一化（见 rule.md §3.4 更新后的清单）。
