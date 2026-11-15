# Phase 8.2-C Audit Report: Final Delivery Documentation Audit (Round 1)

- **Date**: 2026-11-14
- **Baseline HEAD**: `96575ee` (clean workspace, only `1113.json` untracked)
- **Nature**: audit only, no file modifications; proceed to documentation consolidation only after human confirmation of the audit scope

---

## 0. Audit scope and method

- Full read: README.md (all 232 lines), docs/architecture.md (all 213 lines), docs/bench.md, docs/plan.md, docs/docker-mirror.md, docs/design.md (frozen), docs/rule.md (frozen), docs/results.md (legacy baseline), all Phase reports, schema.lua field definitions, the current handler/algorithm/lease/redis implementations, the test/ and bench/ script inventories, docker-compose.yml, kong/kong.yml
- Method: each suspicion verified against the current code/frozen reports (batch=auto measured `clamp(limit/50,1,50)=20`, quota.sh's `-l/-b/-p` parameters actually exist, compose ports 8030/8010/8020, k6 NODES, etc.)

## 1. Audit summary table

| Document | Current issues | Target adjustment | Modify? |
|---|---|---|---|
| **README.md** | ① §6 performance matrix command outdated (actual defaults BATCHES=10,50,100 / RATES=100,500,1000, artifacts at bench/out/results-\*.md not bench/results.md; no mention of the leaseGrant column or the debug statistics scope); ② §7 acceptance checklist's "batch=20 p99 differs from baseline <1ms" has no current evidence (Phase 7's environment has an ~80ms p99 noise floor, a NOT VERIFIED scope); ③ §5 batch table's "typical p99 increment" numbers have no current measurement (Phase 7 did not test the 5/20 tiers); ④ §0's one-sentence design summary covers only batch>1 pre-authorization, not the three modes; ⑤ missing a three-path overview (batch=1 / batch>1 lease / multi-rule) and the EVALSHA self-healing description; ⑥ missing a systematic config field table (scattered across sections); ⑦ missing run instructions for the full test/ suite and a report index; ⑧ the directory tree lacks test/, redis/ (dual-source), docs/reports/ | Rewrite as a complete README for new users (the §5.1–5.8 scope), with outdated commands/numbers replaced by measured values and performance citing Phase 7 | ✅ (round 2) |
| **docs/architecture.md** | ① figure 1's mermaid still draws "POOL local inventory · cross-worker shared" and REPL "2 workers share the same local inventory" — **contradicts V1's worker-private leases (the most important outdated point)**; ② figure 2's decision flow lacks CLOSED/exhaustion re-request/timeout-uncertain→fault branches; "remainder into the local pool" is legacy wording; ③ figure 3's SOLVED zone stops at Phase 3 and the OPEN zone lists already-completed items ("Phase 4 EVALSHA/performance matrix", done in Phase 2/7) → outdated; "debug logs are a temporary state" was already addressed by 8.2-B; ④ some of table 1's "verification evidence" is legacy-era data (e.g., "granted 600 = consumed 90 + local 510") and needs a historical annotation; ⑤ several of table 2's open issues are already done (EVAL→EVALSHA Phase 2, performance matrix Phase 7); ⑥ missing a three-mode differences table, the lease lifecycle (ACTIVE→CLOSED), inventory accounting (granted=consumed+outstanding / lost), EVALSHA self-healing, and performance trade-offs (Phase 7 citation); ⑦ "lease/Lease/local inventory" term conflation | Consolidate into a current-implementation architecture doc (the 14-item checklist in task brief §6), annotate historical evidence with its era, unify terminology as Lease | ✅ (round 2) |
| **docs/DEPLOYMENT.md (new)** | Deployment info scattered across README §2/§3/§9 + compose comments, no standalone deployment doc; missing systematic coverage of environment dependencies/service checks/plugin loading/Redis verification/cleanup; must make clear that DB-less/Compose verification ≠ K8s/Cluster/production HA verification | Add (including startup/checks/request verification/Redis verification/troubleshooting/cleanup; each command checked against the repo) | ✅ New (round 2) |
| **docs/CONFIGURATION.md (new)** | Schema fields have no systematic doc: limit/window/burst/limit_by/header_name/batch/rules/namespace/hide_client_headers/fault_tolerant/redis.\* (schema.lua's measured defaults are complete); missing the policy fingerprint/batch trade-off/LEASE_TTL_MS non-configurable explanations | Add a field table (schema.lua as the authority, no invented fields) | ✅ New (round 2) |
| **docs/TESTING.md (new)** | test/'s 15+ scripts have no run index; missing environment prerequisites (Docker/Kong/Redis containers, compose's default notice level), how to run each test category, and cleanup requirements; performance citing Phase 7 | Add (categorized index of unit/Lua matrix/E2E/fault/isolation/config-isolation/performance) | ✅ New (round 2) |
| **docs/bench.md** | §1's "worker process count 2 is related to shared-dict behavior" is outdated; "duration ≥30s" conflicts with Phase 7's actual 20s scope; the four experiment protocols are legacy-era designs | Update to the current experiment protocol (Phase 7's actual scope), annotate the legacy section as historical | ✅ (round 2) |
| **docs/plan.md** | The 4-day implementation roadmap is an early historical plan, inconsistent with the actual evolution (Phase 0–8.2) | **Keep as a historical doc**, adding only a header note "historical plan; for the actual evolution see docs/reports/" | ✅ (annotation only) |
| **docs/docker-mirror.md** | A network image-pull guide, still valid | Unchanged | ❌ |
| **test/phase1-manual.md** | Contains RL-DEBUG notice-era operational scope (local_fill/redis_grant counting) — the 8.2-B report already stated Batch C would handle it | Add a header note "historical record (Phase 1-era scope)" without changing the body | ✅ (annotation only) |
| **test/phase2-manual.md** | Same nature | Same, header annotation | ✅ (annotation only) |
| **design.md sections 8/9 referenced by docs/plan.md (cited by README §8)** | Links valid (design.md exists) | Keep | ❌ |
| **docs/design.md, rule.md, V1_SCOPE_ADJUSTMENT.md, docs/results.md, docs/PHASE0/2/3 reports, docs/PHASE4/6 reports, docs/reports/PHASE6_3/4/5/7/8_A/8_B, reports/phase-\*, docs/review-phase-0.md, openspec/\*** | Frozen material/historical reports | **All preserved as-is** | ❌ |
| **docker-compose.mirror.yml / scripts/pull-images.sh / k6/\*.js / redis/\*.lua (dual-source)** | No doc issues | Just add entries in README's directory tree | ❌ (code untouched) |

## 2. Outdated points inconsistent with the current code (per-item evidence)

1. **README §6**: `./bench/matrix.sh  # default batch 0,1,5,20 × RPS 200,1000` — the actual code is `BATCHES="${BATCHES:-10,50,100}"`, `RATES="${RATES:-100,500,1000}"` (matrix.sh:38-39); artifacts at `bench/out/results-<TAG>-*.md` (matrix.sh:291), not `bench/results.md`
2. **README §3 response example**: `X-RateLimit-Remaining: 997` — kong.yml actually has limit=1000/window=60/batch=0 (auto→20); in lease mode the first request's remaining=granted−1 (19 with batch=20, not 997); the example must be re-measured against the current implementation and annotated honestly
3. **README §5 table**: "batch=0 auto: clamp(limit/50,1,50)" — verified in code (algorithm.lua:167–175, consistent with kong.yml's comment ✓, keep); "typical p99 increment ~0.3–1ms/≈0" — **no current measurement** (Phase 7 tested only batch=1/10/multi-rule; p99's noise floor is environment-dominated); replaced with a citation of Phase 7's measurements with the tier coverage annotated
4. **README §7**: "batch=20's p99 differs <1ms from the no-plugin baseline" — Phase 7 clean rounds have M0 p99=12.6ms, b10=87.1ms; that assertion does not hold / cannot be attributed (NOT VERIFIED) ⇒ must be rewritten
5. **architecture figures 1/2/3**: see summary table items ①②③ (cross-worker shared inventory, SOLVED stuck at Phase 3, OPEN items already completed)
6. **bench.md §1**: "worker process count 2 is related to shared-dict behavior" — the shared dict was removed (8.2-A)
7. **Terminology**: architecture.md's "lease/leasing mode" and README's "inventory/lease" conflated with the frozen docs' "Lease" ⇒ unified as Lease (preserved when quoting historical originals)

## 3. Content duplication

- README §5's multi-rule block, architecture figure 2's multi-rule branch, and design.md's frozen content duplicate each other — README keeps a brief version and links the frozen doc
- Deployment info scattered across README §2/§3/§9 and compose comments ⇒ consolidated into DEPLOYMENT.md; README keeps quick start and links

## 4. Missing necessary information (to be added)

1. Three-mode differences comparison table (README + architecture)
2. Lease lifecycle and inventory accounting (architecture)
3. Full configuration field table (CONFIGURATION.md)
4. Test run index and environment prerequisites (TESTING.md)
5. EVALSHA/NOSCRIPT self-healing description (README features + architecture mechanism section)
6. Report index (navigation for all frozen material in docs/ and docs/reports/)
7. Production boundary and Deferred summary (README §7 known-limitations rewrite, referencing Phase 6.6 §14)

## 5. Exaggerations or insufficient evidence (must be eliminated)

| Location | Wording | Problem |
|---|---|---|
| README §5 table "typical p99 increment" | Number-level commitment | No current measurement |
| README §7 | "p99 differs <1ms" | Contradicts Phase 7's environmental measurements (NOT VERIFIED) |
| README §10 | "Redis load ÷batch" | Wording should cite Phase 7's measurements (authorization commands 20001→2002, roughly 9.99:1; total QPS 5.5×) |
| architecture table 1 | Some data is legacy-era | Needs a historical annotation; must not be passed off as the lease implementation |
| (Potential risk) any wording that describes the lease TTL's PEXPIRE as "auto return" | — | No such wording was found in the audit, but round-2 consolidation must guard against it |

## 6. Historical content that must be preserved (no changes)

- docs/results.md (legacy baseline), docs/PHASE0_REVIEW/PHASE2_REVIEW/PHASE3_GROUP1/PHASE4_WORKER_LEASE/PHASE6_REQUEST_INTEGRATION, docs/reports/PHASE6_3/6_4/6_5/7/8_A/8_B/8_CLEANUP_PLAN, docs/V1_SCOPE_ADJUSTMENT.md, docs/review-phase-0.md, docs/design.md, docs/rule.md, reports/phase-\*.md, test/phase1-manual.md, test/phase2-manual.md, bench/raw/phase7/
- Historical reports keep the facts as they were produced; current implementation descriptions go only into README/architecture/the new docs

## 7. Round-2 plan (to execute after human confirmation)

1. README.md rewrite (the §5.1–5.8 scope)
2. docs/architecture.md consolidation (the 14-item checklist)
3. Add docs/DEPLOYMENT.md, docs/CONFIGURATION.md, docs/TESTING.md
4. docs/bench.md update + header historical annotations in docs/plan.md, test/phase\*-manual.md
5. Consistency review (terminology/design/evidence/links) + `docs/reports/PHASE8_C_DOCUMENTATION_REPORT.md`
6. After `git diff --check`, commit independently and stop for review

**Change-scope preview**: README.md, docs/architecture.md, docs/bench.md, docs/plan.md (annotation), test/phase1-manual.md (annotation), test/phase2-manual.md (annotation), docs/DEPLOYMENT.md (new), docs/CONFIGURATION.md (new), docs/TESTING.md (new), docs/reports/PHASE8_C_DOCUMENTATION_AUDIT.md (this report), docs/reports/PHASE8_C_DOCUMENTATION_REPORT.md (new in round 2). Zero changes to production code/test scripts/bench scripts/frozen reports/raw data.
