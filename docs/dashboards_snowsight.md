# Dashboards in Snowsight (no Streamlit, no external UI)

## Status of Snowsight dashboards (verified October 2026)

Snowflake deprecated **Legacy Worksheets and Legacy Dashboards**: creating new dashboards was disabled on
20 April 2026, and removal from Snowsight began on 22 June 2026. The official migration target for dashboards
is a Streamlit app — excluded by this project's requirements. Reader accounts were exempt at the time of writing.

What remains native and Python-free, and what this project uses:

1. **Workspaces SQL files with query charts** — run a query, open the *Chart* view of the result, pick the chart
   type (bar, line, scatter, heat grid, scorecard) and columns. One query = one chart. The `snowsight/` folder
   holds one file per "page" with every chart's settings in a comment above the query.
2. **Snowflake Intelligence / Cortex Analyst** over `SEMANTIC.SV_PAYMENTS` for ad-hoc, conversational charts.
3. **Tables with drill-down queries** where an interaction is not available (cross-filtering, click-through).

Verify in your account that the Chart option appears in Workspaces query results; if your account still has
Legacy Dashboards (e.g. a reader account), the same queries can be added as dashboard tiles.

## Setup (one time)

1. Run the deployment through `snowflake/11_dashboard_views.sql` (views) and a successful `dbt build`.
2. Snowsight → **Projects → Workspaces** → *My Workspace* → **+ Add new → Upload files** (or create SQL files and
   paste). Upload `snowsight/01_executive_overview.sql` … `06_cortex_fallback_questions.sql`.
   Optionally connect the Git repository to the workspace so the files stay version-controlled.
3. In each file set the context (role, warehouse, database) — already at the top of each file.
4. Run a single query (cursor inside it, *Run*), click **Chart** in the results pane, and apply the settings
   from the comment above it. Charts are saved with the file.

## Required privileges

| Page | Role | Objects |
|---|---|---|
| Executive, trends, channels, merchants, refunds, reconciliation, fraud, risk | FINTECH_ANALYST (or regional analyst: row access applies) | SELECT on DASHBOARD views, SEMANTIC base, MARTS; CORE for drill-downs; USAGE on WH_FINTECH_BI |
| Data quality / pipeline | FINTECH_ANALYST (views use owner's rights over AUDIT) | DASHBOARD.VW_DATA_QUALITY_STATUS / VW_PIPELINE_EXECUTION_STATUS |
| Task history drill-down | FINTECH_OPS | MONITOR on tasks |
| AI explanations table | FINTECH_ANALYST | DASHBOARD.VW_RECON_EXCEPTION_AI_EXPLANATIONS |

## Chart catalogue

| Id | File | Question | Source view | Chart | X / dimension | Y / measure | Series | Filters | Drill-down |
|---|---|---|---|---|---|---|---|---|---|
| E1 | 01 | Headline KPIs | VW_EXECUTIVE_PAYMENT_KPIS | Scorecards | – | volume, success %, match %, outstanding, refund %, alerts | – | `$period` | E3 definitions |
| E2 | 01 | This vs previous 30 days | VW_EXECUTIVE_PAYMENT_KPIS | Bar | period | payment_volume_inr | – | – | – |
| T1 | 02 | Volume trend | VW_DAILY_PAYMENT_TREND | Line | date_ist (day/week/month bucket) | volume, 7-day avg | – | `$start_date`, `$end_date` | – |
| T2 | 02 | Success vs failure | VW_DAILY_PAYMENT_TREND | Line | date_ist | success %, failure % | – | dates | – |
| T3 | 02 | Biggest failure increases | VW_DAILY_PAYMENT_TREND | Bar | date_ist | failed_change_vs_prior_day | – | dates | C3 |
| C1 | 02 | Volume by channel | VW_PAYMENT_CHANNEL_PERFORMANCE | Stacked bar | month_start | payment_volume_inr | channel_code | dates, `$channel_group` | – |
| C2 | 02 | Success heat grid | VW_PAYMENT_CHANNEL_PERFORMANCE | Heat grid | month_start | channel_code / success % | – | dates | C3 failure reasons |
| M1 | 03 | Top merchants | VW_MERCHANT_PERFORMANCE | Horizontal bar | merchant_name | payment_volume_inr | – | `$report_month`, `$region` | R3 |
| M2 | 03 | Settlement mismatch by merchant | VW_MERCHANT_PERFORMANCE | Bar | merchant_name | settlement_mismatch_inr | – | month, region | S5 |
| M3 | 03 | Refund vs chargeback risk | VW_MERCHANT_PERFORMANCE | Scatter | refund_rate_pct | chargeback_rate_pct | – | month | – |
| R1 | 03 | Refunds by channel/month | VW_REFUND_AND_CHARGEBACK_SUMMARY | Grouped bar | month_start | refund_amount_inr | channel_group | region | R3 |
| R2 | 03 | Chargeback trend | VW_REFUND_AND_CHARGEBACK_SUMMARY | Line | month_start | chargeback amount, count | – | – | – |
| S1 | 04 | Match rate, outstanding | VW_SETTLEMENT_RECONCILIATION_SUMMARY | Scorecards | – | match %, outstanding | – | – | S5 |
| S2 | 04 | Status mix | VW_SETTLEMENT_RECONCILIATION_SUMMARY | Stacked bar | month_start | item_count | recon_status | – | S5 |
| S3 | 04 | Batch ↔ bank | VW_SETTLEMENT_RECONCILIATION_SUMMARY | Bar | recon_status | batches | – | – | S5 |
| S4 | 04 | Exception aging | VW_RECON_EXCEPTION_DETAIL | Stacked bar | age_bucket | exceptions | severity | – | S5 |
| S5/S6 | 04 | Exception list; one payment end-to-end | VW_RECON_EXCEPTION_DETAIL, facts | Table | – | – | – | `$exception_type`, `$src`, `$txn` | – |
| F1 | 05 | Alerts per day | VW_FRAUD_MONITORING_SUMMARY | Stacked bar | alert_date_ist | alert_count | severity | – | F3 |
| F2 | 05 | Rule effectiveness | VW_FRAUD_MONITORING_SUMMARY | Scatter | alert_count | confirmation % | – | – | F3 |
| Q1/Q2 | 05 | DQ board | VW_DATA_QUALITY_STATUS | Table / Bar | status | checks | check_source | – | CNL_EXCEPTIONS |
| P1 | 05 | Pipeline status | VW_PIPELINE_EXECUTION_STATUS | Table | – | – | – | – | P2 task history |
| K1 | 05 | Risk transitions | VW_CUSTOMER_RISK_TRANSITIONS | Stacked bar | month_start | customer_versions | risk_change | – | – |

## Refresh behaviour

Charts show the data as of the last run of their query. Underlying tables refresh when dbt builds
(CI schedule or the optional `EXECUTE DBT PROJECT` task); operational views (DQ, pipeline) refresh as tasks write
AUDIT rows. Re-running a query within 24 hours with unchanged data is served from Snowflake's result cache at no
compute cost. Date controls are session variables (`SET start_date = ...`); change and re-run.

## Not available natively (and the alternative used)

| Desired interaction | Alternative |
|---|---|
| Tiled multi-chart canvas | One Workspaces file per page; charts listed in order |
| Click-to-filter / cross-filter | Parameterised drill-down queries (`SET drill_* = ...`) |
| Scheduled e-mail of a dashboard | Snowflake Alerts / `SYSTEM$SEND_EMAIL` from tasks with KPI text (09_streams_tasks.sql) |
| Conversational exploration | Snowflake Intelligence over semantic views |
