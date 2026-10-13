# Canonical Enterprise Data Model

The CANONICAL schema makes every provider look the same to everything downstream.

## Global standards

| Topic | Standard |
|---|---|
| Identifiers | Provider ids are **never** assumed globally unique. Every key is namespaced: `md5(source_system \| source_transaction_id)`. (PROV_A and PROV_C both emit `TXN##########`; verification query V05 proves no key collision.) |
| Surrogate keys | `surrogate_key()` macro: MD5 of `\|`-joined, null-safe values. Deterministic, so keys are stable across rebuilds. |
| Original values | Kept beside canonical values: `amount_raw`, `source_status`, `event_ts_raw`, `source_record` (VARIANT) in staging. |
| Timestamps | Canonical `*_utc` columns are `TIMESTAMP_NTZ(9)` in UTC. Provider conventions (from `vars.payment_providers`): PROV_A IST wall clock string, PROV_B epoch milliseconds, PROV_C ISO-8601 with offset. Reporting columns `*_ist` / `date_ist` use `Asia/Kolkata`. |
| Money | `NUMBER(18,2)` in **major units**. Minor-unit providers divide by `10^minor_units` of the currency (seed `currency`). Reporting currency INR via monthly FX (`fx_rates_monthly`, synthetic). Original currency always kept. |
| Status | Provider status → `CONFIG.STATUS_MAPPING` → canonical status + category + terminal flag + rank. Unknown values flow to `CNL_EXCEPTIONS` (`UNKNOWN_STATUS`), never dropped. |
| Current status | Latest **terminal** known event, else latest known event, ordered by **event time** (not ingestion time), ties broken by `status_rank`. Late or out-of-order events resolve correctly. |
| Audit attributes | `batch_id`, `ingestion_timestamp_utc`, `canonical_updated_at`, plus source file name in staging. |
| Validity | Rows failing a rule are kept with `is_valid_record = false` and an exception row; facts keep them for row-count reconciliation, metrics filter them out. |

## Entities

| Entity | Model | Business meaning | Grain | Business key | Surrogate key | Status normalisation | DQ tests |
|---|---|---|---|---|---|---|---|
| Party / Customer | `cnl_party_customer` | A person who pays | customer | customer_id | canonical_party_id | – | unique/not_null customer_id |
| Customer KYC History | `cnl_customer_kyc_history` | KYC level/status/risk at each change | customer × KYC event | customer_id + kyc_event_id | canonical_kyc_version_id | upper-cased enums | scd2_valid_windows, accepted_values risk |
| Customer Risk Profile | `cnl_customer_risk_profile` | Current risk + history summary + treatment | customer | customer_id | – | – | unique |
| Merchant | `cnl_merchant` (current), `snap_merchants` (history) | Seller receiving funds; fee rate & settlement cycle | merchant | merchant_id | canonical_merchant_id | upper region | unique, non_negative fee |
| Payment Instrument | `cnl_payment_instrument` | Tokenised card/VPA/account (token + last4 only) | source_system × token | source_system + instrument_token | canonical_instrument_id | – | unique |
| Payment Transaction | `cnl_payment_transaction` | Merchant's payment intent across retries & providers | merchant × merchant_order_id | merchant_id + merchant_order_id | canonical_transaction_id | precedence CAPTURED > REVERSED > VOIDED > in-progress > FAILED | unique, canonical_status_valid |
| Payment Attempt | `cnl_payment_attempt` | One provider authorisation/capture attempt | provider attempt | source_system + source_transaction_id | canonical_attempt_id | via events | unique, status valid, non_negative, currency FK, timestamp not null |
| Payment Event / Status History | `cnl_payment_event` | Each status change (events + record snapshots) | event | source_system + event id | canonical_event_id | STATUS_MAPPING (PAYMENT) | unique, status valid |
| Refund | `cnl_refund` | Money returned to the customer (partial allowed) | refund | refund_id | canonical_refund_id | REFUND domain | unique, status valid |
| Refund Event | `cnl_refund_event` | Refund status change | refund event | refund_event_id | canonical_refund_event_id | REFUND domain | unique |
| Settlement | `cnl_settlement` | Provider payout report line (SALE/REFUND/CHARGEBACK/ADJUSTMENT) | settlement line | settlement_line_id | canonical_settlement_id | type upper-cased | unique, line balanced (warn) |
| Bank Statement Transaction | `cnl_bank_statement_transaction` | Entry on the merchant collection account | bank line | bank_txn_id | canonical_bank_txn_id | DR/CR sign | unique, accepted DR/CR, non_negative |
| Chargeback | `cnl_chargeback` | Card dispute | chargeback | chargeback_id | canonical_chargeback_id | CHARGEBACK domain | unique, status valid |
| Fraud Alert | `cnl_fraud_alert` (+ platform rules in `int_customer_velocity`) | Suspicious-activity indicator | alert | alert_id | canonical_alert_id | upper status | unique |
| Currency | `cnl_currency` | ISO 4217 + minor units | currency | currency_code | currency_code | – | unique |
| Payment Channel | `cnl_payment_channel` | UPI, wallet, debit/credit card, NEFT/IMPS/RTGS | channel | channel_code | channel_code | provider values → channel_code | unique |
| Exceptions | `cnl_exceptions` | Anything not fully canonicalised | exception | type + entity + key | exception_id | – | unique |

## Payment Attempt attribute definitions (core entity)

| Attribute | Type | Definition | PROV_A | PROV_B | PROV_C |
|---|---|---|---|---|---|
| source_system | VARCHAR(20) | Provider code | literal | literal | literal |
| source_transaction_id | VARCHAR | Provider attempt id (unique only within provider) | txn_ref | payment_id | reference_no |
| canonical_attempt_id | VARCHAR(32) | md5(source_system\|source_transaction_id) | derived | derived | derived |
| canonical_transaction_id | VARCHAR(32) | md5(merchant_id\|merchant_order_id) | derived | derived | derived |
| merchant_order_id | VARCHAR | Merchant's order reference (links retries) | order_id | merchant_reference | customer_ref |
| merchant_id / customer_id | VARCHAR | Business keys | merchant_code / cust_id | merchant_id / customer_id | merchant_ref / payer_id |
| amount_raw | VARCHAR | As delivered | amt (major) | payment_amount (minor) | amount_value (major) |
| transaction_amount | NUMBER(18,2) | Major units | as is | ÷ 10^minor_units | as is |
| currency_code | VARCHAR(3) | ISO code, validated against seed | ccy | currency | currency_code |
| source_status → transaction_status | VARCHAR | Original → canonical | txn_status | state | status_code |
| event_ts_raw → event_timestamp_utc | VARCHAR → TIMESTAMP_NTZ | Provider time → UTC | txn_time (IST string) | created_at_ms (epoch ms) | value_ts (ISO+offset) |
| channel_code | VARCHAR | Via RAW.PAYMENT_CHANNELS | channel | method | rail |
| canonical_instrument_id | VARCHAR(32) | md5(source_system\|token) | vpa_token | card_token | account_token |
| is_valid_record | BOOLEAN | amount > 0 ∧ currency valid ∧ status known ∧ timestamp parsed ∧ business key present | | | |
| batch_id, ingestion_timestamp_utc, canonical_updated_at | audit | | | | |

The same table is published in Snowflake as `CANONICAL.CFG_SOURCE_ATTRIBUTE_MAPPING` (generated from dbt vars).

## Status normalisation (excerpt of CONFIG.STATUS_MAPPING)

| Canonical | Category | PROV_A | PROV_B | PROV_C |
|---|---|---|---|---|
| CREATED | IN_PROGRESS | INITIATED | created | – |
| PENDING | IN_PROGRESS | PENDING | – | 09 |
| AUTHORIZED | IN_PROGRESS | – | authorized | – |
| CAPTURED | SUCCESS | SUCCESS | captured, refunded | 00 |
| FAILED | FAILURE | FAILED | declined, failed | 05, 91 |
| REVERSED | REVERSAL | REVERSED | – | R1 |
| VOIDED | REVERSAL | – | voided | – |

## Onboarding a new provider (PROV_D) without redesigning downstream models

1. **Config (runtime):** register `CONFIG.SOURCE_SYSTEM` row; add `STATUS_MAPPING` rows through the
   change-request workflow (`STATUS_MAPPING_UPSERT`); add `RAW.PAYMENT_CHANNELS` rows.
2. **Mapping (deployment, ~25 lines of YAML):** add a `PROV_D` block to `vars.payment_providers` in
   `dbt_project.yml` (field names, timestamp convention, amount unit). Open a PR; CI runs `dbt build` on TEST.
3. **Files:** create `LANDING.PAYMENTS_PROV_D` with the provider's columns and a `CONFIG.FILE_CONTRACT`
   row; `OPS.SP_PROMOTE_LANDING_PAYMENTS('PROV_D', batch)` loads it into RAW.PAYMENTS unchanged
   (payload is VARIANT; keys read case-insensitively).
4. **Nothing else changes.** Staging unions providers from the vars loop; canonical, facts, marts,
   semantic views and dashboards are provider-agnostic. Until step 2 is deployed, PROV_D rows land in
   `CNL_EXCEPTIONS` as `UNMAPPED_PROVIDER` instead of disappearing.
5. Unknown PROV_D status codes surface as `UNKNOWN_STATUS` exceptions and are fixed with a runtime mapping change.
