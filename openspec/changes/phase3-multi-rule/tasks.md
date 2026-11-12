# Tasks

> 规格依据：`specs/rate-limiting/spec.md`（5 条 ADDED）；实现依据：`design.md`（D1–D6）。延续执行约定：按组推进、每组自测简报、每组一个 commit、未执行验证在报告标 NOT RUN。

## 1. 基线与前置核查

- [x] 1.1 `git commit` 打本 change 基线（树干净则 `--allow-empty` 锚点）；验证：`git log --oneline` 出现基线提交
- [x] 1.2 实测 D2 的 limit_by 区分语义：entity_check 中比较"rules 非空 + limit_by ≠ 默认值"是否按预期 400；验证：curl 三例（rules+默认 limit_by / rules+显式 limit_by / 仅 limit_by）；不精确则启用退化方案（rules 模式忽略 limit_by + init warn）并记录
- [x] 1.3 环境自检：三节点 healthy、FLUSHDB 可用；验证：`docker compose ps` 全部 running

## 2. 配置模型（D2，schema.lua）

- [x] 2.1 新增 `rules` 数组字段（元素：limit/window/burst/limit_by/header_name；len_max=8）+ 三条 entity_checks（互斥/batch∈{0,1}/上限）；运行时兜底校验同步；验证：四例实测——rules+limit_by 同现 400、rules+batch=20 400、9 条规则 400、合法 2 规则 201
- [x] 2.2 旧配置回归验证：仅 limit_by 的既有配置下发不受影响（201）；验证：Phase 1/2 的 dims 场景用例配置下发成功

## 3. 多键原子脚本（D3/D4，redis.lua + 独立脚本）

- [x] 3.1 新增 `redis/multi_bucket.lua`（独立裸跑脚本）与内嵌 `GRANT_MULTI` 脚本：KEYS=各规则桶键，ARGV=[n, 各规则 rate/burst/ttl]；逻辑=逐桶 refill（TIME 单调/burst 封顶）→ 全检（各桶 ≥1）→ 全扣/全不扣 → 返回 {ok, 各桶 tokens/wait} 或 {ok=0, 不足规则, 各 wait}；验证：两份脚本 diff 为空
- [x] 3.2 redis-cli 裸跑核心场景：预置 R1 tokens=0、R2 tokens=5 → EVAL 后 R1/R2 均 0/5 不变且返回 ok=0+规则序号；预置双桶充足 → EVAL 后各减 1；验证：与 spec 场景一一对应
- [x] 3.3 `redis.lua` 新增 `grant_multi()` 与纯函数 `parse_multi_grant_response(n, res)`（结构/数值/范围防御校验）；验证：resty 单测——畸形样例（长度错/非数/越界/ok 非法）全拒 + 合法样例通过

## 4. 决策与响应语义（D1/D5，algorithm.lua + handler.lua）

- [x] 4.1 `algorithm.lua` 多规则分支：conf.rules 非空 → 组键构造（组指纹 + r<i> 段 + 各规则维度值）→ grant_multi → 组装 decision（remaining=min、reset=瓶颈桶 now+wait、rule 拒绝信息）；验证：resty 或 curl 观察组键形状（KEYS 含组指纹与 r1/r2 段）
- [x] 4.2 `handler.lua` 多规则响应：放行头（Remaining=min/Reset=瓶颈）、429 体含 `rule` 字段、Retry-After=max(wait) 封顶 max(window)、判定日志含拒绝规则；验证：实测 429 响应体与头（预置一空一有）
- [x] 4.3 运行时兜底校验（rules 模式 batch>1 或超 8 条 → 500 misconfigured 双保险）；验证：绕过 schema 直接注入 conf 的单测路径（resty）

## 5. 多维验证脚本（D6，bench/rules.sh）

- [x] 5.1 编写 `bench/rules.sh`：场景①全或无核心（redis-cli 预置一空一有 → 429 且双桶 tokens 不变）；②全够放行各扣 1；③组指纹换桶（改一条规则 → 组指纹段变化）；④响应语义（瓶颈头/429 rule 字段/Retry-After 封顶）；⑤坏配置三类 400；每场景独立 namespace；验证：脚本 PASS/FAIL 断言齐全
- [x] 5.2 执行 `bench/rules.sh` 全绿；验证：全部场景 PASS（FAIL 即停下排查，禁止凑绿）

## 6. 回归、文档与报告

- [x] 6.1 单规则回归：dims.sh 全绿 + quota.sh batch=1 基线（100/350/0）+ 故障双路径抽查；验证：与既有锚点一致
- [x] 6.2 文档同步：README（rules 配置示例与响应头）、docs/design.md（§2/§4 多规则原子性与组键）、docs/architecture.md（决策流程图多规则分支）、rule.md（键结构 §3 与 α 决策记录）；验证：grep 无遗漏/冲突表述
- [x] 6.3 汇总 `reports/phase-3-multi-rule.md`（§13 格式，无 NOT RUN 或如实标注）；验证：覆盖 spec 全部 scenario 与设计决策实测；人工验收通过后提交组 6 commit

## Workflow follow-up

- 人工验收通过后执行 `openspec archive phase3-multi-rule`（spec 追加合入主 spec）。
- 遗留输入：β 本地多池租约、L2 优雅归还、L3 租约对账、多规则模式的性能矩阵测点 → Phase 4/5。
