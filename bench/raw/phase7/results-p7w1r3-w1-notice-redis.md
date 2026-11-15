# Phase 7 performance matrix — measured performance of the current Lease implementation (tag=p7w1r3, Worker=1, log=notice, redisHost=redis, echoHost=echo)

Generated at: 2026-11-14 19:28:44　limit=1000000 window=60s duration=20s RPS=100,500,1000 batch=10

| Scenario | batch | RPS target | Measured RPS | p50 | p95 | p99 | 200 | 429 | RedisQPS | EVAL count | EVALSHA count | SCRIPT_LOAD count | Local hits | slowGrant | leaseGrant | multiGrant | RedisCPU(s) | KongCPU(cores) | Attempt |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| M0-none | 0 | 100 | 100 | 1.30 | 1.99 | 19.60 | 2001 | 0 | 1 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0.009 | 0.092 |
| M0-none | 0 | 500 | 500 | 0.71 | 1.31 | 18.44 | 10001 | 0 | 1 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0.008 | 0.177 |
| M0-none | 0 | 1000 | 1000 | 0.45 | 0.92 | 31.05 | 20001 | 0 | 1 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0.005 | 0.201 |
| A-batch1 | 1 | 100 | 100 | 1.85 | 2.76 | 99.57 | 2001 | 0 | 475 | 0 | 2001 | 0 | 0 | 2001 | 0 | 0 | 0.030 | 0.115 |
| A-batch1 | 1 | 500 | 500 | 0.89 | 1.80 | 95.92 | 10000 | 0 | 2376 | 0 | 10000 | 0 | 0 | 10000 | 0 | 0 | 0.052 | 0.235 |
| A-batch1 | 1 | 1000 | 989 | 0.62 | 3568.70 | 4005.03 | 16293 | 0 | 4211 | 0 | 17315 | 0 | 0 | 17315 | 0 | 0 | 0.065 | 0.288 |
| A-batch1 | 1 | 1000 | 959 | 0.63 | 3557.05 | 3969.71 | 15668 | 0 | 3747 | 0 | 15861 | 0 | 0 | 15861 | 0 | 0 | 0.053 | 0.268 |
| A-batch1 | 1 | 1000 | 1000 | 0.61 | 1.32 | 81.02 | 20001 | 0 | 4589 | 0 | 20001 | 0 | 0 | 20001 | 0 | 0 | 0.057 | 0.300 |
| B-batch10 | 10 | 100 | 100 | 1.17 | 2.12 | 87.20 | 2001 | 0 | 90 | 0 | 201 | 0 | 1800 | 0 | 201 | 0 | 0.011 | 0.095 |
| B-batch10 | 10 | 500 | 500 | 0.65 | 1.43 | 80.00 | 10001 | 0 | 438 | 0 | 1001 | 0 | 9000 | 0 | 1001 | 0 | 0.017 | 0.184 |
| B-batch10 | 10 | 1000 | 1000 | 0.46 | 1.19 | 122.42 | 20001 | 0 | 878 | 0 | 2001 | 0 | 18000 | 0 | 2001 | 0 | 0.018 | 0.241 |
| C-multi | 0 | 100 | 95 | 1.95 | 3150.56 | 3904.79 | 1897 | 0 | 727 | 0 | 1897 | 0 | 0 | 0 | 0 | 1897 | 0.032 | 0.120 |
| C-multi | 0 | 100 | 100 | 1.77 | 2.64 | 104.18 | 2000 | 0 | 782 | 0 | 2000 | 0 | 0 | 0 | 0 | 2000 | 0.033 | 0.111 |
| C-multi | 0 | 500 | 500 | 0.85 | 1.69 | 84.10 | 10001 | 0 | 3887 | 0 | 10001 | 0 | 0 | 0 | 0 | 10001 | 0.060 | 0.220 |
| C-multi | 0 | 1000 | 1000 | 0.63 | 1.26 | 98.41 | 20001 | 0 | 7790 | 0 | 20001 | 0 | 0 | 0 | 0 | 20001 | 0.074 | 0.297 |

## How to read the table

- EVAL count = INFO commandstats cmdstat_eval call delta (single script per group, explainable: A/C 1 per request; B ≈ request count/batch).
- Local hits = [RL-DEBUG] local_hit log line count delta across the three nodes; slowGrant = redis_grant; leaseGrant = lease_grant (the GRANT_LEASE path of the Lease implementation); multiGrant = multi_grant.
- RedisCPU(s) = INFO cpu used_cpu_sys+user delta; KongCPU(cores) = container cgroup cpu.stat usage_usec delta / duration / 1e6 (summed across three nodes).
- Redis QPS = total_commands_processed delta / duration (includes all commands: connections/scripts/read-write).
