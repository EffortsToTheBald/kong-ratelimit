# Documentation Index

Classified by reading purpose. Code-first priority: schema.lua (configuration) > lib/*
(behavior) > documents in this directory.

## Current Architecture and Usage

| Document | Content |
|---|---|
| [README.md](../README.md) | Project overview, quick start, three modes, performance summary, known limitations |
| [CONFIGURATION.md](CONFIGURATION.md) | Full configuration field table (schema.lua basis) and dimension semantics |
| [DEPLOYMENT.md](DEPLOYMENT.md) | Deployment and environment (Compose verification environment setup, checks, troubleshooting, cleanup) |
| [TESTING.md](TESTING.md) | Test run index and prerequisites |
| [bench.md](bench.md) | Performance experiment protocol (Phase 7 basis) |

## Design and Architecture

| Document | Content |
|---|---|
| [design.md](design.md) | Design document (Current V1: layered error derivation, key/metadata model, Cluster boundary, Deferred) |
| [architecture.md](architecture.md) | Current architecture: three paths, Lease lifecycle, accounting identity, EVALSHA management, failure handling |
| [REMEDIATION.md](REMEDIATION.md) | Remediation gate records (Gates 1–6: audit, design freeze, implementation, acceptance) |
| [docker-mirror.md](docker-mirror.md) | China mirror-registry pulls and network troubleshooting |

## Phase Reports (historical evidence, frozen)

| Document | Content |
|---|---|
| [PHASE0_REVIEW.md](PHASE0_REVIEW.md) | Code-state review under the Phase 4 implementation spec (2026-11-12) |
| [review-phase-0.md](review-phase-0.md) | Original Phase 0 full review (2026-11-11; the two are not duplicates, see the Gate 6 record in REMEDIATION) |
| [PHASE2_REVIEW.md](PHASE2_REVIEW.md) / [PHASE3_GROUP1_REPORT.md](PHASE3_GROUP1_REPORT.md) / [PHASE4_WORKER_LEASE_REPORT.md](PHASE4_WORKER_LEASE_REPORT.md) | Phase 2/3/4 phase reports |
| [PHASE6_REQUEST_INTEGRATION_REPORT.md](PHASE6_REQUEST_INTEGRATION_REPORT.md) | Phase 6 integration acceptance (final integration report) |
| [V1_SCOPE_ADJUSTMENT.md](V1_SCOPE_ADJUSTMENT.md) | V1 scope adjustment record (lifecycle DEFERRED decision) |
| [results.md](results.md) | Phase 1 Legacy performance data (historical comparison; does not represent the current implementation) |
| [plan.md](plan.md) / early-version content of [design.md](design.md) | Historical plans |
| [reports/](reports/) | Frozen phase reports and audits for Phase 6.3–8.2 |
| [../reports/](../reports/) | Phase 1–3 phase evidence (outputs of the archived openspec changes for Phases 1–3, referenced by frozen Specs, not merged) |

## Archive

| Document | Content |
|---|---|
| [archive/rule.md](archive/rule.md) | The project's original SDD development spec and phased implementation document (Historical; most conclusions have evolved; the current basis is design.md) |
