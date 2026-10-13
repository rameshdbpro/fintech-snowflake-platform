/* =====================================================================
   04_SYNTHETIC_DATA_GENERATOR.SQL
   100% Snowflake SQL (Snowflake Scripting). No Python, no external app.

   Reproducibility: every random choice uses OPS.DRAND(key), a pure
   function of a string key (seed || entity || ordinal) built on HASH().
   Same seed + same parameters => byte-identical data on every run.
   (RANDOM()/UNIFORM() are NOT used: their output depends on parallelism.)

   Call:
     CALL OPS.SP_GENERATE_SYNTHETIC_DATA(
          p_num_customers => 5000, p_num_merchants => 200, p_num_payments => 50000,
          p_start_date => '2026-04-01', p_end_date => '2026-09-30',
          p_seed => 'FINTECH-2026', p_reset => TRUE);
   Upper bound: 2,000,000 payments per call (size of OPS.GEN_NUMBERS).
   ===================================================================== */
USE ROLE FINTECH_DEPLOYER;
USE DATABASE FINTECH_DEV;
USE WAREHOUSE WH_FINTECH_LOAD;
USE SCHEMA OPS;

-- Deterministic pseudo-random number in [0,1) derived from a key ---------
CREATE OR REPLACE FUNCTION OPS.DRAND(K VARCHAR)
RETURNS FLOAT
IMMUTABLE
COMMENT = 'Deterministic uniform [0,1) from a string key (HASH based). Same key => same value.'
AS $$ BITAND(HASH(K), 2147483647) / 2147483648.0 $$;

-- Deterministic pick from an array ----------------------------------------
CREATE OR REPLACE FUNCTION OPS.DPICK(ARR ARRAY, K VARCHAR)
RETURNS VARCHAR
IMMUTABLE
AS $$ GET(ARR, FLOOR(OPS.DRAND(K) * ARRAY_SIZE(ARR)))::VARCHAR $$;

-- Provider-specific status vocabulary (inverse of CONFIG.STATUS_MAPPING) -
CREATE OR REPLACE FUNCTION OPS.PROVIDER_RAW_STATUS(SRC VARCHAR, CANON VARCHAR)
RETURNS VARCHAR
IMMUTABLE
AS $$
  CASE SRC
    WHEN 'PROV_A' THEN DECODE(CANON,'CREATED','INITIATED','PENDING','PENDING','CAPTURED','SUCCESS',
                                    'FAILED','FAILED','REVERSED','REVERSED')
    WHEN 'PROV_B' THEN DECODE(CANON,'CREATED','created','AUTHORIZED','authorized','PENDING','authorized',
                                    'CAPTURED','captured','FAILED','declined','VOIDED','voided')
    WHEN 'PROV_C' THEN DECODE(CANON,'CREATED','09','PENDING','09','CAPTURED','00','FAILED','05','REVERSED','R1')
  END
$$;

-- Provider-specific timestamp conventions (input is UTC) ---------------
--   PROV_A: IST wall-clock string  'YYYY-MM-DD HH24:MI:SS'
--   PROV_B: epoch milliseconds (UTC)
--   PROV_C: ISO-8601 with +05:30 offset
CREATE OR REPLACE FUNCTION OPS.FORMAT_PROVIDER_TS(SRC VARCHAR, TS TIMESTAMP_NTZ)
RETURNS VARCHAR
IMMUTABLE
AS $$
  CASE SRC
    WHEN 'PROV_A' THEN TO_VARCHAR(CONVERT_TIMEZONE('UTC','Asia/Kolkata',TS),'YYYY-MM-DD HH24:MI:SS')
    WHEN 'PROV_B' THEN TO_VARCHAR(DATE_PART(EPOCH_MILLISECOND, TS))
    WHEN 'PROV_C' THEN TO_VARCHAR(CONVERT_TIMEZONE('UTC','Asia/Kolkata',TS),'YYYY-MM-DD"T"HH24:MI:SS') || '+05:30'
  END
$$;

-- Number spine (created once) ------------------------------------------
CREATE TRANSIENT TABLE IF NOT EXISTS OPS.GEN_NUMBERS AS
SELECT ROW_NUMBER() OVER (ORDER BY SEQ4()) AS N
FROM TABLE(GENERATOR(ROWCOUNT => 2000000));

CREATE OR REPLACE PROCEDURE OPS.SP_GENERATE_SYNTHETIC_DATA(
    P_NUM_CUSTOMERS NUMBER  DEFAULT 5000,
    P_NUM_MERCHANTS NUMBER  DEFAULT 200,
    P_NUM_PAYMENTS  NUMBER  DEFAULT 50000,
    P_START_DATE    DATE    DEFAULT '2026-04-01',
    P_END_DATE      DATE    DEFAULT '2026-09-30',
    P_SEED          VARCHAR DEFAULT 'FINTECH-2026',
    P_RESET         BOOLEAN DEFAULT TRUE
)
RETURNS VARIANT
LANGUAGE SQL
COMMENT = 'Deterministic synthetic data for all 12 RAW datasets. SQL only.'
EXECUTE AS OWNER
AS
$$
DECLARE
    v_batch   VARCHAR DEFAULT 'SYN-' || P_SEED || '-' || TO_VARCHAR(SYSDATE(),'YYYYMMDDHH24MISS');
    v_secs    NUMBER;
    v_started TIMESTAMP_NTZ DEFAULT SYSDATE();
    v_result  VARIANT;
BEGIN
    IF (P_NUM_PAYMENTS > 2000000) THEN
        RETURN OBJECT_CONSTRUCT('status','FAILED','message','p_num_payments exceeds 2,000,000');
    END IF;
    IF (P_END_DATE < P_START_DATE) THEN
        RETURN OBJECT_CONSTRUCT('status','FAILED','message','p_end_date before p_start_date');
    END IF;
    v_secs := DATEDIFF(second, P_START_DATE::TIMESTAMP_NTZ, DATEADD(day, 1, P_END_DATE)::TIMESTAMP_NTZ);

    INSERT INTO AUDIT.PROCEDURE_LOG (PROCEDURE_NAME, RUN_ID, STEP, STATUS, MESSAGE)
    VALUES ('SP_GENERATE_SYNTHETIC_DATA', :v_batch, 'START', 'STARTED',
            'payments=' || :P_NUM_PAYMENTS || ' seed=' || :P_SEED);

    -- Parameters are materialised in a one-row table so that the
    -- CREATE TABLE ... AS SELECT steps below need no bind variables.
    CREATE OR REPLACE TRANSIENT TABLE OPS.GEN_PARAMS (
        SEED VARCHAR, NUM_CUSTOMERS NUMBER, NUM_MERCHANTS NUMBER, NUM_PAYMENTS NUMBER,
        START_DATE DATE, END_DATE DATE, SECS NUMBER, BATCH_ID VARCHAR);
    INSERT INTO OPS.GEN_PARAMS VALUES (:P_SEED, :P_NUM_CUSTOMERS, :P_NUM_MERCHANTS, :P_NUM_PAYMENTS,
                                       :P_START_DATE, :P_END_DATE, :v_secs, :v_batch);

    IF (P_RESET) THEN
        TRUNCATE TABLE RAW.PAYMENTS;              TRUNCATE TABLE RAW.PAYMENT_STATUS_HISTORY;
        TRUNCATE TABLE RAW.CUSTOMERS;             TRUNCATE TABLE RAW.CUSTOMER_KYC_HISTORY;
        TRUNCATE TABLE RAW.MERCHANTS;             TRUNCATE TABLE RAW.REFUNDS;
        TRUNCATE TABLE RAW.REFUND_STATUS_HISTORY; TRUNCATE TABLE RAW.BANK_SETTLEMENTS;
        TRUNCATE TABLE RAW.BANK_STATEMENT_TRANSACTIONS; TRUNCATE TABLE RAW.PAYMENT_CHANNELS;
        TRUNCATE TABLE RAW.FRAUD_ALERTS;          TRUNCATE TABLE RAW.CHARGEBACKS;
    END IF;

    ---------------------------------------------------------------- channels
    INSERT INTO RAW.PAYMENT_CHANNELS (CHANNEL_CODE, SOURCE_SYSTEM, PROVIDER_CHANNEL_VALUE, CHANNEL_NAME,
                                      CHANNEL_GROUP, INSTRUMENT_TYPE, IS_ACTIVE, BATCH_ID)
    SELECT c1, c2, c3, c4, c5, c6, TRUE, :v_batch FROM VALUES
      ('UPI','PROV_A','UPI','UPI Collect / Intent','UPI','UPI_VPA'),
      ('WALLET','PROV_A','WALLET','Digital Wallet','WALLET','WALLET'),
      ('DEBIT_CARD','PROV_B','debit_card','Debit Card','CARD','DEBIT_CARD'),
      ('CREDIT_CARD','PROV_B','credit_card','Credit Card','CARD','CREDIT_CARD'),
      ('NEFT','PROV_C','NEFT','NEFT Bank Transfer','BANK_TRANSFER','BANK_ACCOUNT'),
      ('IMPS','PROV_C','IMPS','IMPS Bank Transfer','BANK_TRANSFER','BANK_ACCOUNT'),
      ('RTGS','PROV_C','RTGS','RTGS Bank Transfer','BANK_TRANSFER','BANK_ACCOUNT')
      AS v(c1,c2,c3,c4,c5,c6);

    ---------------------------------------------------------------- merchants
    INSERT INTO RAW.MERCHANTS (MERCHANT_ID, MERCHANT_NAME, MCC_CODE, MERCHANT_CATEGORY, REGION, CITY,
                               ONBOARDED_DATE, SETTLEMENT_CYCLE_DAYS, FEE_PCT, MERCHANT_STATUS, UPDATED_AT, BATCH_ID)
    WITH m AS (
        SELECT N,
               'M' || LPAD(N, 5, '0') AS merchant_id,
               OPS.DPICK(ARRAY_CONSTRUCT('5411|GROCERY|0.0150','5812|RESTAURANT|0.0180','5732|ELECTRONICS|0.0200',
                                         '4111|TRANSPORT|0.0120','5999|RETAIL|0.0190','4900|UTILITIES|0.0080',
                                         '7011|TRAVEL|0.0220','5691|FASHION|0.0200'), :P_SEED||'mcat'||N) AS cat
        FROM OPS.GEN_NUMBERS WHERE N <= :P_NUM_MERCHANTS
    )
    SELECT merchant_id,
           OPS.DPICK(ARRAY_CONSTRUCT('Sapphire','Lotus','Indus','Monsoon','Saffron','Banyan','Peacock','Ganga',
                                     'Nilgiri','Deccan','Coral','Tusker'), :P_SEED||'mn1'||N) || ' ' ||
           INITCAP(SPLIT_PART(cat,'|',2)) || ' ' || N,
           SPLIT_PART(cat,'|',1), SPLIT_PART(cat,'|',2),
           OPS.DPICK(ARRAY_CONSTRUCT('NORTH','SOUTH','EAST','WEST'), :P_SEED||'mreg'||N),
           OPS.DPICK(ARRAY_CONSTRUCT('Delhi','Chennai','Kolkata','Mumbai','Bengaluru','Hyderabad','Pune','Vijayawada'), :P_SEED||'mcity'||N),
           DATEADD(day, -FLOOR(OPS.DRAND(:P_SEED||'monb'||N)*900)::INT, :P_START_DATE),
           IFF(OPS.DRAND(:P_SEED||'mcyc'||N) < 0.7, 1, 2),
           SPLIT_PART(cat,'|',3)::NUMBER(6,4),
           'ACTIVE',
           :P_START_DATE::TIMESTAMP_NTZ,
           :v_batch
    FROM m;

    ---------------------------------------------------------------- customers (synthetic PII)
    INSERT INTO RAW.CUSTOMERS (CUSTOMER_ID, FULL_NAME, EMAIL, PHONE, DATE_OF_BIRTH, PAN_NUMBER, CITY, STATE,
                               COUNTRY_CODE, CUSTOMER_SEGMENT, CREATED_AT, UPDATED_AT, BATCH_ID)
    SELECT 'C' || LPAD(N, 7, '0'),
           OPS.DPICK(ARRAY_CONSTRUCT('Aarav','Diya','Vihaan','Ananya','Arjun','Saanvi','Kabir','Isha','Rohan','Meera','Ravi','Lakshmi'), :P_SEED||'fn'||N)
             || ' ' ||
           OPS.DPICK(ARRAY_CONSTRUCT('Sharma','Reddy','Iyer','Patel','Das','Nair','Gupta','Rao','Singh','Menon'), :P_SEED||'ln'||N),
           'user' || N || '@example.invalid',
           '+91-9' || LPAD(FLOOR(OPS.DRAND(:P_SEED||'ph'||N)*999999999)::INT, 9, '0'),
           DATEADD(day, -FLOOR(7300 + OPS.DRAND(:P_SEED||'dob'||N)*14600)::INT, :P_START_DATE),
           'ZZ' || CHR(65 + FLOOR(OPS.DRAND(:P_SEED||'pan1'||N)*26)::INT) || 'PX' || LPAD(MOD(N*7919, 10000), 4, '0') || 'Z',
           OPS.DPICK(ARRAY_CONSTRUCT('Delhi','Chennai','Kolkata','Mumbai','Bengaluru','Hyderabad','Vijayawada','Jaipur'), :P_SEED||'cc'||N),
           OPS.DPICK(ARRAY_CONSTRUCT('DL','TN','WB','MH','KA','TS','AP','RJ'), :P_SEED||'cc'||N),
           'IN',
           OPS.DPICK(ARRAY_CONSTRUCT('MASS','MASS','MASS','AFFLUENT','SME'), :P_SEED||'seg'||N),
           DATEADD(second, -FLOOR(OPS.DRAND(:P_SEED||'cad'||N)*31536000)::INT, :P_START_DATE::TIMESTAMP_NTZ),
           :P_START_DATE::TIMESTAMP_NTZ,
           :v_batch
    FROM OPS.GEN_NUMBERS WHERE N <= :P_NUM_CUSTOMERS;

    ---------------------------------------------------------------- KYC history (SCD2 source)
    INSERT INTO RAW.CUSTOMER_KYC_HISTORY (KYC_EVENT_ID, CUSTOMER_ID, KYC_LEVEL, KYC_STATUS, RISK_RATING, PEP_FLAG,
                                          DOCUMENT_TYPE, EFFECTIVE_FROM, VERIFIED_BY, BATCH_ID)
    WITH c AS (
        SELECT CUSTOMER_ID, CREATED_AT, OPS.DRAND(:P_SEED||'kyc'||CUSTOMER_ID) AS r
        FROM RAW.CUSTOMERS WHERE BATCH_ID = :v_batch
    )
    SELECT 'KYC-'||CUSTOMER_ID||'-1', CUSTOMER_ID, IFF(r<0.35,'MIN','FULL'), 'VERIFIED',
           IFF(r<0.9,'LOW','MEDIUM'), FALSE, IFF(r<0.35,'MOBILE_OTP','AADHAAR_OFFLINE'), CREATED_AT, 'SYSTEM', :v_batch
    FROM c
    UNION ALL   -- 20%: upgrade from MIN to FULL during the window
    SELECT 'KYC-'||CUSTOMER_ID||'-2', CUSTOMER_ID, 'FULL', 'VERIFIED', 'LOW', FALSE, 'AADHAAR_OFFLINE',
           DATEADD(second, FLOOR(OPS.DRAND(:P_SEED||'kyc2'||CUSTOMER_ID) * :v_secs)::INT, :P_START_DATE::TIMESTAMP_NTZ),
           'KYC_OPS', :v_batch
    FROM c WHERE r < 0.20
    UNION ALL   -- 5%: risk escalation to HIGH (some PEP)
    SELECT 'KYC-'||CUSTOMER_ID||'-3', CUSTOMER_ID, 'ENHANCED', 'VERIFIED', 'HIGH', (r > 0.985), 'PASSPORT',
           DATEADD(second, FLOOR(OPS.DRAND(:P_SEED||'kyc3'||CUSTOMER_ID) * :v_secs)::INT, :P_START_DATE::TIMESTAMP_NTZ),
           'RISK_OPS', :v_batch
    FROM c WHERE r >= 0.95;

    ---------------------------------------------------------------- payment intents
    CREATE OR REPLACE TRANSIENT TABLE OPS.GEN_TXN AS
    WITH base AS (
        SELECT N AS i,
               OPS.DRAND(gp.SEED||'prov'||N) AS r_prov,
               OPS.DRAND(gp.SEED||'chan'||N) AS r_chan,
               OPS.DRAND(gp.SEED||'amt'||N)  AS r_amt,
               OPS.DRAND(gp.SEED||'out'||N)  AS r_out,
               OPS.DRAND(gp.SEED||'att'||N)  AS r_att,
               OPS.DRAND(gp.SEED||'ccy'||N)  AS r_ccy,
               OPS.DRAND(gp.SEED||'burst'||N) AS r_burst
        FROM OPS.GEN_NUMBERS, OPS.GEN_PARAMS gp WHERE N <= gp.NUM_PAYMENTS
    ), p AS (
        SELECT b.*,
               CASE WHEN r_prov < 0.45 THEN 'PROV_A' WHEN r_prov < 0.85 THEN 'PROV_B' ELSE 'PROV_C' END AS source_system
        FROM base b
    ), c AS (
        SELECT p.*,
               CASE source_system
                 WHEN 'PROV_A' THEN IFF(r_chan < 0.75, 'UPI', 'WALLET')
                 WHEN 'PROV_B' THEN IFF(r_chan < 0.55, 'debit_card', 'credit_card')
                 ELSE IFF(r_chan < 0.5, 'IMPS', IFF(r_chan < 0.92, 'NEFT', 'RTGS'))
               END AS channel_value
        FROM p
    )
    SELECT i, source_system,
           ROW_NUMBER() OVER (PARTITION BY source_system ORDER BY i) AS prov_seq,
           channel_value,
           'M' || LPAD(1 + FLOOR(OPS.DRAND(gp.SEED||'mer'||i) * gp.NUM_MERCHANTS)::INT, 5, '0') AS merchant_id,
           -- 0.2% of intents belong to a burst customer -> drives velocity fraud indicators
           IFF(r_burst < 0.002, 'C0000007',
               'C' || LPAD(1 + FLOOR(OPS.DRAND(gp.SEED||'cus'||i) * gp.NUM_CUSTOMERS)::INT, 7, '0')) AS customer_id,
           'ORD-' || LPAD(i, 9, '0') AS merchant_order_id,
           IFF(source_system = 'PROV_B' AND r_ccy < 0.03, 'USD', 'INR') AS currency_code,
           ROUND(
             CASE
               WHEN channel_value IN ('UPI','WALLET')              THEN EXP(LN(50)   + r_amt*(LN(5000)    - LN(50)))
               WHEN channel_value IN ('debit_card','credit_card')  THEN EXP(LN(200)  + r_amt*(LN(60000)   - LN(200)))
               WHEN channel_value = 'RTGS'                         THEN EXP(LN(200000)+ r_amt*(LN(900000) - LN(200000)))
               ELSE                                                     EXP(LN(1000) + r_amt*(LN(200000)  - LN(1000)))
             END / IFF(source_system = 'PROV_B' AND r_ccy < 0.03, 83.5, 1), 2) AS amount,
           IFF(r_burst < 0.002,
               DATEADD(second, MOD(i, 3000), DATEADD(day, 5, gp.START_DATE)::TIMESTAMP_NTZ),
               DATEADD(second, FLOOR(OPS.DRAND(gp.SEED||'ts'||i) * gp.SECS)::INT, gp.START_DATE::TIMESTAMP_NTZ)) AS base_ts,
           CASE WHEN r_att < 0.10 THEN 2 WHEN r_att < 0.13 THEN 3 ELSE 1 END AS n_attempts,
           CASE WHEN r_out < 0.87 THEN 'CAPTURED'
                WHEN r_out < 0.885 AND source_system <> 'PROV_B' THEN 'REVERSED'
                WHEN r_out < 0.97 THEN 'FAILED'
                ELSE 'PENDING' END AS outcome
    FROM c CROSS JOIN OPS.GEN_PARAMS gp;

    -- attempts: retries fail; the last attempt carries the intent outcome
    -- NOTE: PROV_A and PROV_C both use 'TXN##########' ids with independent
    -- sequences => identical ids exist across providers (intentional).
    CREATE OR REPLACE TRANSIENT TABLE OPS.GEN_ATTEMPT AS
    SELECT t.*,
           a.value::INT AS attempt_no,
           IFF(a.value::INT < t.n_attempts, 'FAILED', t.outcome) AS canonical_status,
           DATEADD(second, (a.value::INT - 1) * 90, t.base_ts) AS attempt_ts,
           CASE t.source_system
             WHEN 'PROV_B' THEN 'pay_' || LOWER(SUBSTR(SHA2(gp.SEED||'pb'||t.i||'-'||a.value::INT), 1, 14))
             ELSE 'TXN' || LPAD(t.prov_seq * 10 + a.value::INT, 10, '0')
           END AS source_transaction_id,
           'tok_' || SUBSTR(SHA2(gp.SEED||'instr'||t.customer_id||t.channel_value), 1, 24) AS instrument_token,
           LPAD(MOD(ABS(HASH(t.customer_id)), 10000), 4, '0') AS card_last4,
           OPS.DRAND(gp.SEED||'late'||t.i||'-'||a.value::INT) AS r_late,
           OPS.DRAND(gp.SEED||'dup'||t.i||'-'||a.value::INT)  AS r_dup
    FROM OPS.GEN_PARAMS gp, OPS.GEN_TXN t,
         LATERAL FLATTEN(INPUT => ARRAY_GENERATE_RANGE(1, t.n_attempts + 1)) a;

    ---------------------------------------------------------------- RAW.PAYMENTS
    -- 4% of PROV_C captures are delivered as pending ('09'); the success only
    -- arrives later in PAYMENT_STATUS_HISTORY (late-arriving update).
    -- 0.5% of attempts are delivered twice in a second batch (duplicate events).
    INSERT INTO RAW.PAYMENTS (SOURCE_SYSTEM, SOURCE_RECORD, RECORD_HASH, SOURCE_FILE_NAME, SOURCE_FILE_ROW, BATCH_ID, INGESTED_AT)
    WITH payload AS (
        SELECT a.*,
               CASE
                 WHEN source_system = 'PROV_C' AND canonical_status = 'CAPTURED' AND r_late < 0.04
                      THEN OPS.PROVIDER_RAW_STATUS(source_system, 'PENDING')
                 WHEN canonical_status = 'REVERSED'
                      THEN OPS.PROVIDER_RAW_STATUS(source_system, 'CAPTURED')
                 ELSE OPS.PROVIDER_RAW_STATUS(source_system, canonical_status)
               END AS delivered_status,
               CASE source_system
                 WHEN 'PROV_A' THEN OBJECT_CONSTRUCT(
                      'txn_ref', source_transaction_id, 'order_id', merchant_order_id, 'merchant_code', merchant_id,
                      'cust_id', customer_id, 'amt', TO_VARCHAR(amount::NUMBER(18,2)), 'ccy', currency_code,
                      'txn_status', delivered_status, 'txn_time', OPS.FORMAT_PROVIDER_TS(source_system, attempt_ts),
                      'channel', channel_value, 'vpa_token', instrument_token, 'device_id', 'dev_' || SUBSTR(SHA2(customer_id), 1, 10))
                 WHEN 'PROV_B' THEN OBJECT_CONSTRUCT(
                      'payment_id', source_transaction_id, 'merchant_reference', merchant_order_id, 'merchant_id', merchant_id,
                      'customer_id', customer_id, 'payment_amount', TO_VARCHAR(ROUND(amount * 100)::NUMBER(38,0)),
                      'currency', currency_code, 'state', delivered_status,
                      'created_at_ms', OPS.FORMAT_PROVIDER_TS(source_system, attempt_ts),
                      'method', channel_value, 'card_token', instrument_token, 'card_last4', card_last4,
                      'card_network', IFF(MOD(ABS(HASH(customer_id)), 3) = 0, 'RUPAY', IFF(MOD(ABS(HASH(customer_id)), 3) = 1, 'VISA', 'MASTERCARD')))
                 ELSE OBJECT_CONSTRUCT(
                      'reference_no', source_transaction_id, 'customer_ref', merchant_order_id, 'merchant_ref', merchant_id,
                      'payer_id', customer_id, 'amount_value', TO_VARCHAR(amount::NUMBER(18,2)), 'currency_code', currency_code,
                      'status_code', delivered_status, 'value_ts', OPS.FORMAT_PROVIDER_TS(source_system, attempt_ts),
                      'rail', channel_value, 'account_token', instrument_token)
               END AS rec
        FROM OPS.GEN_ATTEMPT a
    )
    SELECT source_system, rec, SHA2(source_system || TO_JSON(rec)),
           'synthetic_' || LOWER(source_system) || '.json', ROW_NUMBER() OVER (ORDER BY source_system, source_transaction_id),
           :v_batch, DATEADD(minute, 5, attempt_ts)
    FROM payload
    UNION ALL
    SELECT source_system, rec, SHA2(source_system || TO_JSON(rec)),
           'synthetic_' || LOWER(source_system) || '_redelivery.json', NULL,
           :v_batch || '-REDELIVERY', DATEADD(hour, 6, attempt_ts)
    FROM payload WHERE r_dup < 0.005;

    ---------------------------------------------------------------- RAW.PAYMENT_STATUS_HISTORY
    INSERT INTO RAW.PAYMENT_STATUS_HISTORY (EVENT_ID, SOURCE_SYSTEM, SOURCE_TRANSACTION_ID, RAW_STATUS, EVENT_TS_RAW,
                                            REASON_CODE, SOURCE_FILE_NAME, BATCH_ID, INGESTED_AT)
    WITH ev AS (
        SELECT source_system, source_transaction_id, 1 AS seq, 'CREATED' AS canon, attempt_ts AS ts, NULL AS reason, r_late, r_dup
        FROM OPS.GEN_ATTEMPT
        UNION ALL
        SELECT source_system, source_transaction_id, 2, 'AUTHORIZED', DATEADD(second, 2, attempt_ts), NULL, r_late, r_dup
        FROM OPS.GEN_ATTEMPT WHERE source_system = 'PROV_B' AND canonical_status = 'CAPTURED'
        UNION ALL
        SELECT source_system, source_transaction_id, 3,
               IFF(canonical_status = 'REVERSED', 'CAPTURED', canonical_status),
               DATEADD(second, 5 + FLOOR(r_late * 55)::INT, attempt_ts),
               IFF(canonical_status = 'FAILED', OPS.DPICK(ARRAY_CONSTRUCT('INSUFFICIENT_FUNDS','ISSUER_DECLINE','TIMEOUT','INVALID_PIN'), source_transaction_id), NULL),
               r_late, r_dup
        FROM OPS.GEN_ATTEMPT WHERE canonical_status <> 'PENDING'
        UNION ALL
        SELECT source_system, source_transaction_id, 4, 'REVERSED', DATEADD(day, 1, attempt_ts), 'BANK_REVERSAL', r_late, r_dup
        FROM OPS.GEN_ATTEMPT WHERE canonical_status = 'REVERSED'
    ), shaped AS (
        SELECT source_system || '-' || source_transaction_id || '-' || seq AS event_id,
               source_system, source_transaction_id,
               OPS.PROVIDER_RAW_STATUS(source_system, canon) AS raw_status,
               OPS.FORMAT_PROVIDER_TS(source_system, ts) AS ts_raw,
               reason,
               -- 3% of final events arrive a day late in a separate batch
               IFF(seq = 3 AND r_late < 0.03, 1, 0) AS is_late,
               ts, r_dup, seq
        FROM ev
    )
    SELECT event_id, source_system, source_transaction_id, raw_status, ts_raw, reason,
           'status_events.json', :v_batch || IFF(is_late = 1, '-LATE', ''),
           DATEADD(minute, IFF(is_late = 1, 1500, 5), ts)
    FROM shaped
    UNION ALL   -- duplicate status event deliveries
    SELECT event_id, source_system, source_transaction_id, raw_status, ts_raw, reason,
           'status_events_redelivery.json', :v_batch || '-REDELIVERY', DATEADD(hour, 6, ts)
    FROM shaped WHERE r_dup < 0.005 AND seq = 3;

    ---------------------------------------------------------------- refunds (incl. multiple partials)
    CREATE OR REPLACE TRANSIENT TABLE OPS.GEN_REFUND AS
    WITH cand AS (
        SELECT a.*, OPS.DRAND(gp.SEED||'rf'||source_system||source_transaction_id) AS r_rf,
                    OPS.DRAND(gp.SEED||'rf2'||source_system||source_transaction_id) AS r_rf2
        FROM OPS.GEN_ATTEMPT a CROSS JOIN OPS.GEN_PARAMS gp WHERE canonical_status = 'CAPTURED'
    )
    SELECT c.source_system, c.source_transaction_id, c.merchant_id, c.currency_code, c.attempt_ts, c.amount,
           f.value::INT AS refund_no,
           IFF(r_rf2 < 0.30, 2, 1) AS refund_count,
           CASE WHEN r_rf2 < 0.30 THEN ROUND(c.amount * IFF(f.value::INT = 1, 0.40, 0.30), 2)
                WHEN r_rf2 < 0.65 THEN ROUND(c.amount * 0.50, 2)
                ELSE c.amount END AS refund_amount,
           CASE WHEN r_rf2 < 0.65 THEN 'PARTIAL' ELSE 'FULL' END AS refund_type,
           DATEADD(hour, 24 * (1 + FLOOR(OPS.DRAND(gp.SEED||'rfd'||c.source_transaction_id||f.value)*20)), c.attempt_ts) AS requested_at,
           IFF(OPS.DRAND(gp.SEED||'rfs'||c.source_transaction_id||f.value) < 0.95, 'PROCESSED', 'FAILED') AS final_status
    FROM OPS.GEN_PARAMS gp, cand c,
         LATERAL FLATTEN(INPUT => ARRAY_GENERATE_RANGE(1, IFF(c.r_rf2 < 0.30, 2, 1) + 1)) f
    WHERE c.r_rf < 0.06;

    INSERT INTO RAW.REFUNDS (REFUND_ID, SOURCE_SYSTEM, SOURCE_TRANSACTION_ID, REFUND_AMOUNT, CURRENCY_CODE,
                             REFUND_TYPE, REFUND_REASON, REQUESTED_AT, SOURCE_FILE_NAME, BATCH_ID, INGESTED_AT)
    SELECT 'RF-' || source_system || '-' || source_transaction_id || '-' || refund_no,
           source_system, source_transaction_id, refund_amount, currency_code, refund_type,
           OPS.DPICK(ARRAY_CONSTRUCT('CUSTOMER_REQUEST','ITEM_NOT_RECEIVED','DUPLICATE_CHARGE','ORDER_CANCELLED'), source_transaction_id||refund_no),
           requested_at, 'refunds.csv', :v_batch, DATEADD(minute, 10, requested_at)
    FROM OPS.GEN_REFUND;

    INSERT INTO RAW.REFUND_STATUS_HISTORY (REFUND_EVENT_ID, REFUND_ID, REFUND_STATUS, EVENT_TS, SOURCE_FILE_NAME, BATCH_ID, INGESTED_AT)
    SELECT 'RFE-' || source_system || '-' || source_transaction_id || '-' || refund_no || '-1',
           'RF-' || source_system || '-' || source_transaction_id || '-' || refund_no,
           'INITIATED', requested_at, 'refund_events.csv', :v_batch, DATEADD(minute, 10, requested_at)
    FROM OPS.GEN_REFUND
    UNION ALL
    SELECT 'RFE-' || source_system || '-' || source_transaction_id || '-' || refund_no || '-2',
           'RF-' || source_system || '-' || source_transaction_id || '-' || refund_no,
           final_status, DATEADD(hour, 30, requested_at), 'refund_events.csv', :v_batch, DATEADD(hour, 31, requested_at)
    FROM OPS.GEN_REFUND;

    ---------------------------------------------------------------- chargebacks (card payments)
    INSERT INTO RAW.CHARGEBACKS (CHARGEBACK_ID, SOURCE_SYSTEM, SOURCE_TRANSACTION_ID, CHARGEBACK_AMOUNT, CURRENCY_CODE,
                                 REASON_CODE, CHARGEBACK_STATUS, RECEIVED_DATE, RESOLVED_DATE, SOURCE_FILE_NAME, BATCH_ID, INGESTED_AT)
    WITH cb AS (
        SELECT a.*, OPS.DRAND(:P_SEED||'cb'||source_transaction_id) AS r_cb,
               OPS.DRAND(:P_SEED||'cbs'||source_transaction_id) AS r_cbs
        FROM OPS.GEN_ATTEMPT a
        WHERE source_system = 'PROV_B' AND canonical_status = 'CAPTURED'
    )
    SELECT 'CB-' || source_transaction_id, source_system, source_transaction_id, amount, currency_code,
           OPS.DPICK(ARRAY_CONSTRUCT('4837','4853','10.4','13.1','4855'), source_transaction_id),
           CASE WHEN r_cbs < 0.25 THEN 'OPEN' WHEN r_cbs < 0.55 THEN 'WON' WHEN r_cbs < 0.9 THEN 'LOST' ELSE 'ACCEPTED' END,
           DATEADD(day, 10 + FLOOR(r_cb * 3000)::INT % 30, TO_DATE(attempt_ts)),
           IFF(r_cbs < 0.25, NULL, DATEADD(day, 40 + FLOOR(r_cb * 3000)::INT % 30, TO_DATE(attempt_ts))),
           'chargebacks.csv', :v_batch, DATEADD(day, 11, attempt_ts)
    FROM cb WHERE r_cb < 0.008;

    ---------------------------------------------------------------- settlements
    -- Rules (per captured attempt, r = DRAND):
    --   r < 0.020           : never settled            -> UNSETTLED
    --   0.020 <= r < 0.025  : two partial lines (60/40)-> MATCHED via multiple events
    --   0.025 <= r < 0.030  : only first partial line  -> PARTIALLY_SETTLED
    --   0.030 <= r < 0.035  : short-settled            -> AMOUNT_MISMATCH
    --   otherwise           : one full SALE line       -> MATCHED
    CREATE OR REPLACE TRANSIENT TABLE OPS.GEN_SETTLE_BASE AS
    SELECT a.source_system, a.source_transaction_id, a.merchant_id, a.currency_code, a.amount, a.attempt_ts,
           m.FEE_PCT, m.SETTLEMENT_CYCLE_DAYS,
           DATEADD(day, m.SETTLEMENT_CYCLE_DAYS, TO_DATE(CONVERT_TIMEZONE('UTC','Asia/Kolkata', a.attempt_ts))) AS settle_date,
           IFF(a.currency_code = 'USD', 'PX',
               DECODE(a.source_system,'PROV_A','PA','PROV_B','PB','PROV_C','PC')) AS batch_code,
           OPS.DRAND(gp.SEED||'set'||a.source_system||a.source_transaction_id) AS r_set
    FROM OPS.GEN_ATTEMPT a
    CROSS JOIN OPS.GEN_PARAMS gp
    JOIN RAW.MERCHANTS m ON m.MERCHANT_ID = a.merchant_id AND m.BATCH_ID = gp.BATCH_ID
    WHERE a.canonical_status = 'CAPTURED';

    INSERT INTO RAW.BANK_SETTLEMENTS (SETTLEMENT_LINE_ID, SETTLEMENT_BATCH_ID, SOURCE_SYSTEM, SOURCE_TRANSACTION_ID,
          MERCHANT_ID, SETTLEMENT_TYPE, IS_FINAL_SETTLEMENT, GROSS_AMOUNT, FEE_AMOUNT, TAX_AMOUNT, NET_AMOUNT,
          CURRENCY_CODE, SETTLEMENT_DATE, SOURCE_FILE_NAME, BATCH_ID, INGESTED_AT)
    WITH lines AS (
        SELECT source_system, source_transaction_id, merchant_id, currency_code, FEE_PCT, batch_code,
               1 AS line_no, TRUE AS is_final, amount AS gross, settle_date
        FROM OPS.GEN_SETTLE_BASE WHERE r_set >= 0.035
        UNION ALL
        SELECT source_system, source_transaction_id, merchant_id, currency_code, FEE_PCT, batch_code,
               1, FALSE, ROUND(amount * 0.6, 2), settle_date
        FROM OPS.GEN_SETTLE_BASE WHERE r_set >= 0.020 AND r_set < 0.030
        UNION ALL
        SELECT source_system, source_transaction_id, merchant_id, currency_code, FEE_PCT, batch_code,
               2, TRUE, amount - ROUND(amount * 0.6, 2), DATEADD(day, 1, settle_date)
        FROM OPS.GEN_SETTLE_BASE WHERE r_set >= 0.020 AND r_set < 0.025
        UNION ALL
        SELECT source_system, source_transaction_id, merchant_id, currency_code, FEE_PCT, batch_code,
               1, TRUE, GREATEST(amount - ROUND(5 + OPS.DRAND(:P_SEED||'mm'||source_transaction_id) * 200, 2), 0.01), settle_date
        FROM OPS.GEN_SETTLE_BASE WHERE r_set >= 0.030 AND r_set < 0.035
    )
    SELECT 'SL-' || source_system || '-' || source_transaction_id || '-' || line_no,
           'SB-' || batch_code || '-' || TO_CHAR(settle_date, 'YYYYMMDD'),
           source_system, source_transaction_id, merchant_id, 'SALE', is_final,
           gross,
           ROUND(gross * FEE_PCT, 2),
           ROUND(ROUND(gross * FEE_PCT, 2) * 0.18, 2),
           gross - ROUND(gross * FEE_PCT, 2) - ROUND(ROUND(gross * FEE_PCT, 2) * 0.18, 2),
           currency_code, settle_date, 'settlement_report.csv', :v_batch,
           DATEADD(hour, 30, settle_date::TIMESTAMP_NTZ)
    FROM lines;

    -- refund debits settle 2 days after the refund is processed
    INSERT INTO RAW.BANK_SETTLEMENTS (SETTLEMENT_LINE_ID, SETTLEMENT_BATCH_ID, SOURCE_SYSTEM, SOURCE_TRANSACTION_ID,
          MERCHANT_ID, SETTLEMENT_TYPE, IS_FINAL_SETTLEMENT, GROSS_AMOUNT, FEE_AMOUNT, TAX_AMOUNT, NET_AMOUNT,
          CURRENCY_CODE, SETTLEMENT_DATE, SOURCE_FILE_NAME, BATCH_ID, INGESTED_AT)
    SELECT 'SL-RF-' || r.source_system || '-' || r.source_transaction_id || '-' || r.refund_no,
           'SB-' || IFF(r.currency_code = 'USD','PX', DECODE(r.source_system,'PROV_A','PA','PROV_B','PB','PROV_C','PC'))
                 || '-' || TO_CHAR(DATEADD(day, 2, TO_DATE(CONVERT_TIMEZONE('UTC','Asia/Kolkata', r.requested_at))), 'YYYYMMDD'),
           r.source_system, r.source_transaction_id, r.merchant_id, 'REFUND', TRUE,
           -r.refund_amount, 0, 0, -r.refund_amount, r.currency_code,
           DATEADD(day, 2, TO_DATE(CONVERT_TIMEZONE('UTC','Asia/Kolkata', r.requested_at))),
           'settlement_report.csv', :v_batch, DATEADD(day, 3, r.requested_at)
    FROM OPS.GEN_REFUND r WHERE r.final_status = 'PROCESSED';

    -- lost chargebacks are debited on resolution
    INSERT INTO RAW.BANK_SETTLEMENTS (SETTLEMENT_LINE_ID, SETTLEMENT_BATCH_ID, SOURCE_SYSTEM, SOURCE_TRANSACTION_ID,
          MERCHANT_ID, SETTLEMENT_TYPE, IS_FINAL_SETTLEMENT, GROSS_AMOUNT, FEE_AMOUNT, TAX_AMOUNT, NET_AMOUNT,
          CURRENCY_CODE, SETTLEMENT_DATE, SOURCE_FILE_NAME, BATCH_ID, INGESTED_AT)
    SELECT 'SL-CB-' || c.CHARGEBACK_ID,
           'SB-' || IFF(c.CURRENCY_CODE = 'USD','PX','PB') || '-' || TO_CHAR(c.RESOLVED_DATE, 'YYYYMMDD'),
           c.SOURCE_SYSTEM, c.SOURCE_TRANSACTION_ID, a.merchant_id, 'CHARGEBACK', TRUE,
           -c.CHARGEBACK_AMOUNT, 0, 0, -c.CHARGEBACK_AMOUNT, c.CURRENCY_CODE, c.RESOLVED_DATE,
           'settlement_report.csv', :v_batch, DATEADD(day, 1, c.RESOLVED_DATE::TIMESTAMP_NTZ)
    FROM RAW.CHARGEBACKS c
    JOIN OPS.GEN_ATTEMPT a ON a.source_system = c.SOURCE_SYSTEM AND a.source_transaction_id = c.SOURCE_TRANSACTION_ID
    WHERE c.BATCH_ID = :v_batch AND c.CHARGEBACK_STATUS IN ('LOST','ACCEPTED');

    ---------------------------------------------------------------- bank statement
    -- One bank entry per settlement batch, bank-specific narrative format.
    --   1.0% of batches: missing credit          -> MISSING_BANK_CREDIT
    --   1.0% of batches: bank charge deducted    -> AMOUNT_MISMATCH
    --   5.0% of batches: credited one day late   -> timing difference (still MATCHED)
    INSERT INTO RAW.BANK_STATEMENT_TRANSACTIONS (BANK_TXN_ID, BANK_CODE, BANK_ACCOUNT_TOKEN, VALUE_DATE, POSTING_TS,
          DR_CR, AMOUNT, CURRENCY_CODE, NARRATIVE, SOURCE_FILE_NAME, BATCH_ID, INGESTED_AT)
    WITH b AS (
        SELECT SETTLEMENT_BATCH_ID, CURRENCY_CODE, MIN(SETTLEMENT_DATE) AS settle_date, SUM(NET_AMOUNT) AS net,
               SPLIT_PART(SETTLEMENT_BATCH_ID, '-', 2) AS code, SPLIT_PART(SETTLEMENT_BATCH_ID, '-', 3) AS dt,
               OPS.DRAND(:P_SEED||'bank'||SETTLEMENT_BATCH_ID) AS r_bank
        FROM RAW.BANK_SETTLEMENTS WHERE BATCH_ID = :v_batch
        GROUP BY SETTLEMENT_BATCH_ID, CURRENCY_CODE
    ), shaped AS (
        SELECT b.*,
               DECODE(code, 'PA','HDFC', 'PB','ICICI', 'PX','ICICI', 'PC','SBI') AS bank_code,
               IFF(r_bank >= 0.02 AND r_bank < 0.03, net - 25.00, net) AS booked,
               IFF(r_bank >= 0.03 AND r_bank < 0.08, DATEADD(day, 1, settle_date), settle_date) AS value_date
        FROM b WHERE r_bank >= 0.01
    )
    SELECT 'BST-' || SETTLEMENT_BATCH_ID, bank_code,
           'acct_' || SUBSTR(SHA2(bank_code || CURRENCY_CODE), 1, 12),
           value_date, DATEADD(hour, 10, value_date::TIMESTAMP_NTZ),
           IFF(booked >= 0, 'CR', 'DR'), ABS(booked), CURRENCY_CODE,
           CASE bank_code
             WHEN 'HDFC'  THEN 'NEFT CR-HDFC0000123-PROVIDER PAYMENTS-SETTL ' || SETTLEMENT_BATCH_ID
             WHEN 'ICICI' THEN 'IMPS/P2A/' || LPAD(ABS(HASH(SETTLEMENT_BATCH_ID)) % 1000000000000, 12, '0') || '/SETTLEMENT/SB' || code || dt || '/PROVB'
             ELSE              'BY TRANSFER-INB ref:SB_' || code || '_' || dt || ' PROVIDER-C'
           END,
           'bank_statement_' || LOWER(bank_code) || '.csv', :v_batch,
           DATEADD(hour, 20, value_date::TIMESTAMP_NTZ)
    FROM shaped;

    -- non-settlement bank entries (interest, charges) -> UNIDENTIFIED_BANK_ENTRY
    INSERT INTO RAW.BANK_STATEMENT_TRANSACTIONS (BANK_TXN_ID, BANK_CODE, BANK_ACCOUNT_TOKEN, VALUE_DATE, POSTING_TS,
          DR_CR, AMOUNT, CURRENCY_CODE, NARRATIVE, SOURCE_FILE_NAME, BATCH_ID, INGESTED_AT)
    SELECT 'BST-MISC-' || N, 'HDFC', 'acct_' || SUBSTR(SHA2('HDFCINR'), 1, 12),
           DATEADD(month, N - 1, DATE_TRUNC('month', :P_START_DATE)) + 27,
           DATEADD(hour, 10, (DATEADD(month, N - 1, DATE_TRUNC('month', :P_START_DATE)) + 27)::TIMESTAMP_NTZ),
           IFF(MOD(N, 2) = 0, 'CR', 'DR'), IFF(MOD(N, 2) = 0, 1250.00, 590.00), 'INR',
           IFF(MOD(N, 2) = 0, 'INT.CREDIT CURRENT ACCOUNT', 'ACCOUNT MAINTENANCE CHARGES GST'),
           'bank_statement_hdfc.csv', :v_batch, SYSDATE()
    FROM OPS.GEN_NUMBERS WHERE N <= GREATEST(1, DATEDIFF(month, :P_START_DATE, :P_END_DATE) + 1);

    ---------------------------------------------------------------- fraud alerts (vendor engine)
    INSERT INTO RAW.FRAUD_ALERTS (ALERT_ID, SOURCE_SYSTEM, SOURCE_TRANSACTION_ID, CUSTOMER_ID, RULE_CODE, ALERT_SCORE,
                                  ALERT_STATUS, ALERT_TS, SOURCE_FILE_NAME, BATCH_ID, INGESTED_AT)
    WITH f AS (
        SELECT a.*, OPS.DRAND(:P_SEED||'fr'||source_system||source_transaction_id) AS r_fr,
                    OPS.DRAND(:P_SEED||'frs'||source_system||source_transaction_id) AS r_frs
        FROM OPS.GEN_ATTEMPT a
    )
    SELECT 'FA-' || source_system || '-' || source_transaction_id, source_system, source_transaction_id, customer_id,
           OPS.DPICK(ARRAY_CONSTRUCT('DEVICE_MISMATCH','GEO_ANOMALY','AMOUNT_SPIKE','NEW_INSTRUMENT','BIN_RISK'), source_transaction_id),
           ROUND(40 + r_frs * 60, 2),
           CASE WHEN r_frs < 0.40 THEN 'FALSE_POSITIVE' WHEN r_frs < 0.70 THEN 'CLOSED'
                WHEN r_frs < 0.85 THEN 'OPEN' ELSE 'CONFIRMED_FRAUD' END,
           DATEADD(second, 30, attempt_ts), 'fraud_alerts.csv', :v_batch, DATEADD(minute, 15, attempt_ts)
    FROM f WHERE r_fr < 0.01 OR customer_id = 'C0000007';

    ---------------------------------------------------------------- audit + control totals
    INSERT INTO AUDIT.INGESTION_LOG (BATCH_ID, TARGET_TABLE, LOAD_METHOD, ROWS_LOADED, ROWS_REJECTED, STATUS, STARTED_AT, MESSAGE)
    SELECT :v_batch, t, 'SYNTHETIC_SQL', c, 0, 'SUCCESS', :v_started, 'seed=' || :P_SEED
    FROM (
      SELECT 'RAW.PAYMENTS' t, COUNT(*) c FROM RAW.PAYMENTS WHERE BATCH_ID LIKE :v_batch || '%' UNION ALL
      SELECT 'RAW.PAYMENT_STATUS_HISTORY', COUNT(*) FROM RAW.PAYMENT_STATUS_HISTORY WHERE BATCH_ID LIKE :v_batch || '%' UNION ALL
      SELECT 'RAW.CUSTOMERS', COUNT(*) FROM RAW.CUSTOMERS WHERE BATCH_ID = :v_batch UNION ALL
      SELECT 'RAW.CUSTOMER_KYC_HISTORY', COUNT(*) FROM RAW.CUSTOMER_KYC_HISTORY WHERE BATCH_ID = :v_batch UNION ALL
      SELECT 'RAW.MERCHANTS', COUNT(*) FROM RAW.MERCHANTS WHERE BATCH_ID = :v_batch UNION ALL
      SELECT 'RAW.REFUNDS', COUNT(*) FROM RAW.REFUNDS WHERE BATCH_ID = :v_batch UNION ALL
      SELECT 'RAW.REFUND_STATUS_HISTORY', COUNT(*) FROM RAW.REFUND_STATUS_HISTORY WHERE BATCH_ID = :v_batch UNION ALL
      SELECT 'RAW.BANK_SETTLEMENTS', COUNT(*) FROM RAW.BANK_SETTLEMENTS WHERE BATCH_ID = :v_batch UNION ALL
      SELECT 'RAW.BANK_STATEMENT_TRANSACTIONS', COUNT(*) FROM RAW.BANK_STATEMENT_TRANSACTIONS WHERE BATCH_ID = :v_batch UNION ALL
      SELECT 'RAW.PAYMENT_CHANNELS', COUNT(*) FROM RAW.PAYMENT_CHANNELS WHERE BATCH_ID = :v_batch UNION ALL
      SELECT 'RAW.FRAUD_ALERTS', COUNT(*) FROM RAW.FRAUD_ALERTS WHERE BATCH_ID = :v_batch UNION ALL
      SELECT 'RAW.CHARGEBACKS', COUNT(*) FROM RAW.CHARGEBACKS WHERE BATCH_ID = :v_batch
    );

    -- Generator-side control totals: what dbt must reproduce downstream.
    INSERT INTO AUDIT.CONTROL_TOTALS (BATCH_ID, CONTROL_POINT, OBJECT_NAME, CURRENCY_CODE, ROW_COUNT, AMOUNT_TOTAL)
    SELECT :v_batch, 'GENERATOR_TRUTH', 'CAPTURED_ATTEMPTS', currency_code, COUNT(*), SUM(amount)
    FROM OPS.GEN_ATTEMPT WHERE canonical_status = 'CAPTURED' GROUP BY currency_code
    UNION ALL
    SELECT :v_batch, 'GENERATOR_TRUTH', 'DISTINCT_ATTEMPTS', NULL, COUNT(*), NULL FROM OPS.GEN_ATTEMPT
    UNION ALL
    SELECT :v_batch, 'GENERATOR_TRUTH', 'TRANSACTIONS', NULL, COUNT(*), NULL FROM OPS.GEN_TXN;

    v_result := (SELECT OBJECT_AGG(TARGET_TABLE, ROWS_LOADED::VARIANT) FROM AUDIT.INGESTION_LOG WHERE BATCH_ID = :v_batch);

    DROP TABLE IF EXISTS OPS.GEN_SETTLE_BASE;
    DROP TABLE IF EXISTS OPS.GEN_REFUND;
    -- GEN_TXN / GEN_ATTEMPT are kept until the next run for inspection.

    INSERT INTO AUDIT.PROCEDURE_LOG (PROCEDURE_NAME, RUN_ID, STEP, STATUS, MESSAGE)
    VALUES ('SP_GENERATE_SYNTHETIC_DATA', :v_batch, 'END', 'SUCCESS', TO_VARCHAR(:v_result));

    RETURN OBJECT_CONSTRUCT('status','SUCCESS','batch_id',v_batch,'row_counts',v_result);

EXCEPTION
    WHEN OTHER THEN
        INSERT INTO AUDIT.PROCEDURE_LOG (PROCEDURE_NAME, RUN_ID, STEP, STATUS, MESSAGE)
        VALUES ('SP_GENERATE_SYNTHETIC_DATA', :v_batch, 'ERROR', 'FAILED',
                'SQLCODE=' || :SQLCODE || ' ' || :SQLERRM || ' STATE=' || :SQLSTATE);
        RAISE;
END;
$$;

-- Example (default volumes, ~57k attempts, < 1 minute on XSMALL):
-- CALL OPS.SP_GENERATE_SYNTHETIC_DATA();
-- Larger volume / different window:
-- CALL OPS.SP_GENERATE_SYNTHETIC_DATA(50000, 1000, 1000000, '2026-01-01', '2026-09-30', 'FINTECH-2026', TRUE);
