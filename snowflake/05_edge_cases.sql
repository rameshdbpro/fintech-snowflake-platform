/* =====================================================================
   05_EDGE_CASES.SQL  -  controlled known-answer test cases
   Fixed identifiers (prefix EDGE) with hand-computed expected outcomes in
   CONFIG.EXPECTED_TEST_OUTCOME. dbt singular test
   tests/assert_edge_case_expected_outcomes.sql compares them to the marts.

   Merchant M_EDGE: fee 2.00%, GST 18% on fee, T+1 settlement.
     fee(g) = ROUND(g*0.02,2); tax = ROUND(fee*0.18,2); net = g - fee - tax

   Run AFTER 04 (generator) and BEFORE dbt. Re-runnable (deletes EDGE rows).
   ===================================================================== */
USE ROLE FINTECH_DEPLOYER;
SET DB_NAME = 'FINTECH_DEV';
USE DATABASE IDENTIFIER($DB_NAME);
USE WAREHOUSE WH_FINTECH_LOAD;

SET EDGE_BATCH = 'EDGE-CASES-V1';

-- clean previous edge rows ---------------------------------------------
DELETE FROM RAW.PAYMENTS                    WHERE BATCH_ID LIKE 'EDGE%';
DELETE FROM RAW.PAYMENT_STATUS_HISTORY      WHERE BATCH_ID LIKE 'EDGE%';
DELETE FROM RAW.CUSTOMERS                   WHERE BATCH_ID LIKE 'EDGE%';
DELETE FROM RAW.CUSTOMER_KYC_HISTORY        WHERE BATCH_ID LIKE 'EDGE%';
DELETE FROM RAW.MERCHANTS                   WHERE BATCH_ID LIKE 'EDGE%';
DELETE FROM RAW.REFUNDS                     WHERE BATCH_ID LIKE 'EDGE%';
DELETE FROM RAW.REFUND_STATUS_HISTORY       WHERE BATCH_ID LIKE 'EDGE%';
DELETE FROM RAW.BANK_SETTLEMENTS            WHERE BATCH_ID LIKE 'EDGE%';
DELETE FROM RAW.BANK_STATEMENT_TRANSACTIONS WHERE BATCH_ID LIKE 'EDGE%';
DELETE FROM RAW.CHARGEBACKS                 WHERE BATCH_ID LIKE 'EDGE%';
DELETE FROM RAW.FRAUD_ALERTS                WHERE BATCH_ID LIKE 'EDGE%';
DELETE FROM CONFIG.EXPECTED_TEST_OUTCOME;

-- reference data ---------------------------------------------------------
INSERT INTO RAW.MERCHANTS (MERCHANT_ID, MERCHANT_NAME, MCC_CODE, MERCHANT_CATEGORY, REGION, CITY, ONBOARDED_DATE,
                           SETTLEMENT_CYCLE_DAYS, FEE_PCT, MERCHANT_STATUS, UPDATED_AT, BATCH_ID)
VALUES ('M_EDGE','Edge Case Test Merchant','5999','RETAIL','SOUTH','Vijayawada','2025-01-01',1,0.0200,'ACTIVE','2026-01-01',$EDGE_BATCH);

INSERT INTO RAW.CUSTOMERS (CUSTOMER_ID, FULL_NAME, EMAIL, PHONE, DATE_OF_BIRTH, PAN_NUMBER, CITY, STATE, COUNTRY_CODE,
                           CUSTOMER_SEGMENT, CREATED_AT, UPDATED_AT, BATCH_ID)
VALUES ('C_EDGE','Edge Test Customer','edge@example.invalid','+91-9000000000','1990-01-01','ZZEPX0000Z',
        'Vijayawada','AP','IN','MASS','2026-01-01 00:00:00','2026-01-01 00:00:00',$EDGE_BATCH);

-- E09: KYC changes -> 3 SCD2 versions, current risk HIGH
INSERT INTO RAW.CUSTOMER_KYC_HISTORY (KYC_EVENT_ID, CUSTOMER_ID, KYC_LEVEL, KYC_STATUS, RISK_RATING, PEP_FLAG,
                                      DOCUMENT_TYPE, EFFECTIVE_FROM, VERIFIED_BY, BATCH_ID)
VALUES ('KYC-C_EDGE-1','C_EDGE','MIN','VERIFIED','LOW',FALSE,'MOBILE_OTP','2026-01-01 00:00:00','SYSTEM',$EDGE_BATCH),
       ('KYC-C_EDGE-2','C_EDGE','FULL','VERIFIED','LOW',FALSE,'AADHAAR_OFFLINE','2026-02-01 00:00:00','KYC_OPS',$EDGE_BATCH),
       ('KYC-C_EDGE-3','C_EDGE','ENHANCED','VERIFIED','HIGH',FALSE,'PASSPORT','2026-03-15 00:00:00','RISK_OPS',$EDGE_BATCH);

-- payments ---------------------------------------------------------------
-- Helper CTE builds provider payloads exactly like the generator does.
INSERT INTO RAW.PAYMENTS (SOURCE_SYSTEM, SOURCE_RECORD, RECORD_HASH, SOURCE_FILE_NAME, BATCH_ID, INGESTED_AT)
WITH e AS (
  SELECT * FROM VALUES
   -- case , src     , txn id         , order id        , amount   , ccy  , canonical delivered , ts (UTC)
   ('E01','PROV_A','EDGE-A-0001','EDGE-ORD-0001', 1000.00,'INR','CAPTURED','2026-04-10 04:30:00'),
   ('E02','PROV_B','EDGE-B-0002a','EDGE-ORD-0002', 2500.00,'INR','FAILED',  '2026-04-10 05:00:00'),
   ('E02','PROV_B','EDGE-B-0002b','EDGE-ORD-0002', 2500.00,'INR','FAILED',  '2026-04-10 05:01:30'),
   ('E02','PROV_B','EDGE-B-0002c','EDGE-ORD-0002', 2500.00,'INR','CAPTURED','2026-04-10 05:03:00'),
   ('E03','PROV_C','EDGE-C-0003','EDGE-ORD-0003', 50000.00,'INR','PENDING', '2026-04-10 06:00:00'),
   ('E04','PROV_B','EDGE-B-0004','EDGE-ORD-0004', 10000.00,'INR','CAPTURED','2026-04-10 07:00:00'),
   ('E06','PROV_A','EDGE-A-0006','EDGE-ORD-0006', 1200.00,'INR','CAPTURED','2026-04-05 08:00:00'),
   ('E07','PROV_B','EDGE-B-0007','EDGE-ORD-0007', 4000.00,'INR','CAPTURED','2026-04-10 09:00:00'),
   ('E08','PROV_B','EDGE-B-0008','EDGE-ORD-0008', 8000.00,'INR','CAPTURED','2026-04-10 10:00:00'),
   ('E10','PROV_A','EDGE-A-0010','EDGE-ORD-0010',  -50.00,'INR','CAPTURED','2026-04-10 11:00:00'),
   ('E10','PROV_B','EDGE-B-0011','EDGE-ORD-0011',  300.00,'XXX','CAPTURED','2026-04-10 11:05:00'),
   ('E10','PROV_C','EDGE-C-0012','EDGE-ORD-0012',  700.00,'INR','ZZ',      '2026-04-10 11:10:00'),
   ('E11','PROV_A','EDGE-A-0013','EDGE-ORD-0013', 1500.00,'INR','CAPTURED','2026-04-10 12:00:00'),
   ('E12','PROV_B','EDGE-B-0014','EDGE-ORD-0014', 6000.00,'INR','CAPTURED','2026-04-10 13:00:00'),
   ('E12','PROV_B','EDGE-B-0015','EDGE-ORD-0015', 6000.00,'INR','CAPTURED','2026-04-10 13:30:00'),
   -- E14: same provider id as E01 but from PROV_C -> must NOT collide
   ('E14','PROV_C','EDGE-A-0001','EDGE-ORD-0016',  800.00,'INR','CAPTURED','2026-04-10 14:00:00')
   AS v(case_id, src, txn, ord, amt, ccy, canon, ts)
), p AS (
  SELECT e.*, IFF(canon = 'ZZ', 'ZZ', OPS.PROVIDER_RAW_STATUS(src, canon)) AS raw_status,
         OPS.FORMAT_PROVIDER_TS(src, ts::TIMESTAMP_NTZ) AS ts_raw
  FROM e
), rec AS (
  SELECT src, ts,
    CASE src
      WHEN 'PROV_A' THEN OBJECT_CONSTRUCT('txn_ref',txn,'order_id',ord,'merchant_code','M_EDGE','cust_id','C_EDGE',
                          'amt',TO_VARCHAR(amt::NUMBER(18,2)),'ccy',ccy,'txn_status',raw_status,'txn_time',ts_raw,
                          'channel','UPI','vpa_token','tok_edge_upi','device_id','dev_edge')
      WHEN 'PROV_B' THEN OBJECT_CONSTRUCT('payment_id',txn,'merchant_reference',ord,'merchant_id','M_EDGE','customer_id','C_EDGE',
                          'payment_amount',TO_VARCHAR(ROUND(amt*100)::NUMBER(38,0)),'currency',ccy,'state',raw_status,
                          'created_at_ms',ts_raw,'method','credit_card','card_token','tok_edge_card','card_last4','4242','card_network','VISA')
      ELSE OBJECT_CONSTRUCT('reference_no',txn,'customer_ref',ord,'merchant_ref','M_EDGE','payer_id','C_EDGE',
                          'amount_value',TO_VARCHAR(amt::NUMBER(18,2)),'currency_code',ccy,'status_code',raw_status,
                          'value_ts',ts_raw,'rail','IMPS','account_token','tok_edge_acct')
    END AS r
  FROM p
)
SELECT src, r, SHA2(src || TO_JSON(r)), 'edge_cases.json', $EDGE_BATCH, DATEADD(minute, 5, ts::TIMESTAMP_NTZ) FROM rec
UNION ALL   -- E01: identical re-delivery of EDGE-A-0001 (PROV_A) in a later batch
SELECT src, r, SHA2(src || TO_JSON(r)), 'edge_cases_redelivery.json', $EDGE_BATCH || '-REDELIVERY',
       DATEADD(hour, 6, ts::TIMESTAMP_NTZ)
FROM rec WHERE src = 'PROV_A' AND r:txn_ref::VARCHAR = 'EDGE-A-0001';

-- status history ------------------------------------------------------
INSERT INTO RAW.PAYMENT_STATUS_HISTORY (EVENT_ID, SOURCE_SYSTEM, SOURCE_TRANSACTION_ID, RAW_STATUS, EVENT_TS_RAW,
                                        REASON_CODE, SOURCE_FILE_NAME, BATCH_ID, INGESTED_AT)
SELECT event_id, src, txn, OPS.PROVIDER_RAW_STATUS(src, canon), OPS.FORMAT_PROVIDER_TS(src, ts::TIMESTAMP_NTZ),
       reason, 'edge_status.json', batch, ingested::TIMESTAMP_NTZ
FROM VALUES
  -- E03 late-arriving: '00' captured event delivered a day late; then an
  -- OLDER '09' pending event delivered even later. Final must be CAPTURED.
  ('EDGE-E03-1','PROV_C','EDGE-C-0003','CREATED', '2026-04-10 06:00:00',NULL,'EDGE-CASES-V1',     '2026-04-10 06:05:00'),
  ('EDGE-E03-3','PROV_C','EDGE-C-0003','CAPTURED','2026-04-10 06:00:40',NULL,'EDGE-CASES-V1-LATE','2026-04-11 07:00:00'),
  ('EDGE-E03-2','PROV_C','EDGE-C-0003','PENDING', '2026-04-10 06:00:20',NULL,'EDGE-CASES-V1-LATE2','2026-04-12 07:00:00'),
  -- E11 reversal
  ('EDGE-E11-1','PROV_A','EDGE-A-0013','CAPTURED','2026-04-10 12:00:10',NULL,'EDGE-CASES-V1','2026-04-10 12:05:00'),
  ('EDGE-E11-2','PROV_A','EDGE-A-0013','REVERSED','2026-04-11 12:00:00','BANK_REVERSAL','EDGE-CASES-V1','2026-04-11 12:05:00'),
  -- E02 retries
  ('EDGE-E02-a','PROV_B','EDGE-B-0002a','FAILED','2026-04-10 05:00:05','ISSUER_DECLINE','EDGE-CASES-V1','2026-04-10 05:05:00'),
  ('EDGE-E02-b','PROV_B','EDGE-B-0002b','FAILED','2026-04-10 05:01:35','ISSUER_DECLINE','EDGE-CASES-V1','2026-04-10 05:05:00'),
  ('EDGE-E02-c','PROV_B','EDGE-B-0002c','CAPTURED','2026-04-10 05:03:05',NULL,'EDGE-CASES-V1','2026-04-10 05:05:00')
  AS v(event_id, src, txn, canon, ts, reason, batch, ingested);

-- refunds: E04 two partial refunds ------------------------------------
INSERT INTO RAW.REFUNDS (REFUND_ID, SOURCE_SYSTEM, SOURCE_TRANSACTION_ID, REFUND_AMOUNT, CURRENCY_CODE, REFUND_TYPE,
                         REFUND_REASON, REQUESTED_AT, SOURCE_FILE_NAME, BATCH_ID)
VALUES ('RF-EDGE-0004-1','PROV_B','EDGE-B-0004',3000.00,'INR','PARTIAL','CUSTOMER_REQUEST','2026-04-12 10:00:00','edge.csv',$EDGE_BATCH),
       ('RF-EDGE-0004-2','PROV_B','EDGE-B-0004',2000.00,'INR','PARTIAL','ITEM_NOT_RECEIVED','2026-04-14 10:00:00','edge.csv',$EDGE_BATCH);
INSERT INTO RAW.REFUND_STATUS_HISTORY (REFUND_EVENT_ID, REFUND_ID, REFUND_STATUS, EVENT_TS, SOURCE_FILE_NAME, BATCH_ID)
VALUES ('RFE-EDGE-0004-1-1','RF-EDGE-0004-1','INITIATED','2026-04-12 10:00:00','edge.csv',$EDGE_BATCH),
       ('RFE-EDGE-0004-1-2','RF-EDGE-0004-1','PROCESSED','2026-04-13 16:00:00','edge.csv',$EDGE_BATCH),
       ('RFE-EDGE-0004-2-1','RF-EDGE-0004-2','INITIATED','2026-04-14 10:00:00','edge.csv',$EDGE_BATCH),
       ('RFE-EDGE-0004-2-2','RF-EDGE-0004-2','PROCESSED','2026-04-15 16:00:00','edge.csv',$EDGE_BATCH);

-- chargeback: E08 lost -------------------------------------------------
INSERT INTO RAW.CHARGEBACKS (CHARGEBACK_ID, SOURCE_SYSTEM, SOURCE_TRANSACTION_ID, CHARGEBACK_AMOUNT, CURRENCY_CODE,
                             REASON_CODE, CHARGEBACK_STATUS, RECEIVED_DATE, RESOLVED_DATE, SOURCE_FILE_NAME, BATCH_ID)
VALUES ('CB-EDGE-0008','PROV_B','EDGE-B-0008',8000.00,'INR','4837','LOST','2026-04-25','2026-05-20','edge.csv',$EDGE_BATCH);

-- settlements (batch SB-PE-20260411 primary, SB-PE-20260412 second) -----
INSERT INTO RAW.BANK_SETTLEMENTS (SETTLEMENT_LINE_ID, SETTLEMENT_BATCH_ID, SOURCE_SYSTEM, SOURCE_TRANSACTION_ID,
      MERCHANT_ID, SETTLEMENT_TYPE, IS_FINAL_SETTLEMENT, GROSS_AMOUNT, FEE_AMOUNT, TAX_AMOUNT, NET_AMOUNT,
      CURRENCY_CODE, SETTLEMENT_DATE, SOURCE_FILE_NAME, BATCH_ID)
SELECT line_id, batch, src, txn, 'M_EDGE', typ, is_final, gross,
       IFF(typ = 'SALE', ROUND(gross * 0.02, 2), 0),
       IFF(typ = 'SALE', ROUND(ROUND(gross * 0.02, 2) * 0.18, 2), 0),
       gross - IFF(typ = 'SALE', ROUND(gross * 0.02, 2) + ROUND(ROUND(gross * 0.02, 2) * 0.18, 2), 0),
       'INR', sdate::DATE, 'edge_settlement.csv', $EDGE_BATCH
FROM VALUES
  ('SL-EDGE-E01','SB-PE-20260411','PROV_A','EDGE-A-0001','SALE',TRUE,  1000.00,'2026-04-11'),  -- matched despite duplicate delivery
  ('SL-EDGE-E02','SB-PE-20260411','PROV_B','EDGE-B-0002c','SALE',TRUE, 2500.00,'2026-04-11'),  -- matched on the successful retry
  ('SL-EDGE-E03','SB-PE-20260411','PROV_C','EDGE-C-0003','SALE',TRUE, 50000.00,'2026-04-11'),  -- matched after late update
  ('SL-EDGE-E04','SB-PE-20260411','PROV_B','EDGE-B-0004','SALE',TRUE, 10000.00,'2026-04-11'),
  ('SL-EDGE-E04R1','SB-PE-20260411','PROV_B','EDGE-B-0004','REFUND',TRUE,-3000.00,'2026-04-11'),
  ('SL-EDGE-E04R2','SB-PE-20260411','PROV_B','EDGE-B-0004','REFUND',TRUE,-2000.00,'2026-04-11'),
  ('SL-EDGE-E05','SB-PE-20260411','PROV_B','EDGE-B-9999','SALE',TRUE,   750.00,'2026-04-11'),  -- orphan settlement
  ('SL-EDGE-E07','SB-PE-20260411','PROV_B','EDGE-B-0007','SALE',TRUE,  3900.00,'2026-04-11'),  -- short by 100
  ('SL-EDGE-E08','SB-PE-20260411','PROV_B','EDGE-B-0008','SALE',TRUE,  8000.00,'2026-04-11'),
  ('SL-EDGE-E08CB','SB-PE-20260411','PROV_B','EDGE-B-0008','CHARGEBACK',TRUE,-8000.00,'2026-04-11'),
  ('SL-EDGE-E12a','SB-PE-20260411','PROV_B','EDGE-B-0014','SALE',FALSE, 4000.00,'2026-04-11'),
  ('SL-EDGE-E12b','SB-PE-20260412','PROV_B','EDGE-B-0014','SALE',TRUE,  2000.00,'2026-04-12'),  -- 2nd event, other batch
  ('SL-EDGE-E12c','SB-PE-20260411','PROV_B','EDGE-B-0015','SALE',FALSE, 4000.00,'2026-04-11'),  -- partial, remainder never arrives
  ('SL-EDGE-E14','SB-PE-20260411','PROV_C','EDGE-A-0001','SALE',TRUE,   800.00,'2026-04-11')
  AS v(line_id, batch, src, txn, typ, is_final, gross, sdate);

-- bank statement: SB-PE-20260411 credited exactly; SB-PE-20260412 never credited;
-- an unknown batch reference SB-PE-20260413 appears on the statement.
INSERT INTO RAW.BANK_STATEMENT_TRANSACTIONS (BANK_TXN_ID, BANK_CODE, BANK_ACCOUNT_TOKEN, VALUE_DATE, POSTING_TS, DR_CR,
      AMOUNT, CURRENCY_CODE, NARRATIVE, SOURCE_FILE_NAME, BATCH_ID)
SELECT 'BST-EDGE-1', 'HDFC', 'acct_edge', '2026-04-11', '2026-04-11 10:00:00', 'CR', SUM(NET_AMOUNT), 'INR',
       'NEFT CR-HDFC0000123-PROVIDER PAYMENTS-SETTL SB-PE-20260411', 'edge_bank.csv', $EDGE_BATCH
FROM RAW.BANK_SETTLEMENTS WHERE SETTLEMENT_BATCH_ID = 'SB-PE-20260411'
UNION ALL
SELECT 'BST-EDGE-2', 'HDFC', 'acct_edge', '2026-04-13', '2026-04-13 10:00:00', 'CR', 999.00, 'INR',
       'NEFT CR-HDFC0000123-PROVIDER PAYMENTS-SETTL SB-PE-20260413', 'edge_bank.csv', $EDGE_BATCH;

-- expected outcomes -----------------------------------------------------
-- Entity keys use source_system|source_transaction_id for attempts,
-- merchant_id|merchant_order_id for transactions, batch id for batches.
INSERT INTO CONFIG.EXPECTED_TEST_OUTCOME (TEST_CASE_ID, DESCRIPTION, CHECK_TYPE, ENTITY_KEY, EXPECTED_VALUE)
VALUES
 ('E01','Duplicate delivery counted once','DEDUP_COUNT','PROV_A|EDGE-A-0001','1'),
 ('E01','Duplicate delivery still reconciles','PAYMENT_RECON_STATUS','PROV_A|EDGE-A-0001','MATCHED'),
 ('E02','Three attempts roll up to one transaction','ATTEMPT_COUNT','M_EDGE|EDGE-ORD-0002','3'),
 ('E02','Retry succeeds: transaction CAPTURED','FINAL_STATUS','M_EDGE|EDGE-ORD-0002','CAPTURED'),
 ('E02','Only the capturing attempt is settled','PAYMENT_RECON_STATUS','PROV_B|EDGE-B-0002c','MATCHED'),
 ('E03','Late out-of-order events resolve by event time','FINAL_STATUS','M_EDGE|EDGE-ORD-0003','CAPTURED'),
 ('E03','Late-captured payment reconciles','PAYMENT_RECON_STATUS','PROV_C|EDGE-C-0003','MATCHED'),
 ('E04','Two partial refunds sum to 5000','REFUND_TOTAL','PROV_B|EDGE-B-0004','5000.00'),
 ('E04','Refunds do not break sale reconciliation','PAYMENT_RECON_STATUS','PROV_B|EDGE-B-0004','MATCHED'),
 ('E05','Settlement without payment','EXCEPTION_TYPE','SL-EDGE-E05','UNMATCHED_SETTLEMENT'),
 ('E06','Captured long ago, never settled','PAYMENT_RECON_STATUS','PROV_A|EDGE-A-0006','UNSETTLED'),
 ('E07','Short settled by 100','PAYMENT_RECON_STATUS','PROV_B|EDGE-B-0007','AMOUNT_MISMATCH'),
 ('E08','Chargeback does not change sale match','PAYMENT_RECON_STATUS','PROV_B|EDGE-B-0008','MATCHED'),
 ('E08','Lost chargeback amount','CHARGEBACK_AMOUNT','PROV_B|EDGE-B-0008','8000.00'),
 ('E09','Three KYC versions','KYC_VERSIONS','C_EDGE','3'),
 ('E09','Current risk rating','CURRENT_RISK','C_EDGE','HIGH'),
 ('E10','Negative amount routed to exceptions','EXCEPTION_TYPE','PROV_A|EDGE-A-0010','INVALID_AMOUNT'),
 ('E10','Unknown currency routed to exceptions','EXCEPTION_TYPE','PROV_B|EDGE-B-0011','INVALID_CURRENCY'),
 ('E10','Unknown status routed to exceptions','EXCEPTION_TYPE','PROV_C|EDGE-C-0012','UNKNOWN_STATUS'),
 ('E11','Reversal is final status','FINAL_STATUS','M_EDGE|EDGE-ORD-0013','REVERSED'),
 ('E11','Reversed payment not settleable','PAYMENT_RECON_STATUS','PROV_A|EDGE-A-0013','NOT_APPLICABLE'),
 ('E12','Two settlement events add up','PAYMENT_RECON_STATUS','PROV_B|EDGE-B-0014','MATCHED'),
 ('E12','Partial settlement outstanding','PAYMENT_RECON_STATUS','PROV_B|EDGE-B-0015','PARTIALLY_SETTLED'),
 ('E13','Batch credited exactly','BATCH_RECON_STATUS','SB-PE-20260411','MATCHED'),
 ('E13','Batch never credited','BATCH_RECON_STATUS','SB-PE-20260412','MISSING_BANK_CREDIT'),
 ('E13','Bank credit with unknown batch','BATCH_RECON_STATUS','SB-PE-20260413','UNMATCHED_BANK_CREDIT'),
 ('E14','Same provider id in another provider is distinct','PAYMENT_RECON_STATUS','PROV_C|EDGE-A-0001','MATCHED');
