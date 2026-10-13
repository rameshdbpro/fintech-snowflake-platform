# Sample KPI Results

No Snowflake account was available when this project was built, so **no numbers below were produced by a
Snowflake run**. Two kinds of figures are given, clearly separated:

## 1. Exact expected results for the controlled edge cases (hand-computed, enforced by tests)

These are deterministic and are asserted by dbt test `assert_edge_case_expected_outcomes` and `CONFIG.EXPECTED_TEST_OUTCOME`.
Filter any view on `merchant_id = 'M_EDGE'` (or `source_transaction_id LIKE 'EDGE%'`) to reproduce them.

| KPI (merchant M_EDGE only) | Expected value | Derivation |
|---|---|---|
| Valid payment transactions | 11 | 14 edge orders minus the 3 invalid ones (E10) |
| Successful payment count | 10 | all valid orders except EDGE-ORD-0013 (reversed) |
| Payment volume (INR) | 89,500.00 | 1,000 + 2,500 + 50,000 + 10,000 + 1,200 + 4,000 + 8,000 + 6,000 + 6,000 + 800 |
| Payment success rate | 90.91% | 10 / 11 terminal transactions |
| Payment attempt count | 13 | EDGE-A-0001, B-0002a/b/c, C-0003, B-0004, A-0006, B-0007, B-0008, A-0013, B-0014, B-0015, PROV_C EDGE-A-0001 (E10 attempts are invalid) |
| Refund amount (INR) | 5,000.00 | E04: 3,000 + 2,000 |
| Chargeback amount (INR) | 8,000.00 | E08 lost |
| Settlement statuses | MATCHED 7, UNSETTLED 1, AMOUNT_MISMATCH 1, PARTIALLY_SETTLED 1, NOT_APPLICABLE 1 | E01, E02c, E03, E04, E08, E14, B-0014 / E06 / E07 / B-0015 / E11 |
| Settlement match rate | 70.00% | 7 / 10 settleable |
| Outstanding settlement (INR) | 3,300.00 | E06 1,200 + E07 100 + B-0015 2,000 |
| Batch SB-PE-20260411 | net 69,945.18, MATCHED | 84,950.00 sale gross − 2,004.82 fee & GST − 5,000 refunds − 8,000 chargeback |
| Batch SB-PE-20260412 | net 1,952.80, MISSING_BANK_CREDIT | 2,000 − 40.00 fee − 7.20 GST |
| Bank ref SB-PE-20260413 | 999.00, UNMATCHED_BANK_CREDIT | no such batch |
| Orphan settlement | 750.00 UNMATCHED_SETTLEMENT | SL-EDGE-E05 |
| Customer C_EDGE | 3 KYC versions, current HIGH | E09 |

## 2. Full synthetic population (default generator run)

Produce the actual figures after deployment with:

```sql
SELECT * FROM DASHBOARD.VW_EXECUTIVE_PAYMENT_KPIS ORDER BY sort_order;      -- V12
SELECT recon_status, COUNT(*) FROM MARTS.MART_SETTLEMENT_RECONCILIATION GROUP BY 1;
```

What to expect from the generator's design parameters (seed `FINTECH-2026`, 50,000 orders, 2026-04-01..2026-09-30).
These are **design targets**, not measured results; deterministic per seed, so your run will produce the same values
every time and the exact numbers become your regression baseline:

| KPI | Design target |
|---|---|
| Orders / attempts | 50,000 orders; ≈ 1.16 attempts per order (10% two attempts, 3% three) → ≈ 58,000 attempts (+ edge cases) |
| Provider mix | ≈ 45% PROV_A, 40% PROV_B, 15% PROV_C |
| Payment success rate | ≈ 87% of terminal orders captured; ≈ 1.5% reversed (PROV_A/C); ≈ 8.5% failed; ≈ 3% left pending (excluded from the rate) |
| Refunds | ≈ 6% of captured attempts refunded, 30% of those twice (partial) ; ≈ 95% processed |
| Chargebacks | ≈ 0.8% of captured card payments |
| Settlement | ≈ 96.5% MATCHED; ≈ 2% UNSETTLED; ≈ 0.5% PARTIALLY_SETTLED; ≈ 0.5% AMOUNT_MISMATCH |
| Bank | ≈ 1% batches MISSING_BANK_CREDIT; ≈ 1% BATCH_AMOUNT_MISMATCH (25.00 bank charge); ≈ 5% credited a day late |
| Fraud | ≈ 1% of attempts with vendor alerts + burst customer C0000007 velocity alerts |
