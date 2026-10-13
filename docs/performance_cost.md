# Performance and Cost

| Topic | Decision |
|---|---|
| Warehouse sizing | XSMALL for load, BI and AI; SMALL for dbt. Scale up only for backfills when Query Profile shows remote spilling; scale back after (16_cost_monitoring.sql §2). |
| Workload separation | 4 warehouses (load / transform / BI / AI) so dashboards and AI never queue behind dbt, and AI spend is capped separately. Justified by distinct SLAs and the AI resource monitor. |
| Auto-suspend | 60 s on every warehouse; tasks use `WHEN SYSTEM$STREAM_HAS_DATA` so idle schedules start no warehouse. |
| Incremental models | Only where volume grows with time and late data matters: payment events, attempts, attempt fact, settlement fact. Everything else is a full table rebuild (simpler, cheap at this scale). |
| Efficient joins | Pre-aggregate one-to-many facts before joining (also the fan-out rule); point-in-time dimension joins on business key + validity range; integer date keys. |
| Clustering | Declared only on the four date-filtered incremental tables. Keep it only if `SYSTEM$CLUSTERING_INFORMATION` and partition pruning show benefit; at the default volume it is not needed — remove `cluster_by` to avoid reclustering credits. |
| Query profile analysis | Check *Most expensive nodes*, *partitions scanned vs total*, *bytes spilled*; the cost query (§3b) ranks dbt models by elapsed time via `query_tag`. |
| Snowpark vs SQL | SQL for all relational work. Snowpark only for the narrative parser (config-driven regex with named groups) and the dynamic-column profiler; both have SQL fallbacks. No Snowpark Container Services. |
| Cortex usage controls | Dedicated XSMALL warehouse, 120 s timeout, RM_FINTECH_AI, 50-row cap per AI batch, explanations cached in AUDIT (never regenerated for the same exception), usage queries (§3c). |
| Data retention | Time Travel 1 day DEV/TEST, 7 days PROD/AUDIT/CONFIG; transient work tables (`OPS.GEN_*`) avoid Fail-safe storage. |
| Avoiding compute | Result cache for repeated dashboard queries; views for light dashboard logic, tables for heavy marts; no always-on orchestration platform. |
