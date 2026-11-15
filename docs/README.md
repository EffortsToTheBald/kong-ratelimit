# 文档索引

按阅读目的分类。以代码为准的优先级：schema.lua（配置）> lib/*（行为）> 本目录文档。

## 当前架构与使用

| 文档 | 内容 |
|---|---|
| [README.md](../README.md) | 项目总览、快速启动、三种模式、性能摘要、已知限制 |
| [CONFIGURATION.md](CONFIGURATION.md) | 配置字段全表（schema.lua 口径）与维度语义 |
| [DEPLOYMENT.md](DEPLOYMENT.md) | 部署与环境（Compose 验证环境搭建、检查、排障、清理） |
| [TESTING.md](TESTING.md) | 测试运行索引与前置条件 |
| [bench.md](bench.md) | 性能实验协议（Phase 7 口径） |

## 设计与架构

| 文档 | 内容 |
|---|---|
| [design.md](design.md) | 设计文档（Current V1：误差分层推导、Key/元数据模型、Cluster 边界、Deferred） |
| [architecture.md](architecture.md) | 当前架构：三路径、Lease 生命周期、账目恒等式、EVALSHA 管理、故障处理 |
| [REMEDIATION.md](REMEDIATION.md) | 整改关口记录（关口一至六：审计、设计冻结、实施、验收） |
| [docker-mirror.md](docker-mirror.md) | 国内镜像站拉取与网络排障 |

## 阶段报告（历史证据，冻结）

| 文档 | 内容 |
|---|---|
| [PHASE0_REVIEW.md](PHASE0_REVIEW.md) | Phase 4 实施规范下的代码现状审查（2026-11-12） |
| [review-phase-0.md](review-phase-0.md) | 原始 Phase 0 全面审查（2026-11-11；两者非重复，见 REMEDIATION 关口六记录） |
| [PHASE2_REVIEW.md](PHASE2_REVIEW.md) / [PHASE3_GROUP1_REPORT.md](PHASE3_GROUP1_REPORT.md) / [PHASE4_WORKER_LEASE_REPORT.md](PHASE4_WORKER_LEASE_REPORT.md) | Phase 2/3/4 阶段报告 |
| [PHASE6_REQUEST_INTEGRATION_REPORT.md](PHASE6_REQUEST_INTEGRATION_REPORT.md) | Phase 6 集成验收（最终集成报告） |
| [V1_SCOPE_ADJUSTMENT.md](V1_SCOPE_ADJUSTMENT.md) | V1 范围调整记录（生命周期 DEFERRED 决策） |
| [results.md](results.md) | Phase 1 Legacy 性能数据（历史对照，不代表当前实现） |
| [plan.md](plan.md) / [design.md](design.md) 早期版本相关内容 | 历史计划 |
| [reports/](reports/) | Phase 6.3–8.2 各阶段冻结报告与审计 |
| [../reports/](../reports/) | Phase 1–3 阶段证据（Phase 1–3 openspec 归档 change 的产出物，路径被冻结 Spec 引用，不合并） |

## 归档

| 文档 | 内容 |
|---|---|
| [archive/rule.md](archive/rule.md) | 项目最初 SDD 开发规格与分阶段实施文档（Historical；多数结论已演进，当前口径以 design.md 为准） |
