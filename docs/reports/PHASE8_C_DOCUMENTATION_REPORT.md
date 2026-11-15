# Phase 8.2-C Report: Final Delivery Documentation Consolidation

- **Date**: 2026-11-14
- **Baseline HEAD**: `01b3e11` (the first-round audit commit); zero code/test/bench script changes throughout this round
- **commit**: `docs: finalize phase8c delivery documentation`

## 1. Changed files

| File | Type | Content |
|---|---|---|
| README.md | Rewrite | A project front page for new users (all 10 items of §5 covered) |
| docs/architecture.md | Rewrite | The current implementation's architecture (all 14 checklist items covered; fixed the erroneous cross-worker shared-inventory description) |
| docs/DEPLOYMENT.md | New | Compose verification environment: deployment/checking/troubleshooting/cleanup |
| docs/CONFIGURATION.md | New | Full configuration field table (schema.lua as the sole basis) |
| docs/TESTING.md | New | Test run index + prerequisites + cleanup methods + report index |
| docs/bench.md | Updated | Header notes the current scope (Phase 7/8.2-B: matrix's actual defaults, debug statistics scope); legacy wording annotated |
| test/phase1-manual.md | Annotated | Tail note on the historical scope (RL-DEBUG is now debug level); steps and conclusions preserved as-is |
| test/phase2-manual.md | Annotated | Same as above |
| docs/reports/PHASE8_C_DOCUMENTATION_AUDIT.md | Committed in round 1 (01b3e11) | — |
| docs/reports/PHASE8_C_DOCUMENTATION_REPORT.md | New | This report |

**Zero changes**: production code (handler/algorithm/lease/redis/schema), test/*.sh|*.lua script logic (only historical docs annotated), bench/*.sh, k6/, frozen Spec/Design (design.md/rule.md/openspec/), Phase 6/7 reports, Phase 8.2-A/B reports, bench/raw/phase7/ raw data, docs/results.md, V1_SCOPE_ADJUSTMENT.md.

## 2. Adjustments per document (against the first-round audit)

| Audit issue | Action |
|---|---|
| README §6 matrix command/defaults/artifacts outdated | Rewritten with measured defaults (BATCHES=10,50,100 / RATES=100,500,1000 / DUR=20s / debug level / artifacts bench/out/results-<TAG>-*.md) |
| README §7 "batch=20 p99 differs <1ms" without evidence | **Deleted**; the performance section cites only Phase 7 (including the p99 NOT VERIFIED statement) |
| README §5 "typical p99 increment" numbers | **Deleted**; the batch table retains only semantics and authorization behavior (batch=auto verified in code as clamp(limit/50,1,50)) |
| README missing three-mode overview / self-healing description / field table / test index / report index | All added (§2/§4/§6/§7/§8/§10) |
| architecture figure 1 "cross-worker shared inventory" | **Corrected**: worker-private lease pools, a lease belongs to its creating worker, workers share the global quota via Redis |
| architecture figure 2 missing CLOSED/uncertain branches | Redrawn: GRANT's four classifications + CLOSED stripped out + uncertain not registered |
| architecture figure 3 SOLVED/OPEN outdated | Updated: Phase 2 EVALSHA / Phase 4 lease / Phase 7 performance / Phase 8.2 cleanup marked complete; Phase 5 Deferred honestly annotated |
| architecture table 1 legacy-era evidence | Rewritten as narrated sections with the current evidence sources (Phase 7/6.5 etc.) cited |
| architecture table 2 completed items still marked OPEN | Deleted/updated |
| Term conflation (lease/Lease/local inventory) | Unified as Lease (except historical quotations) |
| No systematic config field docs | CONFIGURATION.md full table (checked field by field against schema.lua, including mutual exclusions/validation rules) |
| No test run index | TESTING.md (categorized + prerequisites + serial/noise reminders + the "historical PASS cannot be reproduced with one click" statement) |
| Deployment info scattered | Consolidated into DEPLOYMENT.md (each command checked against compose/scripts) |

## 3. Core architecture semantics check (all items of 10.2)

| Check | Result |
|---|---|
| Description of batch>1 auto-returning inventory | ❌ absent (all wording says Deferred / no auto RETURN) |
| Workers sharing leases | ❌ absent (explicitly worker-private, structurally isolated) |
| Continuing to use unconfirmed inventory during Redis faults | ❌ absent (uncertain outcomes are not registered, not retried) |
| Multi-rule using leases | ❌ absent (explicitly not used; batch 0/1 constraint) |
| Redis exceptions returning 429 | ❌ absent (429 = deterministic rejection; faults go to 503/degraded) |
| Lease TTL described as inventory return | ❌ absent (explicitly "metadata TTL ≠ auto return") |
| Phase 5 described as complete | ❌ absent (all marked Deferred) |
| Shared dict as the current implementation | ❌ absent (explicitly removed, not depended upon) |
| batch>1 having equal timing precision to batch=1 | ❌ absent (explicitly pre-authorization/burst/loss exposure) |

## 4. Configuration field verification

CONFIGURATION.md's table verified field by field against schema.lua: limit (required)/window (60)/burst (0,≤1e8)/batch (0,≤1e8)/
limit_by (7-dimension one_of, default ip)/header_name (conditionally required)/rules (≤8, mutually exclusive with limit_by, batch∈{0,1})/
namespace (rl)/hide_client_headers (false)/fault_tolerant (false)/redis.{host,port,password,database,timeout,key_prefix}.
**No invented fields**; LEASE_TTL_MS is not listed as user-configurable (explicitly an internal constant).

## 5. Command verification

| Command | Verification basis |
|---|---|
| `docker compose up -d/down/down -v/--force-recreate` | compose file |
| `curl :8031/status` etc. admin ports 8031/8011/8021 | compose ports |
| `./bench/quota.sh -l 100 -b 1 -p 150` | quota.sh getopts "l:b:w:p:h" |
| `./bench/rules.sh` / `dims.sh` | actual files in bench/ |
| `bash bench/matrix.sh -b 10 / -w 1 / -L notice` | matrix.sh getopts and defaults |
| `bash test/*.sh` (15 scripts) | actual filenames in test/ |
| First request `X-RateLimit-Remaining: 19` | measured this round (batch auto→20, granted 20 consume 1) |

## 6. Performance data citation check

All numbers in README §8 and architecture §12 come from the formal Phase 7 report (clean-round means @1000 w2):
0.66/1.41/82.8, 0.50/1.16/87.1, 20001→2002 (roughly 9.99:1), 4773→869 (5.5×), CPU 0.348→0.269/0.079→0.021,
accounting 255800/247952/7848 (3.1% unconsumed/unconfirmed gap); p99 NOT VERIFIED honestly annotated; legacy data used only as historical reference.
No recomputation, no mixing, no new commitments.

## 7. Internal link check

Scripted verification (the `.md` relative links in README/architecture/DEPLOYMENT/CONFIGURATION/TESTING): **all 13 links valid, 0 broken**;
README's internal anchor `#9-known-limitations` was corrected.

## 8. Terminology consistency

Lease / GRANT_LEASE / GRANT_MULTI / CLOSED / outstanding / lost / batch=1 / batch>1 / fail-close /
EVALSHA / NOSCRIPT are used consistently across the five documents; historical reports keep their original wording untouched.

## 9. Unresolved issues

- No blocking issues. Remaining optimization items (all honestly annotated in the docs):
  - p99 causal attribution NOT VERIFIED (environmental noise)
  - Old pool reclamation / RETURN / metric export / Cluster / endurance: Deferred or not verified
  - phase1/2-manual's historical operational scope annotated but body not rewritten (historical record; preserved by convention)

## 10. Unverified content

- Kubernetes / Redis Cluster / production HA / endurance — the docs explicitly declare "not verified/Deferred" and must not claim otherwise
- Tiers not covered by Phase 7 (current batch=50/100 measurements, >1000 RPS) — annotated in TESTING.md/bench.md

## 11. Final acceptance conclusion

Against the task brief §13's 10 acceptance criteria:
1–3 (a new user understands the project / sets up the environment / understands the three paths) ✓; 4–5 (the lease mechanism / correct configuration) ✓; 6–7 (reproducing the main tests / understanding the performance benefit and its limits) ✓;
8 (no exaggeration of production maturity, including the "not a mature commercial product" statement) ✓; 9 (consistent with the frozen design, all §3 items pass) ✓;
10 (no known contradictions among docs/code/evidence, 0 broken links) ✓.

**Conclusion: Phase 8.2-C documentation consolidation complete; acceptance criteria met.**
