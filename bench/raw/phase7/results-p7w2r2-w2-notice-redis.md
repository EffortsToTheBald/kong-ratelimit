# Phase 7 performance matrix — measured performance of the current Lease implementation (tag=p7w2r2, Worker=2, log=notice, redisHost=redis, echoHost=echo)

Generated at: 2026-11-14 18:56:25　limit=1000000 window=60s duration=20s RPS=100,500,1000 batch=10

| Scenario | batch | RPS target | Measured RPS | p50 | p95 | p99 | 200 | 429 | RedisQPS | EVAL count | EVALSHA count | SCRIPT_LOAD count | Local hits | slowGrant | leaseGrant | multiGrant | RedisCPU(s) | KongCPU(cores) | Attempt |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| M0-none | 0 | 100 | 100 | 1.27 | 2.17 | 17.64 | 2001 | 0 | 1 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0.009 | 0.103 |
| M0-none | 0 | 500 | 500 | 0.66 | 1.24 | 24.98 | 10001 | 0 | 1 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0.007 | 0.177 |
| M0-none | 0 | 1000 | 1000 | 0.47 | 0.95 | 14.18 | 20001 | 0 | 1 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0.006 | 0.221 |
| A-batch1 | 1 | 100 | 100 | 1.75 | 2.69 | 74.67 | 2001 | 0 | 490 | 0 | 2001 | 0 | 0 | 2001 | 0 | 0 | 0.028 | 0.126 |
| A-batch1 | 1 | 500 | 461 | 0.99 | 3205.80 | 3947.10 | 8138 | 0 | 2239 | 0 | 9216 | 0 | 0 | 9216 | 0 | 0 | 0.055 | 0.244 |
| A-batch1 | 1 | 500 | 500 | 0.95 | 1.92 | 93.40 | 10001 | 0 | 2394 | 0 | 10001 | 0 | 0 | 10001 | 0 | 0 | 0.062 | 0.261 |
| A-batch1 | 1 | 1000 | 1000 | 0.64 | 1.36 | 86.24 | 20000 | 0 | 4867 | 0 | 20000 | 0 | 0 | 20000 | 0 | 0 | 0.077 | 0.351 |
| B-batch10 | 10 | 100 | 100 | 1.30 | 2.16 | 89.16 | 2001 | 0 | 88 | 0 | 203 | 0 | 1798 | 0 | 203 | 0 | 0.012 | 0.101 |
| B-batch10 | 10 | 500 | 462 | 0.77 | 3154.12 | 3915.49 | 8629 | 0 | 654 | 0 | 1498 | 0 | 7164 | 0 | 1498 | 0 | 0.012 | 0.197 |
| B-batch10 | 10 | 500 | 500 | 0.68 | 1.44 | 87.06 | 10001 | 0 | 392 | 0 | 1003 | 0 | 8998 | 0 | 1003 | 0 | 0.016 | 0.192 |
| B-batch10 | 10 | 1000 | 959 | 0.52 | 3455.46 | 4014.88 | 16494 | 0 | 782 | 0 | 1795 | 0 | 16114 | 0 | 1795 | 0 | 0.017 | 0.280 |
| B-batch10 | 10 | 1000 | 1000 | 0.50 | 1.16 | 94.02 | 20001 | 0 | 877 | 0 | 2002 | 0 | 17999 | 0 | 2002 | 0 | 0.020 | 0.275 |
| C-multi | 0 | 100 | 100 | 1.74 | 2.73 | 90.59 | 2001 | 0 | 780 | 0 | 2001 | 0 | 0 | 0 | 0 | 2001 | 0.031 | 0.121 |
| C-multi | 0 | 500 | 500 | 0.93 | 1.77 | 84.54 | 10001 | 0 | 3897 | 0 | 10001 | 0 | 0 | 0 | 0 | 10001 | 0.074 | 0.239 |
| C-multi | 0 | 1000 | 1000 | 0.69 | 1.46 | 96.73 | 20000 | 0 | 7764 | 0 | 20000 | 0 | 0 | 0 | 0 | 20000 | 0.102 | 0.347 |

## How to read the table

- EVAL count = INFO commandstats cmdstat_eval call delta (single script per group, explainable: A/C 1 per request; B ≈ request count/batch).
- Local hits = [RL-DEBUG] local_hit log line count delta across the three nodes; slowGrant = redis_grant; leaseGrant = lease_grant (the GRANT_LEASE path of the Lease implementation); multiGrant = multi_grant.
- RedisCPU(s) = INFO cpu used_cpu_sys+user delta; KongCPU(cores) = container cgroup cpu.stat usage_usec delta / duration / 1e6 (summed across three nodes).
- Redis QPS = total_commands_processed delta / duration (includes all commands: connections/scripts/read-write).
