# Phase 7 performance matrix — measured performance of the current Lease implementation (tag=p7w2r1, Worker=2, log=notice, redisHost=redis, echoHost=echo)

Generated at: 2026-11-14 18:47:44　limit=1000000 window=60s duration=20s RPS=100,500,1000 batch=10

| Scenario | batch | RPS target | Measured RPS | p50 | p95 | p99 | 200 | 429 | RedisQPS | EVAL count | EVALSHA count | SCRIPT_LOAD count | Local hits | slowGrant | leaseGrant | multiGrant | RedisCPU(s) | KongCPU(cores) | Attempt |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| M0-none | 0 | 100 | 100 | 1.26 | 2.12 | 28.59 | 2001 | 0 | 1 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0.008 | 0.105 |
| M0-none | 0 | 500 | 500 | 0.58 | 1.36 | 459.12 | 10000 | 0 | 1 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0.006 | 0.157 |
| M0-none | 0 | 1000 | 1000 | 0.47 | 0.97 | 10.76 | 20000 | 0 | 1 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0.006 | 0.229 |
| A-batch1 | 1 | 100 | 100 | 1.66 | 2.65 | 85.09 | 2001 | 0 | 476 | 0 | 2001 | 0 | 0 | 2001 | 0 | 0 | 0.027 | 0.127 |
| A-batch1 | 1 | 500 | 500 | 0.90 | 1.85 | 112.55 | 10001 | 0 | 2425 | 0 | 10001 | 0 | 0 | 10001 | 0 | 0 | 0.059 | 0.251 |
| A-batch1 | 1 | 1000 | 1000 | 0.68 | 1.40 | 80.85 | 20001 | 0 | 4726 | 0 | 20001 | 0 | 0 | 20001 | 0 | 0 | 0.080 | 0.347 |
| B-batch10 | 10 | 100 | 95 | 1.44 | 3147.69 | 3896.85 | 1897 | 0 | 82 | 0 | 193 | 0 | 1704 | 0 | 193 | 0 | 0.011 | 0.120 |
| B-batch10 | 10 | 100 | 92 | 1.40 | 3152.70 | 3890.91 | 1846 | 0 | 80 | 0 | 186 | 0 | 1660 | 0 | 186 | 0 | 0.011 | 0.096 |
| B-batch10 | 10 | 100 | 100 | 1.32 | 2.36 | 115.55 | 2000 | 0 | 90 | 0 | 203 | 0 | 1797 | 0 | 203 | 0 | 0.012 | 0.109 |
| B-batch10 | 10 | 500 | 500 | 0.71 | 1.54 | 90.01 | 10001 | 0 | 431 | 0 | 1003 | 0 | 8998 | 0 | 1003 | 0 | 0.017 | 0.213 |
| B-batch10 | 10 | 1000 | 1000 | 0.50 | 1.18 | 79.35 | 20000 | 0 | 869 | 0 | 2002 | 0 | 17998 | 0 | 2002 | 0 | 0.021 | 0.275 |
| C-multi | 0 | 100 | 95 | 1.95 | 3132.68 | 3886.94 | 1897 | 0 | 709 | 0 | 1897 | 0 | 0 | 0 | 0 | 1897 | 0.031 | 0.115 |
| C-multi | 0 | 100 | 100 | 1.77 | 2.69 | 93.19 | 2000 | 0 | 778 | 0 | 2000 | 0 | 0 | 0 | 0 | 2000 | 0.032 | 0.118 |
| C-multi | 0 | 500 | 500 | 0.93 | 1.77 | 79.87 | 10001 | 0 | 3886 | 0 | 10001 | 0 | 0 | 0 | 0 | 10001 | 0.073 | 0.240 |
| C-multi | 0 | 1000 | 1000 | 0.68 | 1.44 | 97.00 | 20002 | 0 | 7552 | 0 | 20002 | 0 | 0 | 0 | 0 | 20002 | 0.100 | 0.338 |

## How to read the table

- EVAL count = INFO commandstats cmdstat_eval call delta (single script per group, explainable: A/C 1 per request; B ≈ request count/batch).
- Local hits = [RL-DEBUG] local_hit log line count delta across the three nodes; slowGrant = redis_grant; leaseGrant = lease_grant (the GRANT_LEASE path of the Lease implementation); multiGrant = multi_grant.
- RedisCPU(s) = INFO cpu used_cpu_sys+user delta; KongCPU(cores) = container cgroup cpu.stat usage_usec delta / duration / 1e6 (summed across three nodes).
- Redis QPS = total_commands_processed delta / duration (includes all commands: connections/scripts/read-write).
