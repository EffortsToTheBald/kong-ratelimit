# Tasks

> 规格依据：`specs/rate-limiting/spec.md`（11 条 ADDED）；实现依据：`design.md`（D1–D9）。延续执行约定：按任务组推进、每组自测简报、每组结束一个 commit、未执行的验证在报告中标 NOT RUN。

## 1. 基线与前置事实核查

- [ ] 1.1 `git add -A && git commit` 打本 change 基线 commit；验证：`git log --oneline` 出现基线提交
- [ ] 1.2 实测 D4 主方案可行性：向 Admin API 下发带 `entity_checks`（conditional+contains）的 schema 修改后，提交 `limit_by=[header]` 无 header_name 的配置，确认返回 400 且 `contains` 对数组生效；验证：curl 实测 400；若不生效则切换 design D4 的 `custom_entity_check` fallback 并记录
- [ ] 1.3 环境自检（沿用 Phase 1 前奏）：三节点 healthy、FLUSHDB 可用；验证：`docker compose ps` 全部 running

## 2. 响应头语义（D1/D2/D8，redis.lua + handler.lua）

- [ ] 2.1 `redis.lua`：脚本 wait 公式统一为 `wait = max(0, (1 - tokens) / rate)`（tokens≥1 时为 0）；同步 `redis/token_bucket.lua`；验证：`diff` 两份脚本主体为空；resty 喂 tokens=2.3/0.7 两样例断言 wait=0/正值
- [ ] 2.2 `handler.lua`：slow path `reset = now + wait`、fast path 按 remaining 分支（>0 → now；=0 → now+⌈1/rate⌉）、`retry_after = min(max(1, ceil(wait)), floor(window))`、429 分支加 notice 日志（key/limit/batch）；验证：limit=100 batch=1 手动耗尽后 429 响应中 `Reset − now ≈ Retry-After`（±1s）；limit=1/window=3600 触发 429 时 `Retry-After ≤ 3600`
- [ ] 2.3 `algorithm.lua`：remaining 口径注释（两路径均为本节点视角）与 reset 传值微调；验证：curl 观察快/慢路径响应头格式一致（均为 Unix 秒）

## 3. 校验与防御（D3/D4/D5）

- [ ] 3.1 `schema.lua` 增加 `entity_checks`（conditional + contains，或 1.2 选定方案）；验证：下发 `limit_by=[header]` 无 header_name → 400；下发合法 header 配置 → 成功；既有无 header 配置下发不受影响
- [ ] 3.2 `redis.lua` 抽出纯函数 `parse_grant_response(res, want)` 并在 grant() 中接入（畸形 → close + nil,err）；验证：resty 单测喂 5 类畸形样例（非 table/长度≠3/granted 非数/granted>want/tokens 非数）全部返回 nil+err，合法样例通过
- [ ] 3.3 `handler.lua` 增加 `_M:init_worker()`（backend 非 shared_dict → log.warn）；验证：移除 KONG_NGINX_HTTP_LUA_SHARED_DICT 临时启动一次（docker compose 环境变量覆盖），启动日志出现降级 warning；恢复正常配置后告警消失
- [ ] 3.4 畸形返回的故障分支验证（结合 3.2）：代码路径确认畸形 → nil,err → handler fail 分支；验证：日志与分支单测证明（E2E 注入不可行，报告中如实记录测试方式）

## 4. 多维验证脚本（D6/D7，bench/dims.sh）

- [ ] 4.1 编写 `bench/dims.sh`：7 场景（[ip,path] 独立 / [method] 分桶 / [header] 双租户+哨兵 / [route] / [service] / [consumer] 双 consumer+anon / 指纹顺序断言），每场景独立 namespace + FLUSHDB，PASS/FAIL 断言；consumer 场景自带 key-auth + alice/bob 声明式配置（/echo-auth 路由）
- [ ] 4.2 执行 `bench/dims.sh` 全绿；验证：7 场景全部 PASS（预期外 FAIL 即停下排查，禁止改验收标准凑绿）
- [ ] 4.3 consumer 场景优先级复核：确认 key-auth（1250）先于本插件（1002）执行、日志无 "attempt to call" 类异常；验证：dims.sh consumer 场景输出 + kong 日志无 error

## 5. 文档同步（D8/D9）

- [ ] 5.1 `README.md`：响应头语义段（Reset=下一令牌可用 Unix 秒、Retry-After≤window、remaining=本节点视角、429 日志）；验证：与实测响应头一致
- [ ] 5.2 `docs/design.md`：§7 响应头语义更新、§9 取舍表补"reset 口径/防御校验"行；验证：grep 无旧语义残留（"窗口重置/now+window"）
- [ ] 5.3 `rule.md` §3.2/§3.3/§3.4：key 格式示例与说明补 `p=` 指纹（输入、"策略变更即新桶"、namespace 逃生门）；验证：grep `kong:rl:{rl:ip=` 旧示例已全部更新
- [ ] 5.4 `docs/review-phase-0.md` 不改（历史记录）；验证：确认未误改

## 6. 集成验收与报告

- [ ] 6.1 回归：Phase 1 关键 case 复跑（batch=1 基线 100/350/0、故障双路径、指纹隔离）；验证：与 Phase 1 结果一致（`test/first-commit.md` 锚点表）
- [ ] 6.2 新语义全量验证：dims.sh + reset/Retry-After/429 日志/400 下发/降级告警逐项留档；验证：覆盖 spec 全部 11 条 ADDED 需求的 scenario
- [ ] 6.3 汇总 `reports/phase-2-dimensions-and-semantics.md`（rule.md §13 十二节格式；未执行项标 NOT RUN）；验证：报告与原始输出/summary 对应；人工验收通过后提交组 6 commit

## Workflow follow-up

- 人工验收通过后执行 `openspec archive phase2-dimensions-and-semantics`（spec 合入主 spec 为 ADDED 追加）。
- 遗留输入：EVALSHA/性能矩阵/库存生命周期/非均匀流量 → Phase 4 change；Prometheus/结构化日志 → Phase 5 change。
