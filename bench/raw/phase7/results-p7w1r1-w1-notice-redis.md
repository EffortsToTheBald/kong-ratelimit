# Phase 7 performance matrix — measured performance of the current Lease implementation (tag=p7w1r1, Worker=1, log=notice, redisHost=redis, echoHost=echo)

Generated at: 2026-11-14 19:12:24　limit=1000000 window=60s duration=20s RPS=100,500,1000 batch=10

| Scenario | batch | RPS target | Measured RPS | p50 | p95 | p99 | 200 | 429 | RedisQPS | EVAL count | EVALSHA count | SCRIPT_LOAD count | Local hits | slowGrant | leaseGrant | multiGrant | RedisCPU(s) | KongCPU(cores) | Attempt |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| M0-none | 0 | 100 | 92 | 1.39 | 3100.52 | 3838.23 | 1849 | 0 | 1 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0.009 | 0.090 |
| M0-none | 0 | 100 | 100 | 1.25 | 1.84 | 14.05 | 2000 | 0 | 1 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0.009 | 0.089 |
| M0-none | 0 | 500 | 500 | 0.63 | 1.22 | 16.96 | 10001 | 0 | 1 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0.007 | 0.148 |
| M0-none | 0 | 1000 | 1000 | 0.44 | 0.89 | 11.50 | 20001 | 0 | 1 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0.005 | 0.217 |
| A-batch1 | 1 | 100 | 100 | 1.79 | 2.66 | 87.33 | 2001 | 0 | 487 | 0 | 2001 | 0 | 0 | 2001 | 0 | 0 | 0.030 | 0.111 |
| A-batch1 | 1 | 500 | 500 | 0.89 | 1.86 | 185.26 | 10001 | 0 | 2199 | 0 | 10001 | 0 | 0 | 10001 | 0 | 0 | 0.047 | 0.210 |
| A-batch1 | 1 | 1000 | 1000 | 0.61 | 1.27 | 107.65 | 20001 | 0 | 4845 | 0 | 20001 | 0 | 0 | 20001 | 0 | 0 | 0.063 | 0.306 |
| B-batch10 | 10 | 100 | 100 | 1.31 | 2.31 | 81.35 | 2000 | 0 | 89 | 0 | 200 | 0 | 1800 | 0 | 200 | 0 | 0.012 | 0.099 |
| B-batch10 | 10 | 500 | 500 | 0.69 | 1.51 | 118.26 | 10001 | 0 | 439 | 0 | 1001 | 0 | 9000 | 0 | 1001 | 0 | 0.017 | 0.185 |
| B-batch10 | 10 | 1000 | 981 | 0.48 | 3475.65 | 3961.32 | 16721 | 0 | 736 | 0 | 1678 | 0 | 15073 | 0 | 1678 | 0 | 0.014 | 0.241 |
| B-batch10 | 10 | 1000 | 1000 | 0.48 | 1.10 | 96.30 | 20001 | 0 | 870 | 0 | 2001 | 0 | 18000 | 0 | 2001 | 0 | 0.016 | 0.240 |
| C-multi | 0 | 100 | 100 | 1.70 | 2.58 | 88.09 | 2000 | 0 | 781 | 0 | 2000 | 0 | 0 | 0 | 0 | 2000 | 0.032 | 0.107 |
| C-multi | 0 | 500 | 500 | 0.87 | 1.71 | 93.20 | 10001 | 0 | 3893 | 0 | 10001 | 0 | 0 | 0 | 0 | 10001 | 0.063 | 0.223 |
| C-multi | 0 | 1000 | 1000 | 0.60 | 1.26 | 90.75 | 20000 | 0 | 7787 | 0 | 20000 | 0 | 0 | 0 | 0 | 20000 | 0.072 | 0.306 |

## How to read the table

- EVAL count = INFO commandstats cmdstat_eval call delta (single script per group, explainable: A/C 1 per request; B ≈ request count/batch).
- Local hits = [RL-DEBUG] local_hit log line count delta across the three nodes; slowGrant = redis_grant; leaseGrant = lease_grant (the GRANT_LEASE path of the Lease implementation); multiGrant = multi_grant.
- RedisCPU(s) = INFO cpu used_cpu_sys+user delta; KongCPU(cores) = container cgroup cpu.stat usage_usec delta / duration / 1e6 (summed across three nodes).
- Redis QPS = total_commands_processed delta / duration (includes all commands: connections/scripts/read-write).
