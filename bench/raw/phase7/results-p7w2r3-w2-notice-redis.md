# Phase 7 performance matrix — measured performance of the current Lease implementation (tag=p7w2r3, Worker=2, log=notice, redisHost=redis, echoHost=echo)

Generated at: 2026-11-14 19:04:10　limit=1000000 window=60s duration=20s RPS=100,500,1000 batch=10

| Scenario | batch | RPS target | Measured RPS | p50 | p95 | p99 | 200 | 429 | RedisQPS | EVAL count | EVALSHA count | SCRIPT_LOAD count | Local hits | slowGrant | leaseGrant | multiGrant | RedisCPU(s) | KongCPU(cores) | Attempt |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| M0-none | 0 | 100 | 100 | 1.32 | 2.08 | 18.63 | 2001 | 0 | 1 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0.008 | 0.104 |
| M0-none | 0 | 500 | 500 | 0.71 | 1.29 | 16.54 | 10001 | 0 | 1 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0.008 | 0.185 |
| M0-none | 0 | 1000 | 1000 | 0.49 | 0.99 | 12.95 | 20001 | 0 | 1 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0.007 | 0.224 |
| A-batch1 | 1 | 100 | 95 | 1.92 | 3154.29 | 3913.39 | 1897 | 0 | 461 | 0 | 1897 | 0 | 0 | 1897 | 0 | 0 | 0.026 | 0.114 |
| A-batch1 | 1 | 100 | 96 | 1.92 | 3123.45 | 3890.73 | 1923 | 0 | 469 | 0 | 1923 | 0 | 0 | 1923 | 0 | 0 | 0.027 | 0.120 |
| A-batch1 | 1 | 100 | 100 | 1.83 | 2.77 | 70.97 | 2001 | 0 | 490 | 0 | 2001 | 0 | 0 | 2001 | 0 | 0 | 0.029 | 0.127 |
| A-batch1 | 1 | 500 | 500 | 1.01 | 1.94 | 75.19 | 10001 | 0 | 2441 | 0 | 10001 | 0 | 0 | 10001 | 0 | 0 | 0.064 | 0.283 |
| A-batch1 | 1 | 1000 | 1000 | 0.67 | 1.46 | 81.25 | 20001 | 0 | 4726 | 0 | 20001 | 0 | 0 | 20001 | 0 | 0 | 0.079 | 0.345 |
| B-batch10 | 10 | 100 | 100 | 1.37 | 2.29 | 78.62 | 2000 | 0 | 82 | 0 | 202 | 0 | 1798 | 0 | 202 | 0 | 0.012 | 0.095 |
| B-batch10 | 10 | 500 | 500 | 0.73 | 1.55 | 79.49 | 10001 | 0 | 441 | 0 | 1003 | 0 | 8998 | 0 | 1003 | 0 | 0.019 | 0.211 |
| B-batch10 | 10 | 1000 | 1000 | 0.50 | 1.15 | 87.98 | 20001 | 0 | 862 | 0 | 2003 | 0 | 17998 | 0 | 2003 | 0 | 0.021 | 0.258 |
| C-multi | 0 | 100 | 96 | 1.94 | 3122.55 | 3890.46 | 1924 | 0 | 759 | 0 | 1924 | 0 | 0 | 0 | 0 | 1924 | 0.031 | 0.120 |
| C-multi | 0 | 100 | 100 | 1.84 | 2.75 | 69.46 | 2001 | 0 | 778 | 0 | 2001 | 0 | 0 | 0 | 0 | 2001 | 0.032 | 0.121 |
| C-multi | 0 | 500 | 500 | 0.97 | 1.89 | 91.62 | 10001 | 0 | 3904 | 0 | 10001 | 0 | 0 | 0 | 0 | 10001 | 0.076 | 0.266 |
| C-multi | 0 | 1000 | 1000 | 0.68 | 1.42 | 88.58 | 20000 | 0 | 7775 | 0 | 20000 | 0 | 0 | 0 | 0 | 20000 | 0.102 | 0.339 |

## How to read the table

- EVAL count = INFO commandstats cmdstat_eval call delta (single script per group, explainable: A/C 1 per request; B ≈ request count/batch).
- Local hits = [RL-DEBUG] local_hit log line count delta across the three nodes; slowGrant = redis_grant; leaseGrant = lease_grant (the GRANT_LEASE path of the Lease implementation); multiGrant = multi_grant.
- RedisCPU(s) = INFO cpu used_cpu_sys+user delta; KongCPU(cores) = container cgroup cpu.stat usage_usec delta / duration / 1e6 (summed across three nodes).
- Redis QPS = total_commands_processed delta / duration (includes all commands: connections/scripts/read-write).
