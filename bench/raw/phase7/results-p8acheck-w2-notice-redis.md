# Performance matrix (measured on the current implementation; tag=p8acheck, Worker=2, log=notice, redisHost=redis, echoHost=echo; limit=1000000 window=60s duration=20s RPS=100,500,1000 batch=10)

Generated at: 2026-11-14 20:28:47　limit=1000000 window=60s duration=20s RPS=100,500,1000 batch=10

| Scenario | batch | RPS target | Measured RPS | p50 | p95 | p99 | 200 | 429 | RedisQPS | EVAL count | EVALSHA count | SCRIPT_LOAD count | Local hits | slowGrant | leaseGrant | multiGrant | RedisCPU(s) | KongCPU(cores) | Attempt |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| M0-none | 0 | 100 | 100 | 1.22 | 1.92 | 20.58 | 2000 | 0 | 1 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0.008 | 0.099 | 1 |
| M0-none | 0 | 500 | 500 | 0.67 | 1.21 | 10.91 | 10001 | 0 | 1 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0.007 | 0.165 | 1 |
| M0-none | 0 | 1000 | 931 | 0.49 | 3574.12 | 3940.29 | 12129 | 0 | 1 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0.006 | 0.200 | 1 |
| M0-none | 0 | 1000 | 1000 | 0.48 | 0.93 | 9.54 | 20000 | 0 | 1 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0.006 | 0.234 | 2 |
| A-batch1 | 1 | 100 | 92 | 1.45 | 3155.45 | 3892.70 | 1847 | 0 | 447 | 0 | 1847 | 0 | 0 | 1847 | 0 | 0 | 0.022 | 0.105 | 1 |
| A-batch1 | 1 | 100 | 100 | 1.45 | 2.44 | 92.64 | 2001 | 0 | 471 | 0 | 2001 | 0 | 0 | 2001 | 0 | 0 | 0.025 | 0.114 | 2 |
| A-batch1 | 1 | 500 | 462 | 0.97 | 3155.90 | 3881.45 | 8579 | 0 | 2101 | 0 | 8611 | 0 | 0 | 8611 | 0 | 0 | 0.045 | 0.251 | 1 |
| A-batch1 | 1 | 500 | 500 | 0.79 | 1.60 | 86.99 | 10001 | 0 | 2437 | 0 | 10001 | 0 | 0 | 10001 | 0 | 0 | 0.056 | 0.234 | 2 |
| A-batch1 | 1 | 1000 | 947 | 0.59 | 3421.59 | 3968.58 | 16090 | 0 | 3899 | 0 | 16093 | 0 | 0 | 16093 | 0 | 0 | 0.053 | 0.297 | 1 |
| A-batch1 | 1 | 1000 | 1000 | 0.57 | 1.20 | 72.63 | 20001 | 0 | 4787 | 0 | 20001 | 0 | 0 | 20001 | 0 | 0 | 0.063 | 0.315 | 2 |
| B-batch10 | 10 | 100 | 92 | 1.18 | 3180.54 | 3916.07 | 1844 | 0 | 179 | 0 | 413 | 0 | 1431 | 0 | 413 | 0 | 0.011 | 0.096 | 1 |
| B-batch10 | 10 | 100 | 100 | 1.09 | 1.91 | 74.18 | 2001 | 0 | 90 | 0 | 203 | 0 | 1798 | 0 | 203 | 0 | 0.012 | 0.103 | 2 |
| B-batch10 | 10 | 500 | 481 | 0.66 | 3153.53 | 3920.33 | 9307 | 0 | 423 | 0 | 963 | 0 | 8647 | 0 | 963 | 0 | 0.016 | 0.202 | 1 |
| B-batch10 | 10 | 500 | 462 | 0.68 | 3159.17 | 3954.15 | 8565 | 0 | 690 | 0 | 1572 | 0 | 7130 | 0 | 1572 | 0 | 0.012 | 0.191 | 2 |
| B-batch10 | 10 | 500 | 468 | 0.69 | 3155.45 | 3897.86 | 8676 | 0 | 390 | 0 | 911 | 0 | 8178 | 0 | 911 | 0 | 0.015 | 0.192 | 3 |
| B-batch10 | 10 | 1000 | 1000 | 0.45 | 1.04 | 93.63 | 20001 | 0 | 862 | 0 | 2003 | 0 | 17998 | 0 | 2003 | 0 | 0.019 | 0.257 | 1 |
| C-multi | 0 | 100 | 92 | 1.72 | 3192.55 | 3928.79 | 1844 | 0 | 721 | 0 | 1844 | 0 | 0 | 0 | 0 | 1844 | 0.028 | 0.111 | 1 |
| C-multi | 0 | 100 | 92 | 1.53 | 3151.80 | 3889.19 | 1847 | 0 | 722 | 0 | 1847 | 0 | 0 | 0 | 0 | 1847 | 0.027 | 0.114 | 2 |
| C-multi | 0 | 100 | 100 | 1.40 | 2.35 | 80.52 | 2000 | 0 | 781 | 0 | 2000 | 0 | 0 | 0 | 0 | 2000 | 0.029 | 0.117 | 3 |
| C-multi | 0 | 500 | 481 | 0.92 | 3169.16 | 3937.24 | 9305 | 0 | 3566 | 0 | 9487 | 0 | 0 | 0 | 0 | 9487 | 0.063 | 0.232 | 1 |
| C-multi | 0 | 500 | 461 | 0.95 | 3190.31 | 3933.66 | 8145 | 0 | 3589 | 0 | 9219 | 0 | 0 | 0 | 0 | 9219 | 0.062 | 0.232 | 2 |
| C-multi | 0 | 500 | 500 | 0.88 | 1.71 | 89.43 | 10001 | 0 | 3707 | 0 | 10001 | 0 | 0 | 0 | 0 | 10001 | 0.068 | 0.230 | 3 |
| C-multi | 0 | 1000 | 1000 | 0.65 | 1.35 | 102.57 | 20001 | 0 | 7786 | 0 | 20001 | 0 | 0 | 0 | 0 | 20001 | 0.097 | 0.323 | 1 |

## How to read the table

- EVAL count = INFO commandstats cmdstat_eval call delta (single script per group, explainable: A/C 1 per request; B ≈ request count/batch).
- Local hits = [RL-DEBUG] local_hit log line count delta across the three nodes; slowGrant = redis_grant; leaseGrant = lease_grant (the GRANT_LEASE path of the Lease implementation); multiGrant = multi_grant.
- RedisCPU(s) = INFO cpu used_cpu_sys+user delta; KongCPU(cores) = container cgroup cpu.stat usage_usec delta / duration / 1e6 (summed across three nodes).
- Redis QPS = total_commands_processed delta / duration (includes all commands: connections/scripts/read-write).
