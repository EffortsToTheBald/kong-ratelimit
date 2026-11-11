# Spec Delta

## ADDED Requirements

### Requirement: 多维维度组合独立计数
limit_by 的维度组合必须（MUST）参与 Redis key 的 hash tag 计算：不同维度组合映射到不同桶；相同组合与相同维度值稳定映射到同一个桶；任一维度值不同即分桶。

#### Scenario: ip+path 组合下不同 path 独立计数
- **WHEN** 配置 limit_by=[ip, path]、limit=2，依次请求 /echo 与 /echo/foo 各 2 次
- **THEN** 两条路径各有 2 个请求放行（第 3 个同路径请求返回 429），互不共享配额

#### Scenario: 维度顺序不同即不同桶
- **WHEN** 分别以 limit_by=[ip, path] 与 limit_by=[path, ip] 下发同值配置
- **THEN** 两者产生不同指纹、不同 key，互不共享桶

### Requirement: method 维度按 HTTP 方法分桶
method 维度必须（MUST）以请求的 HTTP 方法作为取值参与 key 计算。

#### Scenario: GET 与 POST 分桶
- **WHEN** 配置 limit_by=[method]、limit=1，先发 GET 再发 POST
- **THEN** 两个请求都被放行（各自方法桶的首次），随后同方法第二次请求返回 429

### Requirement: header 维度按指定头取值分桶
header 维度必须（MUST）以 `header_name` 指定头的取值作为维度值；该头缺失的请求必须（MUST）共用同一缺失哨兵桶，不与任何具名值桶共享。

#### Scenario: 不同头值分桶、缺失值共用哨兵
- **WHEN** 配置 limit_by=[header]、header_name=X-Tenant、limit=1，携带 X-Tenant: a 与 X-Tenant: b 各 1 次，再各发 1 次，最后发 1 次不带该头
- **THEN** a、b 首次均放行；a、b 各自第二次与"无头"请求均返回 429，且无头请求不占用 a/b 的桶

### Requirement: consumer 维度按认证身份分桶
consumer 维度必须（MUST）以认证插件解析出的 consumer 身份作为取值；未认证请求共用 anon 哨兵桶。

#### Scenario: 认证后不同 consumer 独立配额
- **WHEN** 路由启用 key-auth，consumer alice/bob 各持有效 key，配置 limit_by=[consumer]、limit=1
- **THEN** alice 与 bob 各自首个带 key 请求放行、第二个返回 429，两者配额互不影响

#### Scenario: 未认证请求共用 anon 桶
- **WHEN** 同上配置下发送不带 key 的请求
- **THEN** 全部落入 anon 桶计数（不与 alice/bob 桶共享）

### Requirement: route/service 维度参与 key 计算
route 与 service 维度必须（MUST）以命中的 route.id / service.id 作为取值参与 key 计算；未命中时使用哨兵值。

#### Scenario: route 维度生效
- **WHEN** 配置 limit_by=[route]、limit=1 且请求命中已有路由
- **THEN** key 中含该 route 的 id 取值，首个请求放行、第二个返回 429

### Requirement: header 维度的 header_name 配置前置校验
limit_by 含 header 而 header_name 缺失/为空的配置必须（MUST）在配置下发时被拒绝（HTTP 400），不得进入运行时。

#### Scenario: 坏配置下发即被拒
- **WHEN** 向 Admin API 下发 limit_by=[header] 且未提供 header_name 的插件配置
- **THEN** Admin API 返回 400 并说明 header_name 必填（运行时不再出现 500）

### Requirement: X-RateLimit-Reset 为下一个令牌可用时刻
X-RateLimit-Reset 必须是（MUST）"下一个令牌可用的 Unix 秒"：Redis 授予路径由服务端返回的等待时长推导，本地库存路径为本节点视角（有库存即视为当前可用）；该口径必须（MUST）与 Retry-After 一致（429 时 Reset−now ≈ Retry-After）。

#### Scenario: 429 时 reset 与 Retry-After 同口径
- **WHEN** 桶被耗尽后收到 429
- **THEN** X-RateLimit-Reset 为未来某 Unix 秒，且其与响应时刻的差值等于 Retry-After 秒数（±1 秒容差）

### Requirement: Retry-After 有上限
Retry-After 必须（MUST）不超过配置的 window 秒。

#### Scenario: 小 rate 配置下 Retry-After 被封顶
- **WHEN** 配置 limit=1、window=3600，触发 429
- **THEN** Retry-After ≤ 3600（不出现超过 window 的等待值）

### Requirement: 429 拒绝可观测
每个被 429 拒绝的请求必须（MUST）产生一条包含限流 key、limit 与 batch 的日志，使限流拒绝可与 Redis 故障区分。

#### Scenario: 429 产生判定日志
- **WHEN** 请求因超配额被拒
- **THEN** 日志出现该请求的 key 与 limit 信息，且可由日志检索区分于 503 故障路径

### Requirement: Redis 畸形返回走故障分支
Redis EVAL 返回值不是 3 元数值数组时必须（MUST）视为 Redis 异常：返回 nil 并进入故障分支（默认 503 / 显式容错 degraded），不得基于畸形数据放行、拒绝或抛出 Lua 异常。

#### Scenario: 畸形返回不产生 500 与异常放行
- **WHEN** Redis 对 EVAL 返回畸形数据（如空表或非数值）
- **THEN** 请求得到 503（默认配置）或 degraded 放行（显式容错），日志记录防御性校验失败，无 Lua traceback

### Requirement: shared dict 缺失时启动告警
lua_shared_dict 不可用导致本地库存降级为 worker 私有表时，系统必须（MUST）在启动阶段输出 warning 日志。

#### Scenario: 降级配置启动即告警
- **WHEN** 以移除 KONG_NGINX_HTTP_LUA_SHARED_DICT 的方式启动 Kong
- **THEN** 启动日志出现本地库存降级的 warning，功能仍以 worker 表降级运行
