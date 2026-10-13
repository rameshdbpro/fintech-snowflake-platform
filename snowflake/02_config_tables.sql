/* =====================================================================
   02_CONFIG_TABLES.SQL
   Runtime metadata. Every table here can be changed WITHOUT a code
   deployment, through the change-request workflow (14_change_management.sql).
   The effect lands on the next dbt build (or immediately for objects that
   read config at query time, e.g. OPS.SP_RUN_DQ_RULES).

   What is NOT here (code changes needing deployment):
     * provider field mappings -> dbt_project.yml vars.payment_providers,
       published read-only as CANONICAL.CFG_SOURCE_ATTRIBUTE_MAPPING
     * model SQL, grains, materialisations -> dbt code
   ===================================================================== */
USE ROLE FINTECH_DEPLOYER;
SET DB_NAME = 'FINTECH_DEV';
USE DATABASE IDENTIFIER($DB_NAME);
USE WAREHOUSE WH_FINTECH_LOAD;
USE SCHEMA CONFIG;

-- Registered providers ------------------------------------------------
CREATE TABLE IF NOT EXISTS CONFIG.SOURCE_SYSTEM (
    SOURCE_SYSTEM        VARCHAR(20) PRIMARY KEY,
    PROVIDER_NAME        VARCHAR(100),
    PROVIDER_SHORT_CODE  VARCHAR(4),
    TIMESTAMP_CONVENTION VARCHAR(20) COMMENT 'LOCAL_TZ | EPOCH_MS | ISO8601_TZ',
    SOURCE_TIMEZONE      VARCHAR(50),
    AMOUNT_UNIT          VARCHAR(10) COMMENT 'MAJOR | MINOR',
    IS_ACTIVE            BOOLEAN DEFAULT TRUE,
    ONBOARDED_AT         TIMESTAMP_NTZ DEFAULT SYSDATE()
);
MERGE INTO CONFIG.SOURCE_SYSTEM t USING (
  SELECT * FROM VALUES
   ('PROV_A','Acme UPI & Wallet Aggregator','PA','LOCAL_TZ','Asia/Kolkata','MAJOR'),
   ('PROV_B','Beta Card Gateway','PB','EPOCH_MS','UTC','MINOR'),
   ('PROV_C','Gamma Bank Transfer Switch','PC','ISO8601_TZ',NULL,'MAJOR')
  AS s(SOURCE_SYSTEM,PROVIDER_NAME,PROVIDER_SHORT_CODE,TIMESTAMP_CONVENTION,SOURCE_TIMEZONE,AMOUNT_UNIT)
) s ON t.SOURCE_SYSTEM = s.SOURCE_SYSTEM
WHEN NOT MATCHED THEN INSERT (SOURCE_SYSTEM,PROVIDER_NAME,PROVIDER_SHORT_CODE,TIMESTAMP_CONVENTION,SOURCE_TIMEZONE,AMOUNT_UNIT)
VALUES (s.SOURCE_SYSTEM,s.PROVIDER_NAME,s.PROVIDER_SHORT_CODE,s.TIMESTAMP_CONVENTION,s.SOURCE_TIMEZONE,s.AMOUNT_UNIT);

-- Status normalisation (runtime-configurable) -------------------------
-- Unknown (source_system, raw status) pairs are NOT dropped: they flow to
-- CANONICAL.CNL_EXCEPTIONS with exception_type = 'UNKNOWN_STATUS'.
CREATE TABLE IF NOT EXISTS CONFIG.STATUS_MAPPING (
    SOURCE_SYSTEM     VARCHAR(20)  NOT NULL,
    STATUS_DOMAIN     VARCHAR(20)  NOT NULL COMMENT 'PAYMENT | REFUND | CHARGEBACK',
    SOURCE_STATUS     VARCHAR(50)  NOT NULL,
    CANONICAL_STATUS  VARCHAR(30)  NOT NULL,
    STATUS_CATEGORY   VARCHAR(20)  NOT NULL COMMENT 'SUCCESS | FAILURE | IN_PROGRESS | REVERSAL',
    IS_TERMINAL       BOOLEAN      NOT NULL,
    STATUS_RANK       NUMBER(3,0)  NOT NULL COMMENT 'Tie-break when two events share a timestamp: higher wins',
    IS_ACTIVE         BOOLEAN      DEFAULT TRUE,
    UPDATED_BY        VARCHAR(100) DEFAULT CURRENT_USER(),
    UPDATED_AT        TIMESTAMP_NTZ DEFAULT SYSDATE(),
    CONSTRAINT PK_STATUS_MAPPING PRIMARY KEY (SOURCE_SYSTEM, STATUS_DOMAIN, SOURCE_STATUS)
);
MERGE INTO CONFIG.STATUS_MAPPING t USING (
  SELECT * FROM VALUES
   -- Provider A (UPPERCASE words)
   ('PROV_A','PAYMENT','INITIATED','CREATED','IN_PROGRESS',FALSE,10),
   ('PROV_A','PAYMENT','PENDING','PENDING','IN_PROGRESS',FALSE,20),
   ('PROV_A','PAYMENT','SUCCESS','CAPTURED','SUCCESS',TRUE,50),
   ('PROV_A','PAYMENT','FAILED','FAILED','FAILURE',TRUE,40),
   ('PROV_A','PAYMENT','REVERSED','REVERSED','REVERSAL',TRUE,60),
   -- Provider B (lowercase states)
   ('PROV_B','PAYMENT','created','CREATED','IN_PROGRESS',FALSE,10),
   ('PROV_B','PAYMENT','authorized','AUTHORIZED','IN_PROGRESS',FALSE,30),
   ('PROV_B','PAYMENT','captured','CAPTURED','SUCCESS',TRUE,50),
   ('PROV_B','PAYMENT','declined','FAILED','FAILURE',TRUE,40),
   ('PROV_B','PAYMENT','failed','FAILED','FAILURE',TRUE,40),
   ('PROV_B','PAYMENT','voided','VOIDED','REVERSAL',TRUE,60),
   ('PROV_B','PAYMENT','refunded','CAPTURED','SUCCESS',TRUE,55),  -- refunds tracked in REFUND domain
   -- Provider C (ISO-8583 style response codes)
   ('PROV_C','PAYMENT','09','PENDING','IN_PROGRESS',FALSE,20),
   ('PROV_C','PAYMENT','00','CAPTURED','SUCCESS',TRUE,50),
   ('PROV_C','PAYMENT','05','FAILED','FAILURE',TRUE,40),
   ('PROV_C','PAYMENT','91','FAILED','FAILURE',TRUE,40),
   ('PROV_C','PAYMENT','R1','REVERSED','REVERSAL',TRUE,60),
   -- Refund statuses are shared across providers ('*')
   ('*','REFUND','INITIATED','REFUND_INITIATED','IN_PROGRESS',FALSE,10),
   ('*','REFUND','PROCESSED','REFUND_PROCESSED','SUCCESS',TRUE,50),
   ('*','REFUND','FAILED','REFUND_FAILED','FAILURE',TRUE,40),
   ('*','REFUND','REVERSED','REFUND_REVERSED','REVERSAL',TRUE,60),
   -- Chargebacks
   ('*','CHARGEBACK','OPEN','CB_OPEN','IN_PROGRESS',FALSE,10),
   ('*','CHARGEBACK','WON','CB_WON','SUCCESS',TRUE,50),
   ('*','CHARGEBACK','LOST','CB_LOST','FAILURE',TRUE,50),
   ('*','CHARGEBACK','ACCEPTED','CB_LOST','FAILURE',TRUE,50)
  AS s(SOURCE_SYSTEM,STATUS_DOMAIN,SOURCE_STATUS,CANONICAL_STATUS,STATUS_CATEGORY,IS_TERMINAL,STATUS_RANK)
) s ON t.SOURCE_SYSTEM=s.SOURCE_SYSTEM AND t.STATUS_DOMAIN=s.STATUS_DOMAIN AND t.SOURCE_STATUS=s.SOURCE_STATUS
WHEN NOT MATCHED THEN INSERT (SOURCE_SYSTEM,STATUS_DOMAIN,SOURCE_STATUS,CANONICAL_STATUS,STATUS_CATEGORY,IS_TERMINAL,STATUS_RANK)
VALUES (s.SOURCE_SYSTEM,s.STATUS_DOMAIN,s.SOURCE_STATUS,s.CANONICAL_STATUS,s.STATUS_CATEGORY,s.IS_TERMINAL,s.STATUS_RANK);

-- Allowed canonical statuses (validation target for status mappings) ---
CREATE TABLE IF NOT EXISTS CONFIG.CANONICAL_STATUS (
    STATUS_DOMAIN VARCHAR(20), CANONICAL_STATUS VARCHAR(30), DESCRIPTION VARCHAR(200),
    CONSTRAINT PK_CANONICAL_STATUS PRIMARY KEY (STATUS_DOMAIN, CANONICAL_STATUS)
);
MERGE INTO CONFIG.CANONICAL_STATUS t USING (
  SELECT * FROM VALUES
   ('PAYMENT','CREATED','Attempt created, no outcome yet'),
   ('PAYMENT','PENDING','Awaiting provider/bank outcome'),
   ('PAYMENT','AUTHORIZED','Funds authorised, not yet captured'),
   ('PAYMENT','CAPTURED','Funds captured: counts as a successful payment'),
   ('PAYMENT','FAILED','Declined, failed or timed out'),
   ('PAYMENT','REVERSED','Captured then reversed by provider/bank'),
   ('PAYMENT','VOIDED','Authorisation voided before capture'),
   ('REFUND','REFUND_INITIATED','Refund requested'),
   ('REFUND','REFUND_PROCESSED','Refund paid out'),
   ('REFUND','REFUND_FAILED','Refund failed'),
   ('REFUND','REFUND_REVERSED','Processed refund reversed'),
   ('CHARGEBACK','CB_OPEN','Dispute open'),
   ('CHARGEBACK','CB_WON','Merchant won, funds retained'),
   ('CHARGEBACK','CB_LOST','Merchant lost or accepted, funds debited')
  AS s(STATUS_DOMAIN,CANONICAL_STATUS,DESCRIPTION)
) s ON t.STATUS_DOMAIN=s.STATUS_DOMAIN AND t.CANONICAL_STATUS=s.CANONICAL_STATUS
WHEN NOT MATCHED THEN INSERT VALUES (s.STATUS_DOMAIN,s.CANONICAL_STATUS,s.DESCRIPTION);

-- Reconciliation tolerances -------------------------------------------
CREATE TABLE IF NOT EXISTS CONFIG.RECON_TOLERANCE (
    RECON_SCOPE        VARCHAR(30) NOT NULL COMMENT 'PAYMENT_SETTLEMENT | BATCH_BANK',
    CURRENCY_CODE      VARCHAR(3)  NOT NULL,
    ABS_TOLERANCE      NUMBER(18,2) NOT NULL COMMENT 'Max absolute difference treated as MATCHED',
    PCT_TOLERANCE      NUMBER(9,6)  NOT NULL COMMENT 'Max relative difference treated as MATCHED',
    TIMING_GRACE_DAYS  NUMBER(3,0)  NOT NULL COMMENT 'Days after expected date before missing = exception',
    FEE_VARIANCE_PCT   NUMBER(9,6)  COMMENT 'Allowed |actual fee rate - contracted fee rate|',
    UPDATED_BY VARCHAR(100) DEFAULT CURRENT_USER(), UPDATED_AT TIMESTAMP_NTZ DEFAULT SYSDATE(),
    CONSTRAINT PK_RECON_TOLERANCE PRIMARY KEY (RECON_SCOPE, CURRENCY_CODE)
);
MERGE INTO CONFIG.RECON_TOLERANCE t USING (
  SELECT * FROM VALUES
   ('PAYMENT_SETTLEMENT','INR',1.00,0.0001,3,0.0010),
   ('PAYMENT_SETTLEMENT','USD',0.05,0.0001,5,0.0010),
   ('BATCH_BANK','INR',5.00,0.0000,2,NULL),
   ('BATCH_BANK','USD',0.50,0.0000,3,NULL)
  AS s(RECON_SCOPE,CURRENCY_CODE,ABS_TOLERANCE,PCT_TOLERANCE,TIMING_GRACE_DAYS,FEE_VARIANCE_PCT)
) s ON t.RECON_SCOPE=s.RECON_SCOPE AND t.CURRENCY_CODE=s.CURRENCY_CODE
WHEN NOT MATCHED THEN INSERT (RECON_SCOPE,CURRENCY_CODE,ABS_TOLERANCE,PCT_TOLERANCE,TIMING_GRACE_DAYS,FEE_VARIANCE_PCT)
VALUES (s.RECON_SCOPE,s.CURRENCY_CODE,s.ABS_TOLERANCE,s.PCT_TOLERANCE,s.TIMING_GRACE_DAYS,s.FEE_VARIANCE_PCT);

-- Fraud thresholds ----------------------------------------------------
CREATE TABLE IF NOT EXISTS CONFIG.FRAUD_THRESHOLD (
    RULE_CODE        VARCHAR(50) PRIMARY KEY,
    DESCRIPTION      VARCHAR(300),
    THRESHOLD_VALUE  NUMBER(18,4) NOT NULL,
    WINDOW_MINUTES   NUMBER(6,0),
    SEVERITY         VARCHAR(10),
    IS_ACTIVE        BOOLEAN DEFAULT TRUE,
    UPDATED_BY VARCHAR(100) DEFAULT CURRENT_USER(), UPDATED_AT TIMESTAMP_NTZ DEFAULT SYSDATE()
);
MERGE INTO CONFIG.FRAUD_THRESHOLD t USING (
  SELECT * FROM VALUES
   ('VELOCITY_ATTEMPTS','Payment attempts by one customer inside the window',5,60,'HIGH'),
   ('VELOCITY_FAILED','Failed attempts by one customer inside the window',3,60,'MEDIUM'),
   ('HIGH_VALUE_INR','Single captured payment above this INR value',150000,NULL,'MEDIUM'),
   ('ALERT_SCORE_HIGH','Vendor alert score at or above this is HIGH severity',80,NULL,'HIGH')
  AS s(RULE_CODE,DESCRIPTION,THRESHOLD_VALUE,WINDOW_MINUTES,SEVERITY)
) s ON t.RULE_CODE=s.RULE_CODE
WHEN NOT MATCHED THEN INSERT (RULE_CODE,DESCRIPTION,THRESHOLD_VALUE,WINDOW_MINUTES,SEVERITY)
VALUES (s.RULE_CODE,s.DESCRIPTION,s.THRESHOLD_VALUE,s.WINDOW_MINUTES,s.SEVERITY);

-- Runtime DQ rules on RAW (executed by OPS.SP_RUN_DQ_RULES) ------------
-- dbt tests cover the transformed layers; these rules guard RAW before dbt.
CREATE TABLE IF NOT EXISTS CONFIG.DQ_RULE (
    RULE_ID        VARCHAR(50) PRIMARY KEY,
    TARGET_TABLE   VARCHAR(200) NOT NULL,
    RULE_TYPE      VARCHAR(30)  NOT NULL COMMENT 'NOT_NULL | FRESHNESS_HOURS | ROW_COUNT_MIN | DUPLICATE_KEY | NON_NEGATIVE',
    COLUMN_NAME    VARCHAR(200),
    THRESHOLD      NUMBER(18,4),
    SEVERITY       VARCHAR(10) DEFAULT 'ERROR',
    IS_ACTIVE      BOOLEAN DEFAULT TRUE,
    DESCRIPTION    VARCHAR(300)
);
MERGE INTO CONFIG.DQ_RULE t USING (
  SELECT * FROM VALUES
   ('RAW_PAY_FRESH','RAW.PAYMENTS','FRESHNESS_HOURS','INGESTED_AT',26,'WARN','Payments loaded in the last 26h'),
   ('RAW_PAY_MIN','RAW.PAYMENTS','ROW_COUNT_MIN',NULL,1,'ERROR','Payments not empty'),
   ('RAW_PAY_DUP','RAW.PAYMENTS','DUPLICATE_KEY','RECORD_HASH',0,'WARN','Exact duplicate deliveries (deduped downstream)'),
   ('RAW_PSH_NN','RAW.PAYMENT_STATUS_HISTORY','NOT_NULL','RAW_STATUS',0,'ERROR','Status present'),
   ('RAW_CUST_DUP','RAW.CUSTOMERS','DUPLICATE_KEY','CUSTOMER_ID',0,'WARN','Customer delivered more than once'),
   ('RAW_REF_NEG','RAW.REFUNDS','NON_NEGATIVE','REFUND_AMOUNT',0,'ERROR','Refund amounts >= 0'),
   ('RAW_SET_NN','RAW.BANK_SETTLEMENTS','NOT_NULL','SETTLEMENT_BATCH_ID',0,'ERROR','Batch id present'),
   ('RAW_STMT_FRESH','RAW.BANK_STATEMENT_TRANSACTIONS','FRESHNESS_HOURS','INGESTED_AT',50,'WARN','Bank statements loaded in last 50h'),
   ('RAW_CB_NEG','RAW.CHARGEBACKS','NON_NEGATIVE','CHARGEBACK_AMOUNT',0,'ERROR','Chargeback amounts >= 0')
  AS s(RULE_ID,TARGET_TABLE,RULE_TYPE,COLUMN_NAME,THRESHOLD,SEVERITY,DESCRIPTION)
) s ON t.RULE_ID=s.RULE_ID
WHEN NOT MATCHED THEN INSERT (RULE_ID,TARGET_TABLE,RULE_TYPE,COLUMN_NAME,THRESHOLD,SEVERITY,DESCRIPTION)
VALUES (s.RULE_ID,s.TARGET_TABLE,s.RULE_TYPE,s.COLUMN_NAME,s.THRESHOLD,s.SEVERITY,s.DESCRIPTION);

-- Bank narrative parsing patterns (consumed by the Snowpark UDF) -------
-- Each pattern MUST expose named groups: prov (2 letters) and dt (yyyymmdd).
CREATE TABLE IF NOT EXISTS CONFIG.BANK_NARRATIVE_PATTERN (
    BANK_CODE   VARCHAR(10) NOT NULL,
    PRIORITY    NUMBER(3,0) NOT NULL,
    PATTERN     VARCHAR(500) NOT NULL,
    IS_ACTIVE   BOOLEAN DEFAULT TRUE,
    EXAMPLE     VARCHAR(300),
    CONSTRAINT PK_BANK_PATTERN PRIMARY KEY (BANK_CODE, PRIORITY)
);
MERGE INTO CONFIG.BANK_NARRATIVE_PATTERN t USING (
  SELECT * FROM VALUES
   ('HDFC',1,'SETTL\\s+SB-(?P<prov>[A-Z]{2})-(?P<dt>\\d{8})','NEFT CR-HDFC0000123-PROVIDER PAYMENTS-SETTL SB-PA-20260401'),
   ('ICICI',1,'/SETTLEMENT/SB(?P<prov>[A-Z]{2})(?P<dt>\\d{8})/','IMPS/P2A/612345678901/SETTLEMENT/SBPB20260401/PROVB'),
   ('SBI',1,'ref:SB_(?P<prov>[A-Z]{2})_(?P<dt>\\d{8})','BY TRANSFER-INB ref:SB_PC_20260401 PROVIDER-C'),
   ('*',99,'SB[-_]?(?P<prov>[A-Z]{2})[-_]?(?P<dt>20\\d{6})','Generic fallback for any bank')
  AS s(BANK_CODE,PRIORITY,PATTERN,EXAMPLE)
) s ON t.BANK_CODE=s.BANK_CODE AND t.PRIORITY=s.PRIORITY
WHEN NOT MATCHED THEN INSERT (BANK_CODE,PRIORITY,PATTERN,EXAMPLE) VALUES (s.BANK_CODE,s.PRIORITY,s.PATTERN,s.EXAMPLE);

-- Row access mapping (role -> merchant region) -------------------------
CREATE TABLE IF NOT EXISTS CONFIG.ROW_ACCESS_MAP (
    ROLE_NAME VARCHAR(100) NOT NULL, REGION VARCHAR(10) NOT NULL,
    CONSTRAINT PK_ROW_ACCESS PRIMARY KEY (ROLE_NAME, REGION)
);
MERGE INTO CONFIG.ROW_ACCESS_MAP t USING (
  SELECT * FROM VALUES ('FINTECH_ANALYST_SOUTH','SOUTH'),('FINTECH_ANALYST_NORTH','NORTH')
  AS s(ROLE_NAME,REGION)
) s ON t.ROLE_NAME=s.ROLE_NAME AND t.REGION=s.REGION
WHEN NOT MATCHED THEN INSERT VALUES (s.ROLE_NAME,s.REGION);

-- Governed metric registry (documentation + impact analysis) -----------
CREATE TABLE IF NOT EXISTS CONFIG.METRIC_DEFINITION (
    METRIC_NAME          VARCHAR(100) PRIMARY KEY,
    BUSINESS_MEANING     VARCHAR(1000),
    AUTHORITATIVE_MODEL  VARCHAR(200),
    GRAIN                VARCHAR(200),
    NUMERATOR            VARCHAR(500),
    DENOMINATOR          VARCHAR(500),
    FILTERS              VARCHAR(500),
    REPORTING_TIMESTAMP  VARCHAR(200),
    TIMEZONE             VARCHAR(50),
    CURRENCY_TREATMENT   VARCHAR(300),
    RETRY_HANDLING       VARCHAR(300),
    REVERSAL_TREATMENT   VARCHAR(300),
    OWNER                VARCHAR(100),
    VERSION              NUMBER(5,0) DEFAULT 1,
    UPDATED_AT           TIMESTAMP_NTZ DEFAULT SYSDATE()
);
MERGE INTO CONFIG.METRIC_DEFINITION t USING (
  SELECT * FROM VALUES
  ('PAYMENT_VOLUME','Value of successfully captured payments','CORE.FACT_PAYMENT_TRANSACTION','payment transaction','SUM(captured_amount_inr) WHERE final_status = CAPTURED',NULL,'final_status = CAPTURED','first_captured_at_ist (date)','Asia/Kolkata','Converted to INR at monthly FX rate; original currency kept in fact','A transaction is counted once regardless of attempts','REVERSED/VOIDED transactions excluded (final_status <> CAPTURED)','Payments Product'),
  ('PAYMENT_ATTEMPT_COUNT','Number of provider payment attempts','CORE.FACT_PAYMENT_ATTEMPT','payment attempt','COUNT(*)',NULL,'is_valid_record','attempt_created_at_ist (date)','Asia/Kolkata','n/a','Every retry is a separate attempt','Reversed attempts still count as attempts','Payments Product'),
  ('SUCCESSFUL_PAYMENT_COUNT','Transactions whose final status is CAPTURED','CORE.FACT_PAYMENT_TRANSACTION','payment transaction','COUNT(*) WHERE final_status = CAPTURED',NULL,'final_status = CAPTURED','first_captured_at_ist','Asia/Kolkata','n/a','Retries collapse into one transaction','Reversed excluded','Payments Product'),
  ('PAYMENT_SUCCESS_RATE','Share of payment transactions that end CAPTURED','CORE.FACT_PAYMENT_TRANSACTION','payment transaction','COUNT WHERE final_status = CAPTURED','COUNT WHERE final_status in terminal statuses','exclude in-progress (CREATED/PENDING/AUTHORIZED)','transaction_created_at_ist','Asia/Kolkata','n/a','Transaction-level: a retry that succeeds counts as success','REVERSED/VOIDED counted in denominator, not numerator','Payments Product'),
  ('PAYMENT_FAILURE_RATE','Share of terminal payment transactions ending FAILED','CORE.FACT_PAYMENT_TRANSACTION','payment transaction','COUNT WHERE final_status = FAILED','COUNT WHERE terminal','exclude in-progress','transaction_created_at_ist','Asia/Kolkata','n/a','Transaction-level','Reversals are neither success nor failure','Payments Product'),
  ('AVERAGE_TRANSACTION_VALUE','Average captured value per successful transaction','CORE.FACT_PAYMENT_TRANSACTION','payment transaction','PAYMENT_VOLUME','SUCCESSFUL_PAYMENT_COUNT','final_status = CAPTURED','first_captured_at_ist','Asia/Kolkata','INR','Retries collapsed','Reversed excluded','Payments Product'),
  ('REFUND_AMOUNT','Value of processed refunds','CORE.FACT_REFUND','refund','SUM(refund_amount_inr) WHERE refund_status = REFUND_PROCESSED',NULL,'refund_status = REFUND_PROCESSED','refund_requested_at_ist','Asia/Kolkata','INR at month of request','n/a','REFUND_REVERSED excluded','Finance Ops'),
  ('REFUND_RATE','Processed refund value as share of payment volume','CORE.FACT_REFUND / CORE.FACT_PAYMENT_TRANSACTION','month x merchant','REFUND_AMOUNT','PAYMENT_VOLUME','aggregated separately then divided (no fact-to-fact join)','respective reporting dates','Asia/Kolkata','INR','n/a','see components','Finance Ops'),
  ('CHARGEBACK_AMOUNT','Value of chargebacks lost by merchants','CORE.FACT_CHARGEBACK','chargeback','SUM(chargeback_amount_inr) WHERE canonical_status = CB_LOST',NULL,'CB_LOST','received_date','Asia/Kolkata','INR','n/a','CB_WON excluded','Risk'),
  ('CHARGEBACK_RATE','Chargeback count per successful transaction','CORE.FACT_CHARGEBACK / CORE.FACT_PAYMENT_TRANSACTION','month x merchant','COUNT(chargebacks received)','SUCCESSFUL_PAYMENT_COUNT','aggregated separately','received_date','Asia/Kolkata','n/a','n/a','n/a','Risk'),
  ('SETTLEMENT_MATCH_RATE','Share of settleable transactions fully matched to settlement','MARTS.MART_SETTLEMENT_RECONCILIATION','captured payment attempt','COUNT WHERE recon_status = MATCHED','COUNT WHERE recon_status <> NOT_APPLICABLE','captured attempts only','captured_date_ist','Asia/Kolkata','Compared in transaction currency','Only the capturing attempt is settleable','Reversed = NOT_APPLICABLE','Finance Ops'),
  ('OUTSTANDING_SETTLEMENT_AMOUNT','Captured value not yet settled (gross basis)','MARTS.MART_SETTLEMENT_RECONCILIATION','captured payment attempt','SUM(GREATEST(expected_gross_inr - settled_gross_inr, 0))',NULL,'recon_status in (UNSETTLED, PENDING_SETTLEMENT, PARTIALLY_SETTLED, AMOUNT_MISMATCH)','captured_date_ist','Asia/Kolkata','INR','n/a','Reversed excluded','Finance Ops'),
  ('FRAUD_ALERT_COUNT','Fraud alerts raised (vendor + platform rules)','CORE.FACT_FRAUD_ALERT','alert','COUNT(*)',NULL,'all statuses','alert_at_ist','Asia/Kolkata','n/a','n/a','n/a','Risk')
  AS s(METRIC_NAME,BUSINESS_MEANING,AUTHORITATIVE_MODEL,GRAIN,NUMERATOR,DENOMINATOR,FILTERS,REPORTING_TIMESTAMP,TIMEZONE,CURRENCY_TREATMENT,RETRY_HANDLING,REVERSAL_TREATMENT,OWNER)
) s ON t.METRIC_NAME=s.METRIC_NAME
WHEN NOT MATCHED THEN INSERT (METRIC_NAME,BUSINESS_MEANING,AUTHORITATIVE_MODEL,GRAIN,NUMERATOR,DENOMINATOR,FILTERS,REPORTING_TIMESTAMP,TIMEZONE,CURRENCY_TREATMENT,RETRY_HANDLING,REVERSAL_TREATMENT,OWNER)
VALUES (s.METRIC_NAME,s.BUSINESS_MEANING,s.AUTHORITATIVE_MODEL,s.GRAIN,s.NUMERATOR,s.DENOMINATOR,s.FILTERS,s.REPORTING_TIMESTAMP,s.TIMEZONE,s.CURRENCY_TREATMENT,s.RETRY_HANDLING,s.REVERSAL_TREATMENT,s.OWNER);

-- Fact grain + materialisation registry (architecture metadata) --------
CREATE TABLE IF NOT EXISTS CONFIG.MODEL_REGISTRY (
    MODEL_NAME       VARCHAR(200) PRIMARY KEY,
    LAYER            VARCHAR(30),
    GRAIN            VARCHAR(500),
    BUSINESS_KEY     VARCHAR(500),
    SURROGATE_KEY    VARCHAR(200),
    MATERIALIZATION  VARCHAR(30),
    CHANGE_CLASS     VARCHAR(20) COMMENT 'RUNTIME (config) | DEPLOYMENT (code)'
);
MERGE INTO CONFIG.MODEL_REGISTRY t USING (
  SELECT * FROM VALUES
   ('FACT_PAYMENT_ATTEMPT','CORE','one row per provider attempt (source_system, source_transaction_id)','source_system+source_transaction_id','attempt_key','incremental(merge)','DEPLOYMENT'),
   ('FACT_PAYMENT_TRANSACTION','CORE','one row per merchant order (merchant_id, merchant_order_id)','merchant_id+merchant_order_id','transaction_key','table','DEPLOYMENT'),
   ('FACT_REFUND','CORE','one row per refund','refund_id','refund_key','table','DEPLOYMENT'),
   ('FACT_SETTLEMENT_EVENT','CORE','one row per settlement report line','settlement_line_id','settlement_event_key','incremental(merge)','DEPLOYMENT'),
   ('FACT_CHARGEBACK','CORE','one row per chargeback','chargeback_id','chargeback_key','table','DEPLOYMENT'),
   ('FACT_FRAUD_ALERT','CORE','one row per alert (vendor or platform rule)','alert_id','fraud_alert_key','table','DEPLOYMENT'),
   ('DIM_CUSTOMER','CORE','one row per customer per KYC/risk version (SCD2)','customer_id+valid_from','customer_key','table','DEPLOYMENT'),
   ('DIM_MERCHANT','CORE','one row per merchant per version (snapshot SCD2)','merchant_id+valid_from','merchant_key','table','DEPLOYMENT'),
   ('DIM_PAYMENT_CHANNEL','CORE','one row per canonical channel','channel_code','channel_key','table','DEPLOYMENT'),
   ('DIM_CURRENCY','CORE','one row per ISO currency','currency_code','currency_key','table','DEPLOYMENT'),
   ('DIM_DATE','CORE','one row per calendar date','date_day','date_key','table','DEPLOYMENT')
  AS s(MODEL_NAME,LAYER,GRAIN,BUSINESS_KEY,SURROGATE_KEY,MATERIALIZATION,CHANGE_CLASS)
) s ON t.MODEL_NAME=s.MODEL_NAME
WHEN NOT MATCHED THEN INSERT VALUES (s.MODEL_NAME,s.LAYER,s.GRAIN,s.BUSINESS_KEY,s.SURROGATE_KEY,s.MATERIALIZATION,s.CHANGE_CLASS);

-- Which config table feeds which model/metric (impact analysis seed) ---
CREATE TABLE IF NOT EXISTS CONFIG.CONFIG_IMPACT_MAP (
    CONFIG_TABLE   VARCHAR(100) NOT NULL,
    IMPACTED_NODE  VARCHAR(200) NOT NULL COMMENT 'dbt model name or metric name',
    NODE_TYPE      VARCHAR(20)  NOT NULL COMMENT 'MODEL | METRIC | PROCEDURE',
    CONSTRAINT PK_IMPACT PRIMARY KEY (CONFIG_TABLE, IMPACTED_NODE)
);
MERGE INTO CONFIG.CONFIG_IMPACT_MAP t USING (
  SELECT * FROM VALUES
   ('STATUS_MAPPING','cnl_payment_attempt','MODEL'),('STATUS_MAPPING','cnl_payment_event','MODEL'),
   ('STATUS_MAPPING','cnl_refund_event','MODEL'),('STATUS_MAPPING','cnl_chargeback','MODEL'),
   ('STATUS_MAPPING','cnl_exceptions','MODEL'),
   ('STATUS_MAPPING','PAYMENT_SUCCESS_RATE','METRIC'),('STATUS_MAPPING','PAYMENT_FAILURE_RATE','METRIC'),
   ('STATUS_MAPPING','PAYMENT_VOLUME','METRIC'),
   ('RECON_TOLERANCE','mart_settlement_reconciliation','MODEL'),('RECON_TOLERANCE','mart_bank_reconciliation','MODEL'),
   ('RECON_TOLERANCE','SETTLEMENT_MATCH_RATE','METRIC'),('RECON_TOLERANCE','OUTSTANDING_SETTLEMENT_AMOUNT','METRIC'),
   ('FRAUD_THRESHOLD','int_customer_velocity','MODEL'),('FRAUD_THRESHOLD','fact_fraud_alert','MODEL'),
   ('FRAUD_THRESHOLD','FRAUD_ALERT_COUNT','METRIC'),
   ('DQ_RULE','OPS.SP_RUN_DQ_RULES','PROCEDURE'),
   ('BANK_NARRATIVE_PATTERN','stg_bank_statement_transactions','MODEL')
  AS s(CONFIG_TABLE,IMPACTED_NODE,NODE_TYPE)
) s ON t.CONFIG_TABLE=s.CONFIG_TABLE AND t.IMPACTED_NODE=s.IMPACTED_NODE
WHEN NOT MATCHED THEN INSERT VALUES (s.CONFIG_TABLE,s.IMPACTED_NODE,s.NODE_TYPE);

-- Known-answer test expectations (filled by 05_edge_cases.sql) ---------
CREATE TABLE IF NOT EXISTS CONFIG.EXPECTED_TEST_OUTCOME (
    TEST_CASE_ID     VARCHAR(20)  NOT NULL,
    DESCRIPTION      VARCHAR(300),
    CHECK_TYPE       VARCHAR(40)  NOT NULL COMMENT 'PAYMENT_RECON_STATUS | BATCH_RECON_STATUS | ATTEMPT_COUNT | FINAL_STATUS | REFUND_TOTAL | EXCEPTION_TYPE | KYC_VERSIONS | DEDUP_COUNT',
    ENTITY_KEY       VARCHAR(200) NOT NULL,
    EXPECTED_VALUE   VARCHAR(200) NOT NULL,
    CONSTRAINT PK_EXPECTED PRIMARY KEY (TEST_CASE_ID, CHECK_TYPE, ENTITY_KEY)
);
