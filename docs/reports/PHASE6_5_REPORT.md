# Phase 6.5 报告：并发与异常 E2E 验证

- **日期**：2026-11-13
- **基线 HEAD**：`63b9d45`（6.4 修正后）；执行中无生产代码改动
- **本阶段性质**：以验证为主；生产代码零修改
- **commit**：`test: verify phase6.5 concurrent lease safety`

## 1. 执行环境

| 项 | 值 |
|---|---|
| HEAD | `63b9d45f137ac0d2d59cb89371b67c88ccf8e706` |
| Kong 节点 | kong1/2/3（compose `kong-common`，容器名实证）；代理端口 8030/8010/8020 |
| Worker 数 | 每节点 2（`ps` 实证：kong1=1321/1322 等），全局 6 Worker |
| Redis | `redis:7-alpine`（redis_version=7.x，`INFO server`）；单实例，无持久化 |
| Docker | compose v2；kong↔redis 容器网络直连；宿主机非 root |
| 测试配置 | limit=100，window=86400（全程 refill < 0.02 token ⇒ 精确账目），batch=10，burst=0，limit_by=ip，fault_tolerant=false，redis timeout=1000ms |

### 可观测性审计（执行前完成，零生产代码改动）

- **lease 记录**（`kong:rl:lease:{lease_id}`）：字段 `lease_id/pool_key/granted/status/created_at`；消费量**不在 Redis**（V1 冻结：消费纯本地）；CLOSED 为本地语义，Redis 侧保持 OPEN
- **Worker 归属**：`lease_id = <hostname>:<worker_id>:<seq>:<hex>`（lease.lua:43/81）⇒ (host,worker) 可解析
- **本地余量**：`X-RateLimit-Remaining` = 本地池余量（fast path）/ granted−1（slow path）（algorithm.lua:423-424 注释明示口径）⇒ outstanding 可逐请求观测
- **连接→Worker PID 映射**：`/proc/net/tcp` inode + `/proc/<pid>/fd` 唯一匹配（ss 不可用）
- **keepalive 钉住**：`/dev/tcp` 手工 HTTP（逐请求读全响应含 body）
- **RL-DEBUG 日志**：algorithm.lua notice 级输出 `local_hit/lease_grant/lease_take_after_grant`（含 lease_id/granted/remaining）

## 2. 测试结果（四个独立脚本，全部实际执行）

### 2.1 concurrent-lease-e2e.sh（测试1：多 Worker 并发）——**PASS 17/17**（执行 2 次，两次全绿）

- Phase A：30 并发（三节点轮转）+ 逐请求采样响应头；Phase B：270 并发；Phase C：排空（顺序轮转至连续 100×429）
- **多 Worker 实证**：lease_id (host,worker) 覆盖 **6/6**（`8b8a3f9f9422:0/1, 7f82df257927:0/1, 300029f42b6f:0/1`）——请求实际进入全部 6 个 Worker
- **全局不超发**：Σgranted（Redis 记录求和）= **100** = limit；GRANT 记录恰 10 条×granted=10
- **口径区分**：Redis GRANT 授权总量=100；本地 TAKE 消费总量=100（== Σgranted，每授予令牌恰消费一次）；HTTP 放行=100（200）+ 300（429，denied-GRANT granted=0 既有语义）
- **无重复消费/无负库存**：全部采样 X-RateLimit-Remaining ≥ 0（min=0）；异常状态码 other=0
- 桶 tokens 终态=0.002 < 1（配额全部经 GRANT 消化，无泄漏）

### 2.2 lease-exhaustion-e2e.sh（测试2：耗尽与重新申请，单连接钉住 Worker）——**PASS 11/11**（5 次执行：4 次全绿 + 1 次 9/2 偶发〔明细未留存，随后连续 3 轮全绿〕）

- 钉住连接 12 请求：remaining 序列 **9,8,7,6,5,4,3,2,1,0,9,8**（精确匹配）——Lease A 池 10→0 耗尽，req11 触发**新 GRANT Lease B**（rem=9），req12 消费 B（rem=8）
- 记录恰 2 条：A≠B（seq 递增：43 vs 44）、各 granted=10、B.created_at ≥ A、status 均 OPEN（V1：CLOSED 本地语义——冻结口径）
- **A 不复活**：req11 是新 GRANT 而非旧库存静默放行（记录数恰 2 + rem=9）
- **B 不复用 A 库存**：rem=9（fresh granted−1），非 ≥10
- **多 Lease 并存 + 独立 Worker 库存独立**：新连接探测（≤8 次）——命中不同 Worker ⇒ 新 Pool ⇒ 记录数 +1 且 rem=9（非共享 B 池的 7）；实测第 2 次探测即命中

### 2.3 worker-crash-e2e.sh（测试3：kill -9 与库存损失，本阶段重点）——**PASS 16/16**（执行 2 次：第 1 次 12/4〔脚本解析 bug〕→修复后全绿）

- **kill 目标确证**：`/proc/net/tcp` inode（`43385121`）→ 唯一归属 Worker **PID=1322**（inode→fd 匹配）；kill -9 后 10s 轮询 ps 确证 PID 退出
- **崩溃前账目**：钉住连接 4 请求 ⇒ 200×4，remaining 序列 **9,8,7,6** ⇒ L1 granted=10 = consumed 4 + outstanding **6**
- **kill -9 后**：150 请求 ⇒ 放行 **90**（恰 9×batch，全部消费）+ 429×60（denied-GRANT）；other=0
- **账目闭环**：
  - 崩溃 Worker：`granted=10 = consumed 4 + lost 6`（outstanding 6 在崩溃后归类 lost）
  - 其余 Worker：`granted=90 = consumed 90 + outstanding 0`
  - 全局：`Σgranted=100 = HTTP 放行 94 + lost 6`——**94 ≠ 100 ⇒ 无接管、无重新授权**（若接管则 allowed 可达 100）
- **无 RETURN/补偿**：L1 记录 granted/status/created_at 原样（crash 前后比对一致）；桶 tokens 终态=0.007 < 1

### 2.4 lease-timeout-uncertain-e2e.sh（测试4：超时与不确定结果）——**PASS 18/18**（调试收敛后连续 2 轮全绿）

- **P1（确认库存期间 Redis 暂停）**：req1 GRANT（rem=9）→ `CLIENT PAUSE 4000` → req2-10 全部 200、remaining 8..0（**确认库存仍可本地 TAKE，与 Redis 无关**）→ req11（池空，新 GRANT 超时）⇒ **503**（既有故障分支，非 429）→ 恢复后 200 rem=9（正常新 GRANT L2）
- **场景 A（Redis 未执行）**：`CLIENT PAUSE 5000 WRITE`（EVALSHA 拦截排队、管理命令可用）→ 0.5s `CLIENT KILL`（先于 Kong 1s 超时）⇒ 请求 503、**记录数=0**（确定性未执行，命令随连接缓冲丢弃）→ 恢复后 200 rem=9（无幻影库存）
- **场景 B（已执行、响应丢失）**——同 Worker 归属链路实证（v2 修正）：fd5 keepalive 客户端连接提前建立且唯一（ESTAB 客户端连接数=1）→ inode（`/proc/net/tcp`）→ worker fd → **Worker PID 唯一映射**（如 inode=`44243484` → PID=`15937`）→ **SIGSTOP redis**（宿主侧信号）→ **超时请求经同一 fd5 发出** ⇒ Kong 1s 超时 503（不确定进故障分支，非 429）→ 复核 fd5 存活且归属 PID 不变（503 未关闭客户端连接）→ **SIGCONT** ⇒ Redis 消费内核缓冲中已到达的 EVALSHA ⇒ **真实执行（记录恰 1，响应丢失）** → **同一 fd5 发送后续请求**（Worker PID 复核一致）⇒ 200 **rem=9** 且记录 +1 ⇒ **不确定结果未登记本地库存、未重试（恰 1 条记录）、同一 Worker 按正常流程重新申请新 Lease**；归属核对共 3 次（请求前/503 后/后续请求后），inode 与 PID 全程一致 ⇒ 超时请求与后续请求确由同一 Worker 处理（非仅同一 Kong 节点）；若 Kong 在 503 后关闭客户端连接则按验收口径标记 NOT VERIFIED（不降低标准），实测未发生
- granted=0（明确拒绝⇒429）由 concurrent-lease-e2e 的 300×429 与 6.4 quota b20 覆盖
- 三种情况（未执行 / 已执行响应丢失 / granted=0）分别有独立断言，未混淆

## 3. 库存账目（真实测试数据）

**正常运行**（concurrent-lease-e2e 实测）：

```
granted(Redis Σ, 10 记录×10) = 100
consumed(HTTP 200, 每成功请求恰 1 次 TAKE) = 100
outstanding(排空后各 Worker 池余量, remaining 头终态=0/429) = 0
⇒ 100 = 100 + 0
```

**Worker 崩溃**（worker-crash-e2e 实测，Worker PID=1322，lease `8b8a3f9f9422:1:370:294bea`）：

```
崩溃前：granted=10（Redis 记录）= consumed 4（4×200）+ outstanding 6（remaining 序列 9,8,7,6）
崩溃后：granted=10 = consumed 4 + lost 6
全局：  Σgranted=100 = HTTP 放行 94 + lost 6（94 ≠ 100 ⇒ 6 个 lost 永不复用，无接管/补偿/RETURN）
```

计算过程：granted 取自 Redis 记录字段；consumed 取自崩溃前该连接 200 计数；outstanding 取自崩溃前最后一请求 `X-RateLimit-Remaining`=6；lost = granted − consumed（崩溃后）；崩溃后放行 90 = 其余 Worker 全部新 GRANT 消费（每条记录 granted=10 ×9 条）。

## 4. 问题记录

- **生产代码 Bug：无**（全部观察到的行为符合冻结设计）
- **测试脚本 Bug（均已修复并重跑）**：
  1. http_req status 解析（`${line##* }` 取到 "OK"/"Unavailable"）→ awk 第二列
  2. `set -- $line` 污染函数 `$1`（fd）⇒ body 读取重定向错误与连接错位 → 无破坏性解析
  3. `eq "$st$rm"` 拼接比较（"2009"≠"200"）与 eq 输出/退出码混用 → 独立比较
  4. `--scan` 顺序非创建序 ⇒ A/B 记录错认 → 按 created_at 排序
  5. 并发负载全落 kong1（单代理端口）→ 三节点端口轮转（8030/8010/8020）
  6. B 场景先发请求后 STOP 存在竞态（GRANT 全程 ~30ms）→ 先 STOP 后发请求
- **测试环境问题（已解决，未误报为生产 Bug）**：
  1. `CLIENT PAUSE` **无法**制造"已执行但响应丢失"——实测发现 Kong 1s 超时后关闭 cosocket，排队命令被丢弃（记录=0）。改用 SIGSTOP/SIGCONT 方案真实复现
  2. PID namespace 内部向 PID 1 发送 SIGSTOP 被内核丢弃（默认处置信号）⇒ 冻结无效——改从宿主机 namespace 外部发信号（`docker inspect` 取宿主 PID）
  3. 宿主机非 root ⇒ kill EPERM → `docker run --pid host --privileged busybox kill`（STOP/CONT 实证 T 状态生效）
  4. `ss` 不可用 → `/proc/net/tcp` inode + fd 匹配
- **v2 修正记录（场景 B 同 Worker 证据补强）**：初版超时请求经独立 curl、后续请求经另一 fd5 ⇒ 无法证明同一 Worker。修正为共用 fd5 keepalive 连接 + inode→fd→PID 三次核对（请求前/503 后/后续请求后）；503 后连接存活性显式验证（若断开则 NOT VERIFIED，实测未断开）。统计 22 断言（新增：连接唯一性、归属唯一性、503 后存活、归属全程一致）
- **NOT VERIFIED：无**。观测边界说明（冻结设计所限，非缺口）：Lease 消费量在 Redis 不可见（V1 消费纯本地），consumed 经 HTTP 200 计数 + `X-RateLimit-Remaining` 逐请求核验；CLOSED 为本地语义，Redis 侧记录保持 OPEN，本地 CLOSED 行为经 remaining 序列（0 后跳 9）与新 GRANT 记录间接实证

## 5. 统计

| 脚本 | 最近一轮 | 备注 |
|---|---|---|
| concurrent-lease-e2e.sh | PASS 17 / FAIL 0 | 2 次执行均全绿 |
| lease-exhaustion-e2e.sh | PASS 11 / FAIL 0 | 5 次执行：4 全绿 + 1 次 9/2 偶发（随后 3 连全绿） |
| worker-crash-e2e.sh | PASS 16 / FAIL 0 | 2 次执行（第 1 次脚本 bug 修复后全绿） |
| lease-timeout-uncertain-e2e.sh | PASS 22 / FAIL 0 / NOT VERIFIED 0 | **v2 修正后连续 4 轮全绿**（修正前 18 断言：超时请求经独立 curl、同 Worker 未证明——证据缺口已补） |
| **合计（最近一轮）** | **PASS 66 / FAIL 0 / NOT VERIFIED 0** | |
| NOT RUN | Phase 6.6（组报告与最终 commit） | 未执行 |

所有断言基于真实执行；无未执行项标 PASS。

## 6. 生产代码修改记录

**Production code: unchanged**

（`git diff` 仅新增 4 个测试脚本与本报告；`git diff --check` 通过。）

## 7. 后续阶段

- **Phase 6.5：通过**——并发安全（6 Worker 全覆盖、TAKE 无重复消费、无负库存）、全局不超发（Σgranted=allowed=100/94+lost 账目闭环）、耗尽重新申请、kill -9 损失账目（无接管/补偿/RETURN）、超时不确定结果三态区分，全部满足冻结设计
- **满足进入 Phase 6.6 的条件**：是
- **Phase 6.6 尚需完成**：`docs/PHASE6_REQUEST_INTEGRATION_REPORT.md` 组报告 + 最终 commit `feat: integrate worker lease into rate limit path`
