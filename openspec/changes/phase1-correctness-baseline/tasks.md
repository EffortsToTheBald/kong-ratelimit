# Tasks

> 规格依据：`specs/rate-limiting/spec.md`；实现依据：`design.md`（D1–D8）。每个任务自带验证方式；未执行/无法执行的验证必须在 `reports/phase-1-correctness.md` 中标 NOT RUN，禁止编造结果（rule.md 15.1-7）。
>
> 执行约定（2026-11-11 与用户对齐）：① apply 按任务组推进，每组完成后自测并简报，可随时纠偏；② **每个任务组结束打一个 commit**（组 1 的 1.1 即基线 commit），保证组级可回滚；③ spec 覆盖策略为按 change 增量——本 capability 其余对外行为（429/Retry-After/TTL/响应头等）在后续 change 各自补充进 spec。

## 1. 回滚基线与环境自检

- [x] 1.1 补 `.gitignore`（`bench/out/` 等测试产物），`git add -A && git commit` 打基线 commit；验证：`git log --oneline` 出现基线提交、`git status` 干净（design D8）
- [x] 1.2 环境自检：`docker compose up -d`、三节点管理面 `/status` 可达、`redis-cli ping` 正常；验证：`docker compose ps` 全部运行中且 `curl -s http://localhost:8031/status` 返回 200；环境不可用时在报告中记录并暂停后续任务

## 2. Redis Lua 时间戳单调（P0-4，design D5）

- [x] 2.1 修改 `lib/redis.lua` 内嵌脚本：补充与 `ts = now` 收进 `if now > ts` 分支，`HSET` 回写分支内 ts 而非裸 `now`；验证：`redis-cli --eval redis/token_bucket.lua` 对预置"未来 ts"的 key 执行，返回不补充且 hash 中 ts 未回退
- [x] 2.2 同步修改 `redis/token_bucket.lua` 使两份脚本逐字一致；验证：两段脚本 diff 为空（P2-3 双源问题记录在案、不合并）
- [x] 2.3 正常路径回归：耗尽桶后短等待再请求，令牌按 `elapsed × rate` 补充且封顶 burst；验证：时序 curl 实测数据记入报告（对应 spec"补充量符合速率公式"场景，rule.md 测试 D 的数据采集前置）

## 3. 决策主流程修复（design D3/D4/D6）

- [x] 3.1 `algorithm.lua:check()` 将 `grant` 的 nil 判定前移到任何 `granted.*` 解引用之前，失败走 `kong.log.err` + `return nil, err`；验证：停止 Redis 发一次请求（当前默认 fault_tolerant=true），日志出现"failing open"且**无 Lua traceback、无 500**（对应 spec"Redis 故障不得产生 HTTP 500"场景）
- [x] 3.2 实现 batch=1 短路：`resolve_batch` 前置，`batch==1` 时跳过 `store.take`/`store.fill`；验证：batch=1 压一轮后日志中 `local_hit`/`local_fill` 计数为 0（对应 spec"batch=1 不产生本地库存"场景）
- [x] 3.3 修正 IP 回退：`kong.client.get_remote_ip` 改为 PDK 真实存在的 `kong.client.get_ip()`；验证：单节点 `curl -i :8030/echo` 正常 200 且带 `X-RateLimit-*` 头（行为不变，仅消除潜在 nil 调用）

## 4. 策略指纹进 Key（P0-1，design D1）

- [ ] 4.1 在 `algorithm.lua` 新增纯函数 `policy_fingerprint(conf)`（FNV-1a 32-bit → 8 位小写 hex；输入 limit、window、解析后 burst、limit_by 顺序、header_name(仅 header 维度时)；不依赖 kong.*），`build_key` 输出 `kong:rl:{rl:p=<hex>:dim=val:...}`；验证：`resty -e`（Kong 镜像内或本机 lua5.1）直接调用该函数打印指纹
- [ ] 4.2 指纹性质验证（脚本化）：改 limit/window/burst/limit_by 顺序/含 header 的 header_name 任一项 ⇒ 指纹变；`burst=0` 与 `burst=limit` ⇒ 同值；只改 batch ⇒ 指纹不变；验证：验证脚本的断言全部通过并记入报告
- [ ] 4.3 跨配置隔离实测（spec"配置变更不继承旧配额"场景）：先以 limit=1000 放行若干请求，切 limit=100 后立即超额请求，全局放行 ≤ 100；验证：三节点下发新配置后 quota 流程实测（不再出现 review 实测的 116 > 100）

## 5. Fail-Closed 默认（P0-2，design D2）

- [ ] 5.1 `schema.lua` `fault_tolerant` 默认改为 false，`kong/kong.yml` 显式 `fault_tolerant: false`；验证：`docker compose restart kong*` 后未显式配置 fault_tolerant 的实例，停 Redis 请求返回 503（spec"停止 Redis 后默认返回 503"场景）
- [ ] 5.2 文档同步：README §7 验收清单 degraded 行、§5 batch 表注、`docs/design.md` §4.6/§7 故障模式、§9 取舍表、§12 key 设计（含 `p=` 指纹与"策略变更即满血新桶"代价）；验证：grep 全仓 `fault_tolerant`/key 格式表述一致，无残留 fail-open 默认描述
- [ ] 5.3 容错模式保留验证：显式 `fault_tolerant=true` 时停 Redis 放行且带 `X-RateLimit-Status: degraded`，恢复后正常；验证：手动配置下发 + `docker compose stop/start redis` 实测（spec"容错模式降级放行"场景，rule.md 测试 C 的显式容错分支）

## 6. 压测脚本收敛（P0-6 + P0-5 断言，design D7）

- [ ] 6.1 `bench/common.sh` 的 `kong_config_json` 增加 namespace 参数并显式写 `fault_tolerant:false`；`quota.sh`/`matrix.sh` 每轮生成独立 namespace；验证：连续两轮 `redis-cli KEYS 'kong:rl:*'` 前缀/namespace 段不同，无跨轮残留
- [ ] 6.2 `bench/quota.sh` 增加每节点断言：k6 summary 的 `requests_kong1/2/3` 逐一严格等于 PER_NODE，否则脚本失败退出；验证：正常轮通过；人为传入非整除 VUS 组合时脚本失败（fail loudly）

## 7. IP 维度回归测试（P0-3 收尾，design D6）

- [ ] 7.1 新增伪造 XFF 场景（如 `bench/xff.sh` 或 quota.sh 变体）：同源 IP、limit=1、batch=1，携带不同伪造 `X-Forwarded-For` 反复请求；验证：仅首个请求 200，其余全部 429（spec"伪造 XFF 不产生新桶"场景）

## 8. Phase 1 集成验收（rule.md 测试 A–D + 报告）

- [ ] 8.1 测试 A+B（batch=1 严格基线）：3 节点 × 150 并发，期望 allowed=100 / limited=350 / other=0，且每节点断言通过、本地库存命中 0；验证：`./bench/quota.sh -l 100 -b 1 -p 150` 全绿（spec"batch=1 全局恰好放行 limit 个"场景）
- [ ] 8.2 测试 B 变体（batch=20 不超发与下界）：期望 allowed ∈ [40, 100] 且多次轮次观察波动并记录（不做 Phase 4 的 10 次重复矩阵）；验证：`./bench/quota.sh -l 100 -b 20 -p 150` 输出落在区间（spec"batch=20 放行数不超过 limit"与"batch=20 均匀流量下放行数达到下界"场景）
- [ ] 8.3 测试 C（故障策略双路径）：默认配置 → 503 不打上游；显式 fault_tolerant=true → degraded 放行；验证：两分支实测数据齐全（与 5.1/5.3 同源，此处做全流程复核）
- [ ] 8.4 测试 D（令牌补充）：以 2.3 采集的数据核对 `tokens += elapsed × rate`、封顶 burst、回拨场景不重复计费；验证：报告含实测时序表
- [ ] 8.5 汇总 `reports/phase-1-correctness.md`：严格按 rule.md §13 十二节格式（含环境说明：WSL mirrored、端口 8030/6380、代理拉镜像），未执行项标 NOT RUN；验证：报告覆盖 8 个测试组且与原始日志/summary 文件对应；人工验收通过后提交组 8 的 commit（回滚锚点由各任务组的组级 commit 共同构成）

## Workflow follow-up

- 人工验收通过后执行 `openspec archive phase1-correctness-baseline`（需先确认 reports/phase-1-correctness.md 已入 `reports/`）。
- 验收遗留的 P1/P2 清单（reset/remaining 口径、EVALSHA、Retry-After 上限、双源脚本合并、`.gitignore` 之外的 P2-5 收尾等）作为下一个 change 的输入，不在本 change 内展开。
