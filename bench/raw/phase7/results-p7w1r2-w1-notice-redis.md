# Phase 7 performance matrix — measured performance of the current Lease implementation (tag=p7w1r2, Worker=1, log=notice, redisHost=redis, echoHost=echo)

Generated at: 2026-11-14 19:20:01　limit=1000000 window=60s duration=20s RPS=100,500,1000 batch=10

| Scenario | batch | RPS target | Measured RPS | p50 | p95 | p99 | 200 | 429 | RedisQPS | EVAL count | EVALSHA count | SCRIPT_LOAD count | Local hits | slowGrant | leaseGrant | multiGrant | RedisCPU(s) | KongCPU(cores) | Attempt |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| M0-none | 0 | 100 | 100 | 1.20 | 1.90 | 16.45 | 2000 | 0 | 1 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0.008 | 0.085 |
| M0-none | 0 | 500 | 500 | 0.62 | 1.19 | 21.92 | 10001 | 0 | 1 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0.006 | 0.166 |
| M0-none | 0 | 1000 | 1000 | 0.45 | 0.92 | 32.83 | 20003 | 0 | 1 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0.005 | 0.210 |
| A-batch1 | 1 | 100 | 100 | 1.68 | 2.64 | 87.46 | 2000 | 0 | 477 | 0 | 2000 | 0 | 0 | 2000 | 0 | 0 | 0.028 | 0.112 |
| A-batch1 | 1 | 500 | 500 | 0.84 | 1.73 | 76.88 | 10000 | 0 | 2334 | 0 | 10000 | 0 | 0 | 10000 | 0 | 0 | 0.049 | 0.221 |
| A-batch1 | 1 | 1000 | 1000 | 0.63 | 1.32 | 96.66 | 20001 | 0 | 4853 | 0 | 20001 | 0 | 0 | 20001 | 0 | 0 | 0.061 | 0.310 |
| B-batch10 | 10 | 100 | 100 | 1.27 | 2.19 | 83.69 | 2000 | 0 | 89 | 0 | 200 | 0 | 1800 | 0 | 200 | 0 | 0.011 | 0.104 |
| B-batch10 | 10 | 500 | 493 | 0.70 | 3257.81 | 7645.53 | 8253 | 0 | 428 | 0 | 996 | 0 | 7878 | 0 | 996 | 0 | 0.015 | 0.179 |
| B-batch10 | 10 | 500 | 500 | 0.64 | 1.47 | 87.65 | 10001 | 0 | 436 | 0 | 1001 | 0 | 9000 | 0 | 1001 | 0 | 0.017 | 0.180 |
| B-batch10 | 10 | 1000 | 1000 | 0.48 | 1.12 | 92.63 | 20001 | 0 | 864 | 0 | 2004 | 0 | 17997 | 0 | 2004 | 0 | 0.018 | 0.247 |
| C-multi | 0 | 100 | 100 | 1.73 | 2.62 | 76.13 | 2001 | 0 | 760 | 0 | 2001 | 0 | 0 | 0 | 0 | 2001 | 0.031 | 0.118 |
| C-multi | 0 | 500 | 500 | 0.84 | 1.68 | 96.05 | 10001 | 0 | 3801 | 0 | 10001 | 0 | 0 | 0 | 0 | 10001 | 0.061 | 0.211 |
| C-multi | 0 | 1000 | 1000 | 0.63 | 1.27 | 97.44 | 20001 | 0 | 7788 | 0 | 20001 | 0 | 0 | 0 | 0 | 20001 | 0.073 | 0.292 |

## How to read the table

- EVAL count = INFO commandstats cmdstat_eval call delta (single script per group, explainable: A/C 1 per request; B ≈ request count/batch).
- Local hits = [RL-DEBUG] local_hit log line count delta across the three nodes; slowGrant = redis_grant; leaseGrant = lease_grant (the GRANT_LEASE path of the Lease implementation); multiGrant = multi_grant.
- RedisCPU(s) = INFO cpu used_cpu_sys+user delta; KongCPU(cores) = container cgroup cpu.stat usage_usec delta / duration / 1e6 (summed across three nodes).
- Redis QPS = total_commands_processed delta / duration (includes all commands: connections/scripts/read-write).
