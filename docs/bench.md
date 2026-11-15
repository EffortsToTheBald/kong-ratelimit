# Experiment Protocol: Latency × Precision × Redis Load

> **Current basis (Phase 7)**: official performance data is in
> `docs/reports/PHASE7_PERFORMANCE_REPORT.md` (raw data in `bench/raw/phase7/`). This
> document keeps the experiment design principles; where it differs from the current
> `bench/matrix.sh` actual defaults, the script is authoritative: `BATCHES=10,50,100`,
> `RATES=100,500,1000`, `DUR=20s`, `LIMIT=1000000`, `LOGLEVEL=debug` (the statistics
> columns depend on it, since Phase 8.2-B). Statements below such as "shared dict" and
> "30s" are Legacy-era historical text, kept only as design-principle reference.

> The goal is not to "produce pretty numbers", but to **draw three monotonic curves with
> the same code and a single parameter**, and give the basis for the chosen values. What
> reviewers look at is not how many QPS you pushed, but whether you know where you are
> relative to the upper bound.

---

## 1. Controlled Variables

| Variable | Fixed value | Notes |
|---|---|---|
| Number of Kong replicas | 3 | Client round-robins 8030/8010/8020 |
| Worker process count | 2 | `KONG_NGINX_WORKER_PROCESSES=2`, relevant to shared dict behavior |
| Redis | Single instance, same host | Local RTT; cross-machine numbers require a separate run |
| upstream | `hashicorp/http-echo` | Extremely light, avoiding upstream noise masking plugin overhead |
| Duration | ≥ 30s per group | Below 30s, jitter is large |
| Arrival model | constant-arrival-rate | Do not use VU loops; otherwise RPS drifts with latency and is not comparable |

## 2. Four Experiments

### E1 Quota Correctness (functional, not performance)

```
limit=100, window=3600, batch=1
```

Fire 150 requests at each of the three nodes (450 total), asserting:

```
Pass count == 100          ← must be strictly equal
```

`window=3600` makes "refill" negligible within a minute; otherwise refilling 1.67 tokens
per second makes the result non-integer.

### E2 Under-Admission Upper Bound (verifying the formula in 4.3)

```
limit=100, window=3600, batch ∈ {1, 5, 20}
```

Repeat 5 times per batch and average the pass counts, comparing against the theoretical
lower bound:

```
Expected pass count ∈ [100 - 3*batch, 100]
```

⟨TODO: fill in measured values, verify whether they fall within the interval. If they
fall below the lower bound, it means inventory reclamation/expiry has a bug⟩

### E3 Latency and Throughput (main experiment)

```
limit=1000000 (rate limiting not triggered), window=60
rate ∈ {200, 1000, 3000} RPS
batch ∈ {baseline, 1, 5, 20, auto}
```

Set limit large enough to **keep rate limiting out of the picture**; otherwise what you
measure is the 429 path rather than the admission path.

Record: `p50 / p95 / p99`, actual RPS, error rate.

### E4 Redis Load

Sample before and after each group:

```bash
docker compose exec redis redis-cli INFO stats | grep total_commands_processed
```

Difference ÷ duration = Redis ops/s. Expectation:

```
ops/s ≈ RPS / batch
```

⟨TODO: check whether measurement matches; a deviation means extra commands exist
(connections, SELECT, etc.)⟩

## 3. One-Shot Run

```bash
# Prerequisite: docker compose up -d; k6 installed (see README section 2)
cd kong-ratelimit
chmod +x bench/*.sh            # mandatory after copying over from Windows

./bench/matrix.sh -b 0,1,5,20 -r 200,1000 -d 30
```

The script will:

1. `POST /config` to the three nodes group by group (incidentally demonstrating dynamic config)
2. Wait for the config to take effect (1s)
3. Record Redis `total_commands_processed`
4. Run k6 and read the summary JSON
5. Output `bench/results.md`

## 4. Results Template (auto-filled by the script)

| Scenario | batch | RPS target | Measured RPS | p50(ms) | p95(ms) | p99(ms) | Pass | 429 | Redis ops/s |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|
| M0 baseline | - | 200 | | | | | | 0 | 0 |
| M1 | 1 | 200 | | | | | | | |
| M2 | 5 | 200 | | | | | | | |
| M3 | 20 | 200 | | | | | | | |
| M4 | auto | 200 | | | | | | | |
| M1 | 1 | 1000 | | | | | | | |
| M3 | 20 | 1000 | | | | | | | |

## 5. Three "Don'ts" When Writing Conclusions

1. **Don't** post numbers without explanations. Every number must map to a mechanism
   (e.g. "p99 rose because the slow-path hit rate is 1/20").
2. **Don't** hide anomalous values. On the local Docker network, the gap between
   `batch=1` and `batch=20` may be only 0.1ms, which looks like "the optimization is
   pointless" — the correct conclusion then is "local RTT is too small so the benefit is
   compressed; with a cross-datacenter RTT of 1ms the benefit becomes significant",
   not burying the data.
3. **Don't** set `limit` very large for a performance test without saying so. Reviewers
   will ask "did your rate limiting actually do anything", so state in the document
   beforehand that "E3 deliberately enlarges the quota to isolate the rate-limiting path".

## 6. Reproducibility

- Record the `docker compose` version, k6 version, and host CPU core count.
- Run each group 3 times and take the median; the script defaults to 1 run, and for
  official data running 3 times manually is recommended.
- The first 10s after a cold start (containers just up) involve JIT/connection-pool
  warm-up; do not count them.
