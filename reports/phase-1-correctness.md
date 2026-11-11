# 测试报告 —— Phase 1 核心正确性基线

## 1. 测试目的

验证 `phase1-correctness-baseline` change 的 8 项修复（P0-1~P0-6 + nil 解引用修复 + batch=1 短路）全部生效，并使 `rule.md` §14 中"正确性"相关验收行可证明。全部测试基于真实执行结果，未执行的验证一律标 NOT RUN（本次无 NOT RUN 项）。

## 2. 修改文件

| 文件 | 类型 |
|---|---|
| `kong/plugins/rate-limit-advanced/lib/redis.lua` | 修改（ts 单调） |
| `kong/plugins/rate-limit-advanced/lib/algorithm.lua` | 修改（nil 判定前移、batch=1 短路、get_ip 回退、策略指纹 + FNV-1a、负值归一化） |
| `kong/plugins/rate-limit-advanced/schema.lua` | 修改（fault_tolerant 默认 false） |
| `kong/kong.yml` | 修改（fault_tolerant: false） |
| `redis/token_bucket.lua` | 修改（与内嵌脚本双源同步） |
| `bench/common.sh` | 修改（namespace 参数、显式 fault_tolerant:false、assert_per_node_counts） |
| `bench/quota.sh` / `bench/matrix.sh` | 修改（每轮/每用例独立 namespace、每节点断言） |
| `bench/xff.sh` | 新增（伪造 XFF 回归） |
| `README.md` / `docs/design.md` | 修改（故障策略与 key 设计文档同步） |
| `.gitignore` | 新增 |

## 3. 修改内容

1. **策略指纹（P0-1）**：`build_key` 输出 `kong:rl:{rl:p=<hex8>:dim=val:...}`；指纹 = FNV-1a-32(limit, window, 解析后 burst, limit_by 顺序, header_name[仅 header 维度])，**不含 batch**。策略一变即新桶，旧桶/旧库存随 TTL 淘汰。附带修复：LuaJIT `bit.band` 负值经 `%08x` 符号扩展成 16 位的问题（归一化 `% 0x100000000`）。
2. **Fail-Closed 默认（P0-2）**：`fault_tolerant` 默认 true→false；`true` 保留为显式 degraded 放行。
3. **Redis 失败路径（rule.md §9.1 问题A）**：`check()` 中 nil 判定前移到任何 `granted.*` 解引用之前，失败 `kong.log.err` + `return nil, err`。
4. **时间戳单调（P0-4）**：补充与 `ts = now` 收进 `if now > ts` 分支，`HSET` 回写分支内 ts；双源脚本逐字一致。
5. **batch=1 短路**：`resolve_batch` 前置；`batch==1` 跳过 `store.take`/`store.fill`，每请求必经 Redis EVAL。
6. **IP 回退修正（P0-3）**：`kong.client.get_remote_ip`（PDK 不存在）→ `kong.client.get_ip()`；语义文档化（realip/trusted_ips）+ 伪造 XFF 回归测试。
7. **脚本收敛（P0-6/P0-5）**：配置生成器 namespace 参数化（每轮独立）、显式 fail-closed；quota.sh 增加每节点请求数断言（严格等于 PER_NODE）。
8. **回滚基线**：git 基线 commit `3d06fdf`（修复前）+ 组级 commit 链（`352b7fe`/`f081647`/`04cad54`/`f830672`/`4dd3576`/`912eab2`/`5b33762`）。

## 4. 测试环境

| 项 | 值 |
|---|---|
| 宿主 | WSL2 (Ubuntu)，mirrored 网络模式 |
| 部署 | docker compose：3× Kong 3.6.1 DB-less（每节点 2 worker）+ Redis 7-alpine + http-echo |
| 端口 | kong 代理 8030/8010/8020，管理 8031/8011/8021（非 8000：Windows iphlpsvc 占用）；Redis 宿主 6380→容器 6379（宿主 6379 被占） |
| shared dict | `kong_rl 32m`（KONG_NGINX_HTTP_LUA_SHARED_DICT 注入，生效） |
| 镜像 | 经宿主代理 127.0.0.1:7897 拉取 |
| Docker | Engine 29.1.5；本会话用户 tdohs 经 docker 组授权（`sg docker -c` 包裹调用） |
| k6 | v2.3.0（宿主） |
| Redis 持久化 | `--save ""`、无 AOF（测试态） |
| 时间 | 2026-11-11 19:00–19:45 (+08:00) |

## 5. 测试参数

| 测试 | 配置 |
|---|---|
| A+B（batch=1 基线） | limit=100 window=3600 batch=1 limit_by=ip |
| B20（batch=20） | limit=100 window=3600 batch=20 limit_by=ip |
| C（故障） | limit=100 batch=1；a) 无 fault_tolerant 字段 b) fault_tolerant=true |
| D（补充） | limit=60 window=60 batch=1（rate=1/s, burst=60） |
| XFF | limit=1 batch=1，20 个不同伪造 XFF |
| 隔离 | 每轮：`restart kong×3` → FLUSHDB → 独立 namespace 下发 |
| 指纹性质 | resty 容器内直接调用纯函数，10 条断言 |

## 6. 测试命令

```bash
sg docker -c "docker compose restart kong1 kong2 kong3"   # 每轮隔离
sg docker -c "docker compose exec -T redis redis-cli FLUSHDB"
./bench/quota.sh -l 100 -b 1  -p 150     # 测试 A+B
./bench/quota.sh -l 100 -b 20 -p 150     # 测试 B20（×3 轮，含 4.3 轮）
./bench/xff.sh                           # 伪造 XFF 回归
# 故障注入：docker compose stop/start redis + 逐节点 curl
# 回拨：redis-cli HSET <key> ts <未来值> 后请求
# 指纹：docker compose exec kong1 resty -e '...policy_fingerprint...'
```

## 7. 测试结果

| # | 测试 | 结果 | 预期 | 状态 |
|---|---|---|---|---|
| 1 | A+B batch=1 全局配额 | allowed=100 limited=350 other=0 | 恰 100/350/0 | ✅ |
| 2 | A+B 每节点请求数 | 150/150/150（断言通过） | 严格 150×3 | ✅ |
| 3 | A+B 本地库存 | local_hit=0 local_fill=0 redis_grant=450 | 全 0，每请求 1 次 EVAL | ✅ |
| 4 | B20 不超发与下界（3 轮） | allowed=100/100/100，利用率 100.0% | ∈[40,100] 且 ≤100 | ✅ |
| 5 | C-a 默认故障 | 503 ×3 节点，上游响应头 0（未达上游） | 503 且不打上游 | ✅ |
| 6 | C-b 显式容错 | 200 ×3 + `X-RateLimit-Status: degraded` + 上游头 1 | 放行+标记+达上游 | ✅ |
| 7 | D 补充速率 | 耗尽 60×200+10×429；等 5.004s 后恰 5×200（=⌊5.004×1⌋）；桶 tokens=0.532 ≤ burst=60 | ≤⌈t×rate⌉ 且 ≤burst | ✅ |
| 8 | D 时间戳单调（回拨） | 预置 ts=未来 1794400631 → 请求后 tokens 59→58、**ts 保持原值** | 不补充、ts 不回退 | ✅ |
| 9 | 指纹性质（10 断言） | 全绿；limit100=25c15179、limit1000=8039753e（8 位小写 hex） | 见 4.2 断言集 | ✅ |
| 10 | 跨配置隔离 | 同 namespace 切 limit 1000→100 后 450 请求恰放行 100；KEYS 双指纹双桶 | ≤100，不继承（修复前同场景 116） | ✅ |
| 11 | 伪造 XFF | 200=1、429=19（20 个不同伪造 XFF） | 仅首个放行 | ✅ |
| 12 | namespace 轮次隔离 | 两轮 namespace 段不同、同策略指纹一致（e891f3c2） | 无跨轮残留 | ✅ |
| 13 | 每节点断言-正常 | 10/10/10 通过 | 严格相等 | ✅ |
| 14 | 每节点断言-破坏 | VUS=2（15/15/0）→ exit 1 fail loudly | 失败退出 | ✅ |
| 15 | Redis 失败日志 | `algorithm.lua:136 grant failed`（error）→ `handler.lua:29/34 failing open/closed`；traceback/attempt-to 计数 0 | 无 500、无异常栈 | ✅ |

原始证据：`bench/out/{quota-b1,quota-b20,iso-probe,sabotage}.json`（最近一轮覆盖写）；日志计数见 §8。

## 8. 日志分析

- **batch=1 轮**（namespace `rl-1794396919-622257`）：`local_hit=0`、`local_fill=0`、`redis_grant=450`——严格模式语义在运行时被证实，而非仅靠代码阅读。
- **故障分支**：Redis 停止时 DNS 解析失败 → `redis grant failed: connect: [cosocket] DNS resolution failed`（error 级，algorithm.lua:136）→ 按配置分流 `failing closed`（handler.lua:34，默认）或 `failing open`（handler.lua:29，显式容错）。**全仓无 `stack traceback` / `attempt to index` 记录**（修复前此处必抛 Lua 异常）。
- **守恒核算**（隔离探针 namespace `rliso1`，limit=1000 batch=20，90 请求）：30 次 grant×20=600 授出；60 次 local_hit；30 次 fill×19=570。核账：600 = 30（grant 路径消耗）+ 570（fill）；桶 1000−600+0.005 补充=400.005 ✅；本地池 570−60=510 ✅；总剩余 400+510=910=600−90+400 ✅。**无令牌凭空产生或消失**。
- 修复前 review 阶段的历史日志问题（`--since` 混轮日志、宿主机旧脚本）已通过"每轮独立 namespace + 日志按 namespace 过滤"的规程消除。

## 9. 发现的问题（本阶段执行中新发现）

| # | 问题 | 处置 |
|---|---|---|
| 1 | `bench/out/` 曾被 root 拥有 → k6 写不进 summary、quota.sh 读到**陈旧文件**，造成"total=90 allowed=100"的矛盾输出 | 已 `chown tdohs` 修复；建议下阶段在 `assert_prerequisites` 里加写权限预检（P2） |
| 2 | LuaJIT `bit.band` 返回带符号 32 位值，指纹经 `%08x` 符号扩展为 16 位（`ffffffff8039753e`） | 已修复（`% 0x100000000` 归一化）；不影响已发布语义（同值仍同 key） |
| 3 | **同策略下 FLUSHDB 后，旧本地库存仍有效**（90 请求全部命中旧池、未建 Redis 桶） | 非 bug：同策略库存语义合法、误差方向为少发。规程要求每轮 `restart kong`（本次已按规程执行）；租赁生命周期治理归 Phase 4 |
| 4 | quota.sh 对 batch>1 的下界告警在"流量不足以打穿配额"时也会触发（如 -p 30 的冒烟轮） | 说明性告警而非失败，属预期；用法文档注明需满量流量 |
| 5 | batch=1 时 `X-RateLimit-Remaining` 恒为 0（granted−1） | 既有语义，P1-3 统一口径时处理，本阶段不动 |

## 10. 风险分析

- **配置变更 = 新桶满血**：改 limit/window/burst/limit_by 瞬间配额重置。已写入 README/design；运维逃生门是 `namespace`。
- **默认 fail-closed 降低可用性**：Redis 故障期间整体 503。这是 rule.md 既定策略；可用性敏感方显式 `fault_tolerant=true`。
- **回拨期间不补充**：时钟回拨窗口内桶冻结（少发）。Lua 内无法告警，报告中如实记录该限制。
- **32-bit 指纹碰撞**：单项目规则规模下概率可忽略；冲突时扩展为 64 位（布局不变）。
- **同策略跨 FLUSHDB 的本地库存残留**：见 §9.3；Phase 4 需设计租赁有效期/回收协议（回收必须防重复归还）。

## 11. 是否通过验收

**通过（自验）。** rule.md §14 正确性相关验收行对照：

| 验收项 | 状态 |
|---|---|
| Redis Lua 原子令牌桶 / 时间用 Redis TIME / burst 封顶 | ✅（§7-7/8） |
| batch=1 全局配额严格正确 | ✅（§7-1/2/3） |
| batch=N 不超发 | ✅（§7-4，3 轮 + 守恒核算） |
| Key 多维规则组合 / Hash Tag 正确 | ✅（§7-9/10，指纹进 hash tag） |
| shared dict 同节点共享 / 本地库存原子扣减 | ✅（review 已核实 + 本轮守恒核算） |
| Redis 故障 Fail-Closed 默认 / 429 区分 503 | ✅（§7-5/6/15） |
| TTL 与令牌生命周期 | 桶 TTL 2×window 实测存续（50780f62 PTTL≈7147s）；本地库存生命周期治理归 Phase 4 |
| 测试：多节点并发及故障测试 | ✅（§7 全部） |
| 报告：真实执行 | ✅（本文档，无 NOT RUN 项） |

人工验收待用户确认；确认后提交组 8 commit。

## 12. 下一阶段建议

1. **P1 语义批**（建议作为下一个 change）：reset/remaining 口径统一（含 batch=1 恒 0 问题）、EVALSHA+NOSCRIPT 回退、Retry-After 上限、429 路径日志、Redis 返回值防御性校验、header_name 的 schema 级校验（P1-4）、shared dict 降级告警（backend() 接入 init_worker）。
2. **Phase 4（batch 性能与库存生命周期）**：batch×RPS 矩阵 + 非均匀流量场景（Kong1 10% / Kong2 10% / Kong3 80%）验证滞留与利用率；本地库存租赁有效期/空闲回收（须防重复归还）；bench/out 权限预检。
3. **Phase 5（工程化）**：Prometheus 指标、结构化日志（request_id/node/decision）、长稳与节点重启场景。
4. **文档收尾**：`rule.md` §3.2/§3.3 的 key 格式示例尚未含 `p=` 指纹（用户原始文档，未擅改），建议由作者确认后同步；README §7 其余未勾选项随 Phase 2+ 逐项补齐。
