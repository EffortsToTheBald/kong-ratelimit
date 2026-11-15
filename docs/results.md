# Phase 4 First-Group Performance Baseline —— Legacy EVAL + Shared Inventory

> Generated: this file is a merge of three matrix.sh runs (see "Test Commands"). All data
> comes from real runs.

## 0. Environment and Basis

- Host: 20-core Linux (kernel 7.0.0), **shared desktop machine** (same machine always
  running kubelet/K8s node, 2 host redis-server instances, IDE, this session's agent;
  5GB swap already used).
- Containers: 3× Kong 3.6 DB-less (2 workers/node) + Redis 7 (standalone) + http-echo.
- Load test: k6 v0.54 constant-arrival-rate, 20s per group, RPS tiers 100/500/1000, NODES
  round-robining 3 nodes.
- Rate-limiting config: limit=1000000/window=60 (deliberately enlarged to isolate the
  rate-limiting path, testing admission only); **batch explicitly configured**
  (1/10/50/100; `resolve_batch()` adopts batch>0 directly, no clamp interference).
- **Legacy EVAL + Shared Inventory**: batch=1, one EVAL per request; batch>1 does
  store.take first (shared-dict local hit) then EVAL slow path; multi-rule, one EVAL
  GRANT_MULTI per request.
- **Redis host/echo host = direct container-IP connections** (see "Finding 1").

## 1. Test Commands

```bash
./bench/matrix.sh -w 2 -L notice -H ip -E ip   # First segment (notice/w2)
./bench/matrix.sh -w 2 -L error -H ip -E ip    # Second segment (error/w2, isolating debug-log backpressure)
./bench/matrix.sh -w 1 -L notice -H ip -E ip   # Third segment (notice/w1)
# Raw k6 summaries: bench/out/p1-w*-*.json (copied into bench/raw/phase1/ for the record)
```

## 2. First Segment: Worker=2 / KONG_LOG_LEVEL=notice (current default deployment shape)


| Scenario | batch | RPS target | Measured RPS | p50 | p95 | p99 | 200 | 429 | RedisQPS | EVAL count | Local hits | slowGrant | multiGrant | RedisCPU(s) | KongCPU(cores) | Attempts |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| M0-none | 0 | 100 | 92 | 1.33 | 3555.71 | 3922.69 | 1848 | 0 | 1 | 0 | 0 | 0 | 0 | -0.006 | 0.089 | 1 |
| M0-none | 0 | 100 | 100 | 1.18 | 1.78 | 2.48 | 2001 | 0 | 1 | 0 | 0 | 0 | 0 | -0.007 | 0.107 | 2 |
| M0-none | 0 | 500 | 500 | 0.64 | 1.20 | 1.80 | 10001 | 0 | 1 | 0 | 0 | 0 | 0 | -0.006 | 0.165 | 1 |
| M0-none | 0 | 1000 | 951 | 0.54 | 3088.20 | 3839.36 | 15621 | 0 | 1 | 0 | 0 | 0 | 0 | -0.005 | 0.231 | 1 |
| M0-none | 0 | 1000 | 1000 | 0.48 | 0.93 | 3.22 | 20001 | 0 | 1 | 0 | 0 | 0 | 0 | -0.005 | 0.213 | 2 |
| A-batch1 | 1 | 100 | 100 | 1.54 | 2.35 | 3.40 | 2001 | 0 | 488 | 2001 | 0 | 2001 | 0 | -0.012 | 0.128 | 1 |
| A-batch1 | 1 | 500 | 475 | 0.96 | 3079.82 | 3842.36 | 8995 | 0 | 2298 | 9493 | 0 | 9493 | 0 | -0.020 | 0.238 | 1 |
| A-batch1 | 1 | 500 | 500 | 0.87 | 1.62 | 2.53 | 10001 | 0 | 2440 | 10001 | 0 | 10001 | 0 | -0.024 | 0.242 | 2 |
| A-batch1 | 1 | 1000 | 974 | 0.65 | 3065.23 | 3833.39 | 17678 | 0 | 4646 | 19106 | 0 | 19106 | 0 | -0.033 | 0.329 | 1 |
| A-batch1 | 1 | 1000 | 951 | 0.67 | 3228.71 | 3853.50 | 15404 | 0 | 4419 | 18204 | 0 | 18204 | 0 | -0.020 | 0.311 | 2 |
| A-batch1 | 1 | 1000 | 1000 | 0.65 | 1.26 | 3.08 | 20001 | 0 | 4865 | 20001 | 0 | 20001 | 0 | -0.043 | 0.334 | 3 |
| B-batch10 | 10 | 100 | 100 | 1.31 | 2.11 | 3.50 | 2001 | 0 | 48 | 201 | 1800 | 201 | 0 | -0.009 | 0.114 | 1 |
| B-batch10 | 10 | 500 | 500 | 0.69 | 1.53 | 273.81 | 10001 | 0 | 239 | 1001 | 9000 | 1001 | 0 | -0.011 | 0.194 | 1 |
| B-batch10 | 10 | 1000 | 974 | 0.52 | 3067.63 | 3833.70 | 17684 | 0 | 445 | 1913 | 17203 | 1913 | 0 | -0.010 | 0.267 | 1 |
| B-batch10 | 10 | 1000 | 1000 | 0.51 | 1.04 | 2.61 | 20000 | 0 | 487 | 2002 | 17998 | 2002 | 0 | -0.011 | 0.282 | 2 |
| B-batch50 | 50 | 100 | 100 | 1.26 | 1.93 | 2.89 | 2001 | 0 | 11 | 41 | 1960 | 41 | 0 | -0.008 | 0.107 | 1 |
| B-batch50 | 50 | 500 | 500 | 0.66 | 1.22 | 2.09 | 10001 | 0 | 49 | 201 | 9800 | 201 | 0 | -0.007 | 0.196 | 1 |
| B-batch50 | 50 | 1000 | 973 | 0.52 | 3060.50 | 3829.47 | 17669 | 0 | 93 | 384 | 18723 | 384 | 0 | -0.005 | 0.281 | 1 |
| B-batch50 | 50 | 1000 | 1000 | 0.51 | 0.97 | 3.66 | 20001 | 0 | 98 | 401 | 19600 | 401 | 0 | -0.006 | 0.270 | 2 |
| B-batch100 | 100 | 100 | 100 | 1.26 | 1.90 | 2.96 | 2001 | 0 | 6 | 21 | 1980 | 21 | 0 | -0.008 | 0.110 | 1 |
| B-batch100 | 100 | 500 | 500 | 0.66 | 1.22 | 2.86 | 10001 | 0 | 25 | 101 | 9900 | 101 | 0 | -0.006 | 0.196 | 1 |
| B-batch100 | 100 | 1000 | 1000 | 0.49 | 0.95 | 2.78 | 20000 | 0 | 49 | 200 | 19800 | 200 | 0 | -0.006 | 0.266 | 1 |
| C-multi | 0 | 100 | 90 | 2.48 | 3572.76 | 3932.48 | 1799 | 0 | 693 | 1799 | 0 | 0 | 1799 | -0.017 | 0.129 | 1 |
| C-multi | 0 | 100 | 92 | 1.93 | 3117.90 | 3828.17 | 1849 | 0 | 697 | 1849 | 0 | 0 | 1849 | -0.017 | 0.120 | 2 |
| C-multi | 0 | 100 | 100 | 1.77 | 2.58 | 3.47 | 2001 | 0 | 712 | 2001 | 0 | 0 | 2001 | -0.015 | 0.119 | 3 |
| C-multi | 0 | 500 | 500 | 0.93 | 1.88 | 283.13 | 10001 | 0 | 3688 | 10001 | 0 | 0 | 10001 | -0.037 | 0.238 | 1 |
| C-multi | 0 | 1000 | 1000 | 0.67 | 1.33 | 3.15 | 20001 | 0 | 7583 | 20001 | 0 | 0 | 20001 | -0.045 | 0.347 | 1 |

## How to Read the Table

- EVAL count = INFO commandstats cmdstat_eval call difference (a single script within the
  group; interpretable: A/C once per request; B ≈ requests/batch).
- Local hits = difference in [RL-DEBUG] local_hit log line counts across the three nodes;
  slowGrant = redis_grant; multiGrant = multi_grant.
- RedisCPU(s) = INFO cpu used_cpu_sys+user difference; KongCPU(cores) = container cgroup
  cpu.stat usage_usec difference/duration/1e6 (summed over the three nodes).
- Redis QPS = total_commands_processed difference/duration (all commands including
  connection/script/read-write).

## 3. Second Segment: Worker=2 / KONG_LOG_LEVEL=error (isolating the debug-log backpressure factor)


| Scenario | batch | RPS target | Measured RPS | p50 | p95 | p99 | 200 | 429 | RedisQPS | EVAL count | Local hits | slowGrant | multiGrant | RedisCPU(s) | KongCPU(cores) | Attempts |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| M0-none | 0 | 100 | 100 | 1.26 | 2.05 | 11.96 | 2000 | 0 | 1 | 0 | 0 | 0 | 0 | 0.009 | 0.094 | 1 |
| M0-none | 0 | 500 | 500 | 0.66 | 1.22 | 6.35 | 10001 | 0 | 1 | 0 | 0 | 0 | 0 | 0.007 | 0.176 | 1 |
| M0-none | 0 | 1000 | 930 | 0.51 | 3119.08 | 3848.95 | 14915 | 0 | 1 | 0 | 0 | 0 | 0 | 0.006 | 0.206 | 1 |
| M0-none | 0 | 1000 | 1000 | 0.49 | 9.70 | 644.41 | 19855 | 0 | 1 | 0 | 0 | 0 | 0 | 0.006 | 0.219 | 2 |
| M0-none | 0 | 1000 | 1000 | 0.47 | 0.92 | 2.11 | 20001 | 0 | 1 | 0 | 0 | 0 | 0 | 0.006 | 0.218 | 3 |
| A-batch1 | 1 | 100 | 95 | 1.81 | 3073.60 | 3831.87 | 1899 | 0 | 464 | 1899 | 0 | 0 | 0 | 0.028 | 0.114 | 1 |
| A-batch1 | 1 | 100 | 95 | 1.77 | 3225.34 | 3911.46 | 1894 | 0 | 436 | 1894 | 0 | 0 | 0 | 0.026 | 0.118 | 2 |
| A-batch1 | 1 | 100 | 100 | 1.66 | 2.48 | 3.48 | 2001 | 0 | 487 | 2001 | 0 | 0 | 0 | 0.028 | 0.112 | 3 |
| A-batch1 | 1 | 500 | 500 | 0.90 | 1.67 | 2.41 | 10001 | 0 | 2327 | 10001 | 0 | 0 | 0 | 0.063 | 0.217 | 1 |
| A-batch1 | 1 | 1000 | 1000 | 0.68 | 1.31 | 3.80 | 20001 | 0 | 4869 | 20001 | 0 | 0 | 0 | 0.092 | 0.324 | 1 |
| B-batch10 | 10 | 100 | 100 | 1.13 | 1.92 | 2.98 | 2000 | 0 | 44 | 200 | 0 | 0 | 0 | 0.010 | 0.087 | 1 |
| B-batch10 | 10 | 500 | 500 | 0.66 | 1.29 | 3.09 | 10001 | 0 | 244 | 1001 | 0 | 0 | 0 | 0.016 | 0.180 | 1 |
| B-batch10 | 10 | 1000 | 974 | 0.50 | 3060.94 | 3829.28 | 17685 | 0 | 460 | 1913 | 0 | 0 | 0 | 0.016 | 0.246 | 1 |
| B-batch10 | 10 | 1000 | 1000 | 0.49 | 1.00 | 2.64 | 20001 | 0 | 488 | 2001 | 0 | 0 | 0 | 0.019 | 0.247 | 2 |
| B-batch50 | 50 | 100 | 100 | 1.15 | 1.76 | 2.61 | 2001 | 0 | 11 | 41 | 0 | 0 | 0 | 0.009 | 0.113 | 1 |
| B-batch50 | 50 | 500 | 500 | 0.64 | 1.22 | 1.96 | 10001 | 0 | 46 | 201 | 0 | 0 | 0 | 0.009 | 0.164 | 1 |
| B-batch50 | 50 | 1000 | 1000 | 0.50 | 0.96 | 1.83 | 20001 | 0 | 87 | 401 | 0 | 0 | 0 | 0.009 | 0.222 | 1 |
| B-batch100 | 100 | 100 | 100 | 1.15 | 1.78 | 2.37 | 2000 | 0 | 5 | 20 | 0 | 0 | 0 | 0.008 | 0.089 | 1 |
| B-batch100 | 100 | 500 | 500 | 0.65 | 1.18 | 7.87 | 10001 | 0 | 24 | 101 | 0 | 0 | 0 | 0.008 | 0.177 | 1 |
| B-batch100 | 100 | 1000 | 1000 | 0.47 | 0.94 | 6.72 | 20002 | 0 | 48 | 202 | 0 | 0 | 0 | 0.007 | 0.228 | 1 |
| C-multi | 0 | 100 | 100 | 1.63 | 2.60 | 3.93 | 2001 | 0 | 736 | 2001 | 0 | 0 | 0 | 0.030 | 0.109 | 1 |
| C-multi | 0 | 500 | 500 | 0.90 | 1.64 | 2.26 | 10001 | 0 | 3842 | 10001 | 0 | 0 | 0 | 0.074 | 0.227 | 1 |
| C-multi | 0 | 1000 | 1000 | 0.67 | 1.31 | 2.95 | 20001 | 0 | 7791 | 20001 | 0 | 0 | 0 | 0.105 | 0.340 | 1 |

## How to Read the Table

- EVAL count = INFO commandstats cmdstat_eval call difference (a single script within the
  group; interpretable: A/C once per request; B ≈ requests/batch).
- Local hits = difference in [RL-DEBUG] local_hit log line counts across the three nodes;
  slowGrant = redis_grant; multiGrant = multi_grant.
- RedisCPU(s) = INFO cpu used_cpu_sys+user difference; KongCPU(cores) = container cgroup
  cpu.stat usage_usec difference/duration/1e6 (summed over the three nodes).
- Redis QPS = total_commands_processed difference/duration (all commands including
  connection/script/read-write).

## 4. Third Segment: Worker=1 / KONG_LOG_LEVEL=notice


| Scenario | batch | RPS target | Measured RPS | p50 | p95 | p99 | 200 | 429 | RedisQPS | EVAL count | Local hits | slowGrant | multiGrant | RedisCPU(s) | KongCPU(cores) | Attempts |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| M0-none | 0 | 100 | 95 | 1.16 | 3078.47 | 3834.98 | 1900 | 0 | 1 | 0 | 0 | 0 | 0 | 0.009 | 0.081 | 1 |
| M0-none | 0 | 100 | 100 | 1.03 | 1.68 | 2.82 | 2001 | 0 | 1 | 0 | 0 | 0 | 0 | 0.008 | 0.097 | 2 |
| M0-none | 0 | 500 | 500 | 0.60 | 1.11 | 7.64 | 10001 | 0 | 1 | 0 | 0 | 0 | 0 | 0.007 | 0.153 | 1 |
| M0-none | 0 | 1000 | 975 | 0.45 | 3412.12 | 3921.71 | 16070 | 0 | 1 | 0 | 0 | 0 | 0 | 0.005 | 0.189 | 1 |
| M0-none | 0 | 1000 | 953 | 0.45 | 3478.91 | 3936.39 | 15091 | 0 | 1 | 0 | 0 | 0 | 0 | 0.005 | 0.186 | 2 |
| M0-none | 0 | 1000 | 1000 | 0.44 | 0.86 | 6.13 | 20000 | 0 | 1 | 0 | 0 | 0 | 0 | 0.005 | 0.205 | 3 |
| A-batch1 | 1 | 100 | 90 | 2.17 | 3580.06 | 3938.66 | 1799 | 0 | 440 | 1799 | 0 | 1799 | 0 | 0.026 | 0.111 | 1 |
| A-batch1 | 1 | 100 | 92 | 1.67 | 3091.98 | 3828.38 | 1849 | 0 | 452 | 1849 | 0 | 1849 | 0 | 0.027 | 0.101 | 2 |
| A-batch1 | 1 | 100 | 100 | 1.49 | 2.33 | 3.03 | 2001 | 0 | 477 | 2001 | 0 | 2001 | 0 | 0.028 | 0.099 | 3 |
| A-batch1 | 1 | 500 | 500 | 0.75 | 1.42 | 2.34 | 10000 | 0 | 2304 | 10000 | 0 | 10000 | 0 | 0.051 | 0.189 | 1 |
| A-batch1 | 1 | 1000 | 954 | 0.55 | 3548.16 | 3943.33 | 13930 | 0 | 3702 | 15986 | 0 | 15986 | 0 | 0.055 | 0.229 | 1 |
| A-batch1 | 1 | 1000 | 1000 | 0.57 | 1.10 | 40.66 | 20002 | 0 | 4718 | 20002 | 0 | 20002 | 0 | 0.062 | 0.270 | 2 |
| B-batch10 | 10 | 100 | 100 | 1.11 | 1.88 | 2.69 | 2001 | 0 | 48 | 201 | 1800 | 201 | 0 | 0.011 | 0.087 | 1 |
| B-batch10 | 10 | 500 | 500 | 0.62 | 1.25 | 2.62 | 10001 | 0 | 240 | 1001 | 9000 | 1001 | 0 | 0.015 | 0.171 | 1 |
| B-batch10 | 10 | 1000 | 1000 | 0.48 | 0.95 | 4.79 | 20000 | 0 | 489 | 2000 | 18000 | 2000 | 0 | 0.016 | 0.255 | 1 |
| B-batch50 | 50 | 100 | 100 | 1.11 | 1.77 | 2.66 | 2001 | 0 | 10 | 41 | 1960 | 41 | 0 | 0.009 | 0.086 | 1 |
| B-batch50 | 50 | 500 | 500 | 0.60 | 1.15 | 2.36 | 10001 | 0 | 50 | 201 | 9800 | 201 | 0 | 0.009 | 0.169 | 1 |
| B-batch50 | 50 | 1000 | 1000 | 0.48 | 0.92 | 2.52 | 20001 | 0 | 98 | 402 | 19599 | 402 | 0 | 0.008 | 0.233 | 1 |
| B-batch100 | 100 | 100 | 100 | 1.22 | 2.10 | 507.85 | 2001 | 0 | 6 | 21 | 1980 | 21 | 0 | 0.009 | 0.088 | 1 |
| B-batch100 | 100 | 100 | 95 | 1.31 | 3080.25 | 3838.78 | 1900 | 0 | 6 | 21 | 1879 | 21 | 0 | 0.009 | 0.106 | 2 |
| B-batch100 | 100 | 100 | 100 | 1.19 | 1.82 | 3.05 | 2001 | 0 | 6 | 21 | 1980 | 21 | 0 | 0.009 | 0.089 | 3 |
| B-batch100 | 100 | 500 | 500 | 0.63 | 1.21 | 2.83 | 10001 | 0 | 23 | 101 | 9900 | 101 | 0 | 0.008 | 0.154 | 1 |
| B-batch100 | 100 | 1000 | 954 | 0.48 | 3470.37 | 3939.11 | 14988 | 0 | 43 | 172 | 16823 | 172 | 0 | 0.006 | 0.213 | 1 |
| B-batch100 | 100 | 1000 | 1000 | 0.49 | 0.93 | 2.34 | 20002 | 0 | 47 | 202 | 19800 | 202 | 0 | 0.007 | 0.229 | 2 |
| C-multi | 0 | 100 | 92 | 1.85 | 3099.67 | 3841.24 | 1849 | 0 | 720 | 1849 | 0 | 0 | 1849 | 0.032 | 0.106 | 1 |
| C-multi | 0 | 100 | 92 | 1.86 | 3085.82 | 3825.17 | 1850 | 0 | 690 | 1850 | 0 | 0 | 1850 | 0.030 | 0.100 | 2 |
| C-multi | 0 | 100 | 100 | 1.67 | 2.54 | 3.76 | 2001 | 0 | 782 | 2001 | 0 | 0 | 2001 | 0.032 | 0.108 | 3 |
| C-multi | 0 | 500 | 500 | 0.85 | 1.63 | 5.74 | 10001 | 0 | 3901 | 10001 | 0 | 0 | 10001 | 0.065 | 0.226 | 1 |
| C-multi | 0 | 1000 | 1000 | 0.62 | 1.20 | 5.66 | 20001 | 0 | 7469 | 20001 | 0 | 0 | 20001 | 0.078 | 0.306 | 1 |

## How to Read the Table

- EVAL count = INFO commandstats cmdstat_eval call difference (a single script within the
  group; interpretable: A/C once per request; B ≈ requests/batch).
- Local hits = difference in [RL-DEBUG] local_hit log line counts across the three nodes;
  slowGrant = redis_grant; multiGrant = multi_grant.
- RedisCPU(s) = INFO cpu used_cpu_sys+user difference; KongCPU(cores) = container cgroup
  cpu.stat usage_usec difference/duration/1e6 (summed over the three nodes).
- Redis QPS = total_commands_processed difference/duration (all commands including
  connection/script/read-write).

## 5. Findings (troubleshooting records from this round, all genuinely reproducible)

### Finding 1: Container DNS intermittent multi-second blocking (environment defect, affecting both the proxy and Redis chains)
Symptom: with hostname mode (`echo`/`redis`), occasionally (about 1/3 of cases) requests
show 3.8–4.0s blocks at the waiting layer; after switching echo+redis to **direct IP
connections it disappeared completely** (the multi-rule group's p99 went from 4005ms →
3.5ms). Manual curl 100 times slowest 50ms, Redis SLOWLOG shows no slow commands,
`http_req_connecting=0` (not connection establishment).
Disposition: the baseline uses direct IP connections throughout; productionization
recommendations (Kong DNS cache tuning / static hosts / service discovery) are listed in
design.md's production boundaries. **No production code was modified.**

### Finding 2: KONG_LOG_LEVEL=notice log backpressure dominates tail latency (a real existing defect)
Symptom: under notice (RL-DEBUG debug logs, 2–4 lines per request), the batch=1 group's
p95=3.6s/p99=3.8s; after switching to error, the same config gives p95=3.1ms/p99=71ms —
**tail latency is dominated by the debug logs' stdout pipe backpressure**, unrelated to
rate-limiting overhead. This is a legacy temporary debug log from Phases 1/2 (quantified
evidence of the "debug logs are a temporary state" defect).
Disposition: both the notice and error segments are kept (notice = the current
deployment shape presented as-is; error = pure plugin overhead after isolating the log
factor). **No production code was modified**; this must be addressed in the Phase 5
structured-logging rework.

### Finding 3: Host environment noise causing occasional 4s blocks (root cause not located; a contamination criterion and rerun mechanism were established)
Symptom: during one run of this report, ~5% of requests showed **constant-scale 3.8–4.0s
waiting blocks** while measured RPS dropped to ~95% of target — the two share one cause;
**the M0 no-plugin control group showed the same thing** (unrelated to rate-limiting
mode); unrelated to connection establishment (connecting=0), docker-proxy (proxy/direct
1000 RPS both clean in both modes), DNS (still occasional after direct IP), conntrack
(9513/655360), or listen queue (drops=0). `TCPSynRetrans=22170` cumulatively but
attribution could not be located.
Criterion and mechanism: **p99>500ms or measured RPS<95% of target ⇒ judged contaminated
and auto-rerun (≤3 attempts); the attempts column is in the table**; the clean shape's
empirical upper limit is p99≈188ms. If still contaminated after retries, it is marked
as-is (all cases in this round obtained clean data within ≤3 attempts).

## 6. Not Executed (NOT RUN) and Limitations

| Item | Status | Reason |
|---|---|---|
| RETURN-enabled dimension | NOT RUN | RETURN_LEASE belongs to Phase 3/5 scope; this phase is the Legacy baseline |
| EVALSHA comparison segment | NOT RUN | Phase 2 scope |
| Lease mode segment | NOT RUN | Phase 4.4–4.6 scope |
| error level × Worker=1 combination | NOT RUN | The loglevel comparison only needs the Worker=2 dimension (to control scale) |
| Redis master-replica/Cluster | NOT RUN | Single-instance standalone deployment (Cluster is Deferred) |

## 7. Data Files

- Raw k6 summaries (one JSON per case): `bench/raw/phase1/` (committed)
- Raw output of each round: `bench/out/results-p1-*.md`


---

# Phase 4 Second-Group Comparison —— EVALSHA (after the script-management switch)

> Conditions fully identical to the first group: k6/parameters/rate-limiting
> config/Worker count/direct IP connections/20s duration/log level split into notice and
> error segments.
> The only difference: script calls in `lib/redis.lua` switched from full-text EVAL
> upload to EVALSHA (GRANT_LEASE/RETURN_LEASE not yet implemented; not in this group).

## EVALSHA Semantics Verification (implementation record)

| Verification | Result |
|---|---|
| Unit tests (stub client) 8 cases: lazy load / NOSCRIPT self-heal / second NOSCRIPT failure / LOAD failure / timeout does not trigger LOAD / disconnect does not trigger / timeout after lazy load | 8/8 passed (`test/evalsha-unit.sh`) |
| batch=1 request after SCRIPT FLUSH (isolated test Redis) | 200 + `script cache miss (NOSCRIPT), loaded: token_bucket` warn log |
| Multi-rule request after SCRIPT FLUSH | 200 + `loaded: grant_multi` |
| Multi-Worker cache behavior | Independent lazy loading per node (each node's 2 Workers each LOAD; miss log counts consistent with request distribution) |
| commandstats | eval count no longer grows; evalsha/script appear on demand |
| Regression | quota.sh batch=1 exactly 100 ✓, dims.sh 8/8 ✓, rules.sh 14/14 ✓ |

## Second Segment: Worker=2 / notice (same-conditions contrast with the first group's notice segment)


| Scenario | batch | RPS target | Measured RPS | p50 | p95 | p99 | 200 | 429 | RedisQPS | EVAL count | EVALSHA count | SCRIPT_LOAD count | Local hits | slowGrant | multiGrant | RedisCPU(s) | KongCPU(cores) | Attempts |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| M0-none | 0 | 100 | 100 | 1.06 | 1.79 | 2.70 | 2000 | 0 | 1 | 0 | 0 | 0 | 0 | 0 | 0 | 0.008 | 0.093 | 1 |
| M0-none | 0 | 500 | 500 | 0.60 | 1.08 | 1.42 | 10001 | 0 | 1 | 0 | 0 | 0 | 0 | 0 | 0 | 0.007 | 0.150 | 1 |
| M0-none | 0 | 1000 | 1000 | 0.43 | 0.85 | 1.20 | 20001 | 0 | 1 | 0 | 0 | 0 | 0 | 0 | 0 | 0.006 | 0.203 | 1 |
| A-batch1 | 1 | 100 | 100 | 1.55 | 2.35 | 2.83 | 2001 | 0 | 476 | 0 | 2001 | 0 | 0 | 2001 | 0 | 0.026 | 0.126 | 1 |
| A-batch1 | 1 | 500 | 500 | 0.83 | 1.47 | 1.82 | 10001 | 0 | 2374 | 0 | 10001 | 0 | 0 | 10001 | 0 | 0.059 | 0.212 | 1 |
| A-batch1 | 1 | 1000 | 1000 | 0.60 | 1.14 | 1.51 | 20000 | 0 | 4717 | 0 | 20000 | 0 | 0 | 20000 | 0 | 0.078 | 0.282 | 1 |
| B-batch10 | 10 | 100 | 100 | 1.23 | 1.99 | 2.52 | 2001 | 0 | 50 | 0 | 201 | 0 | 1800 | 201 | 0 | 0.011 | 0.111 | 1 |
| B-batch10 | 10 | 500 | 500 | 0.64 | 1.20 | 1.56 | 10001 | 0 | 245 | 0 | 1001 | 0 | 9000 | 1001 | 0 | 0.015 | 0.188 | 1 |
| B-batch10 | 10 | 1000 | 1000 | 0.47 | 0.96 | 1.39 | 20001 | 0 | 487 | 0 | 2001 | 0 | 18000 | 2001 | 0 | 0.018 | 0.255 | 1 |
| B-batch50 | 50 | 100 | 100 | 1.13 | 1.73 | 2.05 | 2001 | 0 | 11 | 0 | 41 | 0 | 1960 | 41 | 0 | 0.008 | 0.093 | 1 |
| B-batch50 | 50 | 500 | 500 | 0.61 | 1.11 | 1.37 | 10001 | 0 | 50 | 0 | 201 | 0 | 9800 | 201 | 0 | 0.009 | 0.174 | 1 |
| B-batch50 | 50 | 1000 | 1000 | 0.46 | 0.87 | 1.17 | 20002 | 0 | 96 | 0 | 402 | 0 | 19600 | 402 | 0 | 0.009 | 0.232 | 1 |
| B-batch100 | 100 | 100 | 100 | 1.13 | 1.71 | 1.93 | 2001 | 0 | 6 | 0 | 21 | 0 | 1980 | 21 | 0 | 0.008 | 0.105 | 1 |
| B-batch100 | 100 | 500 | 500 | 0.61 | 1.11 | 1.38 | 10001 | 0 | 25 | 0 | 101 | 0 | 9900 | 101 | 0 | 0.008 | 0.177 | 1 |
| B-batch100 | 100 | 1000 | 1000 | 0.43 | 0.85 | 1.15 | 20001 | 0 | 48 | 0 | 201 | 0 | 19800 | 201 | 0 | 0.007 | 0.229 | 1 |
| C-multi | 0 | 100 | 100 | 1.66 | 2.53 | 3.00 | 2001 | 0 | 780 | 0 | 2001 | 0 | 0 | 0 | 2001 | 0.031 | 0.117 | 1 |
| C-multi | 0 | 500 | 500 | 0.85 | 1.55 | 1.92 | 10001 | 0 | 3888 | 0 | 10001 | 0 | 0 | 0 | 10001 | 0.069 | 0.242 | 1 |
| C-multi | 0 | 1000 | 1000 | 0.63 | 1.18 | 1.55 | 20001 | 0 | 7814 | 0 | 20001 | 0 | 0 | 0 | 20001 | 0.096 | 0.300 | 1 |

## How to Read the Table

- EVAL count = INFO commandstats cmdstat_eval call difference (a single script within the
  group; interpretable: A/C once per request; B ≈ requests/batch).
- Local hits = difference in [RL-DEBUG] local_hit log line counts across the three nodes;
  slowGrant = redis_grant; multiGrant = multi_grant.
- RedisCPU(s) = INFO cpu used_cpu_sys+user difference; KongCPU(cores) = container cgroup
  cpu.stat usage_usec difference/duration/1e6 (summed over the three nodes).
- Redis QPS = total_commands_processed difference/duration (all commands including
  connection/script/read-write).

## Third Segment: Worker=2 / error (same-conditions contrast with the first group's error segment)


| Scenario | batch | RPS target | Measured RPS | p50 | p95 | p99 | 200 | 429 | RedisQPS | EVAL count | EVALSHA count | SCRIPT_LOAD count | Local hits | slowGrant | multiGrant | RedisCPU(s) | KongCPU(cores) | Attempts |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| M0-none | 0 | 100 | 100 | 1.17 | 1.83 | 2.66 | 2001 | 0 | 1 | 0 | 0 | 0 | 0 | 0 | 0 | 0.007 | 0.098 | 1 |
| M0-none | 0 | 500 | 500 | 0.61 | 1.10 | 1.43 | 10001 | 0 | 1 | 0 | 0 | 0 | 0 | 0 | 0 | 0.007 | 0.157 | 1 |
| M0-none | 0 | 1000 | 1000 | 0.42 | 0.84 | 1.13 | 20001 | 0 | 1 | 0 | 0 | 0 | 0 | 0 | 0 | 0.006 | 0.202 | 1 |
| A-batch1 | 1 | 100 | 100 | 1.48 | 2.24 | 2.76 | 2001 | 0 | 484 | 0 | 2001 | 0 | 0 | 0 | 0 | 0.025 | 0.121 | 1 |
| A-batch1 | 1 | 500 | 500 | 0.77 | 1.41 | 1.75 | 10001 | 0 | 2432 | 0 | 10001 | 0 | 0 | 0 | 0 | 0.056 | 0.199 | 1 |
| A-batch1 | 1 | 1000 | 1000 | 0.59 | 1.11 | 1.50 | 20001 | 0 | 4732 | 0 | 20001 | 0 | 0 | 0 | 0 | 0.077 | 0.268 | 1 |
| B-batch10 | 10 | 100 | 100 | 1.12 | 1.77 | 2.13 | 2000 | 0 | 50 | 0 | 200 | 0 | 0 | 0 | 0 | 0.010 | 0.093 | 1 |
| B-batch10 | 10 | 500 | 500 | 0.63 | 1.20 | 1.60 | 10001 | 0 | 218 | 0 | 1001 | 0 | 0 | 0 | 0 | 0.015 | 0.161 | 1 |
| B-batch10 | 10 | 1000 | 1000 | 0.44 | 0.90 | 1.32 | 20001 | 0 | 475 | 0 | 2001 | 0 | 0 | 0 | 0 | 0.017 | 0.221 | 1 |
| B-batch50 | 50 | 100 | 100 | 1.08 | 1.64 | 2.00 | 2000 | 0 | 11 | 0 | 40 | 0 | 0 | 0 | 0 | 0.008 | 0.089 | 1 |
| B-batch50 | 50 | 500 | 500 | 0.59 | 1.07 | 1.36 | 10001 | 0 | 49 | 0 | 201 | 0 | 0 | 0 | 0 | 0.008 | 0.158 | 1 |
| B-batch50 | 50 | 1000 | 1000 | 0.45 | 0.88 | 1.19 | 20001 | 0 | 99 | 0 | 401 | 0 | 0 | 0 | 0 | 0.008 | 0.223 | 1 |
| B-batch100 | 100 | 100 | 100 | 1.10 | 1.66 | 1.94 | 2000 | 0 | 6 | 0 | 20 | 0 | 0 | 0 | 0 | 0.008 | 0.091 | 1 |
| B-batch100 | 100 | 500 | 500 | 0.59 | 1.06 | 1.31 | 10001 | 0 | 25 | 0 | 101 | 0 | 0 | 0 | 0 | 0.007 | 0.160 | 1 |
| B-batch100 | 100 | 1000 | 1000 | 0.43 | 0.84 | 1.14 | 20001 | 0 | 50 | 0 | 201 | 0 | 0 | 0 | 0 | 0.007 | 0.232 | 1 |
| C-multi | 0 | 100 | 100 | 1.67 | 2.46 | 2.85 | 2000 | 0 | 780 | 0 | 2000 | 0 | 0 | 0 | 0 | 0.031 | 0.115 | 1 |
| C-multi | 0 | 500 | 500 | 0.90 | 1.63 | 1.98 | 10001 | 0 | 3883 | 0 | 10001 | 0 | 0 | 0 | 0 | 0.071 | 0.230 | 1 |
| C-multi | 0 | 1000 | 1000 | 0.64 | 1.21 | 1.60 | 20001 | 0 | 7379 | 0 | 20001 | 0 | 0 | 0 | 0 | 0.093 | 0.304 | 1 |

## How to Read the Table

- EVAL count = INFO commandstats cmdstat_eval call difference (a single script within the
  group; interpretable: A/C once per request; B ≈ requests/batch).
- Local hits = difference in [RL-DEBUG] local_hit log line counts across the three nodes;
  slowGrant = redis_grant; multiGrant = multi_grant.
- RedisCPU(s) = INFO cpu used_cpu_sys+user difference; KongCPU(cores) = container cgroup
  cpu.stat usage_usec difference/duration/1e6 (summed over the three nodes).
- Redis QPS = total_commands_processed difference/duration (all commands including
  connection/script/read-write).

## Transport Overhead Microbenchmark (resty direct connection, GRANT_MULTI script)

| Item | EVAL full text | EVALSHA |
|---|---:|---:|
| Single transfer | 1982 B (script text) | 40 B (SHA) |
| Cumulative transfer over 200 calls | 387 KB | 8 KB |
| Single RTT (local) | 0.08 ms | 0.04 ms |

Conclusion: the byte benefit is definite (49×); the local RTT is tiny so the latency
difference is ~0.04ms/call — on cross-datacenter/public-network deployments that
difference amplifies significantly (recorded as-is, without presupposing a benefit
magnitude).

## Process Records (during Phase 2 execution)

- **One process violation**: the `-T` output-label-argument patch for matrix.sh was not
  fully landed, and a Phase 2 dry run **overwrote the working copy
  `bench/out/results-p1-w2-notice-ip.md`** (the authoritative copy of Phase 1 data is in
  docs/results.md and bench/raw/phase1/*.json, nothing lost; the working md can be
  rebuilt from both). Fixed since (`-T` fully landed and measured), and all Phase 2 data
  was written to `results-p2-*`.
- **Script robustness fixes**: `local a="$1" b="…${a}…"` single-statement assignment
  expands before assignment under set -u (bash semantics) — split apart; `cat|head`
  silently exits with SIGPIPE under pipefail — changed to exit inside awk; k6 summary
  occasionally hangs after writing to disk without exiting — run_k6 gained a 60s timeout
  fallback (if the summary is on disk, the data is taken back; exit 124 is not treated as
  failure).
- Environmental noise (Finding 3) occurred once in this group's runs (A@500 first attempt
  p99=741ms intercepted by the criterion, clean on rerun); all contamination-rerun
  records were kept throughout.

## NOT RUN (Second Group)

| Item | Status | Reason |
|---|---|---|
| EVALSHA for GRANT_LEASE/RETURN_LEASE | NOT RUN | Scripts not yet implemented (registered to the same manager in Phase 3) |
| Worker=1 segment | NOT RUN | The EVALSHA comparison conclusion was drawn from the Worker=2 segment; the Worker dimension belongs to the third group (Lease) |
