# Performance matrix (measured on the current implementation; tag=p8bcheck, Worker=2, log=debug, redisHost=redis, echoHost=echo; limit=1000000 window=60s duration=20s RPS=100,500,1000 batch=10)

Generated at: 2026-11-14 21:14:19　limit=1000000 window=60s duration=20s RPS=100,500,1000 batch=10

| Scenario | batch | RPS target | Measured RPS | p50 | p95 | p99 | 200 | 429 | RedisQPS | EVAL count | EVALSHA count | SCRIPT_LOAD count | Local hits | slowGrant | leaseGrant | multiGrant | RedisCPU(s) | KongCPU(cores) | Attempt |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| M0-none | 0 | 100 | 96 | 1.20 | 3056.45 | 3816.80 | 1924 | 0 | 1 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0.008 | 0.103 | 1 |
| M0-none | 0 | 100 | 100 | 1.13 | 1.77 | 12.20 | 2001 | 0 | 1 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0.009 | 0.099 | 2 |
| M0-none | 0 | 500 | 500 | 0.61 | 1.17 | 23.42 | 10001 | 0 | 1 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0.007 | 0.172 | 1 |
| M0-none | 0 | 1000 | 1000 | 0.43 | 0.86 | 13.98 | 20000 | 0 | 1 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0.006 | 0.227 | 1 |
| A-batch1 | 1 | 100 | 100 | 1.61 | 2.68 | 95.33 | 2001 | 0 | 482 | 0 | 2001 | 0 | 0 | 2001 | 0 | 0 | 0.028 | 0.120 | 1 |
| A-batch1 | 1 | 500 | 461 | 0.97 | 3188.45 | 3932.35 | 8164 | 0 | 2244 | 0 | 9217 | 0 | 0 | 9217 | 0 | 0 | 0.055 | 0.252 | 1 |
| A-batch1 | 1 | 500 | 500 | 0.86 | 1.75 | 86.70 | 10001 | 0 | 2355 | 0 | 10001 | 0 | 0 | 10001 | 0 | 0 | 0.057 | 0.245 | 2 |
| A-batch1 | 1 | 1000 | 936 | 0.61 | 3636.88 | 3987.93 | 13583 | 0 | 3641 | 0 | 15048 | 0 | 0 | 15048 | 0 | 0 | 0.054 | 0.288 | 1 |
| A-batch1 | 1 | 1000 | 1000 | 0.62 | 1.33 | 87.62 | 20000 | 0 | 4741 | 0 | 20000 | 0 | 0 | 20000 | 0 | 0 | 0.071 | 0.336 | 2 |
| B-batch10 | 10 | 100 | 100 | 1.22 | 2.10 | 72.46 | 2001 | 0 | 91 | 0 | 203 | 0 | 1798 | 0 | 203 | 0 | 0.012 | 0.109 | 1 |
| B-batch10 | 10 | 500 | 475 | 0.74 | 3181.51 | 3971.90 | 9049 | 0 | 688 | 0 | 1685 | 0 | 7547 | 0 | 1685 | 0 | 0.013 | 0.201 | 1 |
| B-batch10 | 10 | 500 | 461 | 0.75 | 3209.13 | 3957.34 | 8137 | 0 | 406 | 0 | 924 | 0 | 8292 | 0 | 924 | 0 | 0.016 | 0.208 | 2 |
| B-batch10 | 10 | 500 | 500 | 0.64 | 1.39 | 87.73 | 10001 | 0 | 427 | 0 | 1003 | 0 | 8998 | 0 | 1003 | 0 | 0.016 | 0.191 | 3 |
| B-batch10 | 10 | 1000 | 902 | 0.54 | 4001.28 | 6101.33 | 12033 | 0 | 814 | 0 | 1925 | 0 | 12649 | 0 | 1925 | 0 | 0.014 | 0.230 | 1 |
| B-batch10 | 10 | 1000 | 952 | 0.52 | 3130.61 | 3880.95 | 16783 | 0 | 926 | 0 | 2152 | 0 | 14977 | 0 | 2152 | 0 | 0.015 | 0.266 | 2 |
| B-batch10 | 10 | 1000 | 959 | 0.49 | 3348.73 | 3950.49 | 16718 | 0 | 740 | 0 | 1720 | 0 | 15000 | 0 | 1720 | 0 | 0.013 | 0.284 | 3 |
| C-multi | 0 | 100 | 100 | 1.66 | 2.63 | 86.04 | 2001 | 0 | 753 | 0 | 2001 | 0 | 0 | 0 | 0 | 2001 | 0.031 | 0.118 | 1 |
| C-multi | 0 | 500 | 500 | 0.84 | 1.66 | 79.29 | 10000 | 0 | 3883 | 0 | 10000 | 0 | 0 | 0 | 0 | 10000 | 0.070 | 0.236 | 1 |
| C-multi | 0 | 1000 | 1000 | 0.63 | 1.33 | 76.30 | 20001 | 0 | 7538 | 0 | 20001 | 0 | 0 | 0 | 0 | 20001 | 0.093 | 0.344 | 1 |

## How to read the table

- EVAL count = INFO commandstats cmdstat_eval call delta (single script per group, explainable: A/C 1 per request; B ≈ request count/batch).
- Local hits = [RL-DEBUG] local_hit log line count delta across the three nodes; slowGrant = redis_grant; leaseGrant = lease_grant (the GRANT_LEASE path of the Lease implementation); multiGrant = multi_grant. The stats columns depend on KONG_LOG_LEVEL=debug (this script's default); when running at notice level the stats columns are 0 (expected, not lost requests).
- RedisCPU(s) = INFO cpu used_cpu_sys+user delta; KongCPU(cores) = container cgroup cpu.stat usage_usec delta / duration / 1e6 (summed across three nodes).
- Redis QPS = total_commands_processed delta / duration (includes all commands: connections/scripts/read-write).
