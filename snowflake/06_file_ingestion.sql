/* =====================================================================
   06_FILE_INGESTION.SQL
   File formats, internal stages, COPY INTO with schema validation and
   rejected-record capture, and promotion of provider landing tables.

   Ways to get externally generated CSVs into the stage (all native):
     a) Snowsight: Data > Add Data > Load files into a Stage
        (choose database, schema OPS, stage STG_INBOUND, path /payments/prov_a/)
     b) Snowsight: Data > Databases > <db> > OPS > Stages > STG_INBOUND > + Files
     c) Snowflake CLI / SnowSQL (developer machine or CI):
          snow stage copy ./data/prov_a_payments.csv @OPS.STG_INBOUND/payments/prov_a/
          PUT file://./data/prov_a_payments.csv @OPS.STG_INBOUND/payments/prov_a/ AUTO_COMPRESS=TRUE;
   Then run the COPY / CALL statements below (or let TSK_INGEST_FILES do it).
   ===================================================================== */
USE ROLE FINTECH_DEPLOYER;
USE DATABASE FINTECH_DEV;
USE WAREHOUSE WH_FINTECH_LOAD;
USE SCHEMA OPS;

-- File formats ------------------------------------------------------------
CREATE FILE FORMAT IF NOT EXISTS OPS.FF_CSV_HEADER
  TYPE = CSV
  FIELD_DELIMITER = ','
  SKIP_HEADER = 1
  FIELD_OPTIONALLY_ENCLOSED_BY = '"'
  NULL_IF = ('', 'NULL', 'null')
  EMPTY_FIELD_AS_NULL = TRUE
  TRIM_SPACE = TRUE
  ERROR_ON_COLUMN_COUNT_MISMATCH = TRUE      -- schema validation: wrong column count is a reject
  ENCODING = 'UTF8'
  COMMENT = 'Standard inbound CSV with header row';

-- PARSE_HEADER variant for INFER_SCHEMA based header validation
CREATE FILE FORMAT IF NOT EXISTS OPS.FF_CSV_PARSE_HEADER
  TYPE = CSV PARSE_HEADER = TRUE FIELD_OPTIONALLY_ENCLOSED_BY = '"'
  NULL_IF = ('', 'NULL') TRIM_SPACE = TRUE
  COMMENT = 'Used only to inspect headers with INFER_SCHEMA';

-- Internal stage (server-side encrypted, directory table for file listing)
CREATE STAGE IF NOT EXISTS OPS.STG_INBOUND
  FILE_FORMAT = OPS.FF_CSV_HEADER
  ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE')
  DIRECTORY = (ENABLE = TRUE)
  COMMENT = 'Inbound provider files. Layout: /payments/prov_a|prov_b|prov_c/, /refunds/, /settlements/, /bank_statements/, ...';

/* ---------------------------------------------------------------------
   Expected header contract per landing table (schema validation)
   --------------------------------------------------------------------- */
CREATE TABLE IF NOT EXISTS CONFIG.FILE_CONTRACT (
    STAGE_PATH      VARCHAR(200) PRIMARY KEY,
    TARGET_TABLE    VARCHAR(200) NOT NULL,
    EXPECTED_HEADER VARCHAR(4000) NOT NULL COMMENT 'Comma separated column names, in order'
);
MERGE INTO CONFIG.FILE_CONTRACT t USING (
  SELECT * FROM VALUES
   ('payments/prov_a/','LANDING.PAYMENTS_PROV_A','TXN_REF,ORDER_ID,MERCHANT_CODE,CUST_ID,AMT,CCY,TXN_STATUS,TXN_TIME,CHANNEL,VPA_TOKEN,DEVICE_ID'),
   ('payments/prov_b/','LANDING.PAYMENTS_PROV_B','PAYMENT_ID,MERCHANT_REFERENCE,MERCHANT_ID,CUSTOMER_ID,PAYMENT_AMOUNT,CURRENCY,STATE,CREATED_AT_MS,METHOD,CARD_TOKEN,CARD_LAST4,CARD_NETWORK'),
   ('payments/prov_c/','LANDING.PAYMENTS_PROV_C','REFERENCE_NO,CUSTOMER_REF,MERCHANT_REF,PAYER_ID,AMOUNT_VALUE,CURRENCY_CODE,STATUS_CODE,VALUE_TS,RAIL,ACCOUNT_TOKEN'),
   ('refunds/','RAW.REFUNDS','REFUND_ID,SOURCE_SYSTEM,SOURCE_TRANSACTION_ID,REFUND_AMOUNT,CURRENCY_CODE,REFUND_TYPE,REFUND_REASON,REQUESTED_AT'),
   ('settlements/','RAW.BANK_SETTLEMENTS','SETTLEMENT_LINE_ID,SETTLEMENT_BATCH_ID,SOURCE_SYSTEM,SOURCE_TRANSACTION_ID,MERCHANT_ID,SETTLEMENT_TYPE,IS_FINAL_SETTLEMENT,GROSS_AMOUNT,FEE_AMOUNT,TAX_AMOUNT,NET_AMOUNT,CURRENCY_CODE,SETTLEMENT_DATE'),
   ('bank_statements/','RAW.BANK_STATEMENT_TRANSACTIONS','BANK_TXN_ID,BANK_CODE,BANK_ACCOUNT_TOKEN,VALUE_DATE,POSTING_TS,DR_CR,AMOUNT,CURRENCY_CODE,NARRATIVE')
  AS s(STAGE_PATH,TARGET_TABLE,EXPECTED_HEADER)
) s ON t.STAGE_PATH = s.STAGE_PATH
WHEN MATCHED THEN UPDATE SET TARGET_TABLE = s.TARGET_TABLE, EXPECTED_HEADER = s.EXPECTED_HEADER
WHEN NOT MATCHED THEN INSERT VALUES (s.STAGE_PATH, s.TARGET_TABLE, s.EXPECTED_HEADER);

/* ---------------------------------------------------------------------
   Manual examples (run interactively in a Snowsight SQL file)
   --------------------------------------------------------------------- */
-- 1. Inspect file headers before loading (schema validation)
-- SELECT COLUMN_NAME, TYPE, ORDER_ID
-- FROM TABLE(INFER_SCHEMA(LOCATION => '@OPS.STG_INBOUND/payments/prov_a/', FILE_FORMAT => 'OPS.FF_CSV_PARSE_HEADER'))
-- ORDER BY ORDER_ID;

-- 2. Dry run: report every error without loading
-- COPY INTO LANDING.PAYMENTS_PROV_A (TXN_REF,ORDER_ID,MERCHANT_CODE,CUST_ID,AMT,CCY,TXN_STATUS,TXN_TIME,CHANNEL,VPA_TOKEN,DEVICE_ID)
-- FROM @OPS.STG_INBOUND/payments/prov_a/
-- VALIDATION_MODE = RETURN_ERRORS;

-- 3. Real load with file metadata
-- COPY INTO LANDING.PAYMENTS_PROV_A
--   (TXN_REF,ORDER_ID,MERCHANT_CODE,CUST_ID,AMT,CCY,TXN_STATUS,TXN_TIME,CHANNEL,VPA_TOKEN,DEVICE_ID,_FILE_NAME,_FILE_ROW)
-- FROM (SELECT $1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11, METADATA$FILENAME, METADATA$FILE_ROW_NUMBER
--       FROM @OPS.STG_INBOUND/payments/prov_a/)
-- ON_ERROR = CONTINUE;
-- -- rejected rows of the COPY just executed:
-- SELECT * FROM TABLE(VALIDATE(LANDING.PAYMENTS_PROV_A, JOB_ID => '_last'));

/* ---------------------------------------------------------------------
   SP_LOAD_STAGE_PATH: header check + COPY + reject capture + audit
   --------------------------------------------------------------------- */
CREATE OR REPLACE PROCEDURE OPS.SP_LOAD_STAGE_PATH(P_STAGE_PATH VARCHAR, P_BATCH_ID VARCHAR)
RETURNS VARIANT
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
    v_target   VARCHAR;
    v_expected VARCHAR;
    v_actual   VARCHAR;
    v_cols     VARCHAR;
    v_select   VARCHAR;
    v_copy     VARCHAR;
    v_qid      VARCHAR;
    v_loaded   NUMBER DEFAULT 0;
    v_errors   NUMBER DEFAULT 0;
    v_started  TIMESTAMP_NTZ DEFAULT SYSDATE();
    v_is_landing BOOLEAN;
BEGIN
    SELECT TARGET_TABLE, EXPECTED_HEADER INTO :v_target, :v_expected
    FROM CONFIG.FILE_CONTRACT WHERE STAGE_PATH = :P_STAGE_PATH;

    -- 1) Schema validation: compare inferred header with the contract
    v_actual := (SELECT LISTAGG(UPPER(COLUMN_NAME), ',') WITHIN GROUP (ORDER BY ORDER_ID)
                 FROM TABLE(INFER_SCHEMA(LOCATION => '@OPS.STG_INBOUND/' || :P_STAGE_PATH,
                                         FILE_FORMAT => 'OPS.FF_CSV_PARSE_HEADER')));
    IF (v_actual IS NULL) THEN
        INSERT INTO AUDIT.INGESTION_LOG (BATCH_ID, TARGET_TABLE, LOAD_METHOD, ROWS_LOADED, ROWS_REJECTED, STATUS, MESSAGE, STARTED_AT)
        VALUES (:P_BATCH_ID, :v_target, 'COPY_INTO', 0, 0, 'SUCCESS', 'No files in ' || :P_STAGE_PATH, :v_started);
        RETURN OBJECT_CONSTRUCT('status','NO_FILES');
    END IF;
    IF (v_actual <> UPPER(v_expected)) THEN
        INSERT INTO AUDIT.INGESTION_LOG (BATCH_ID, TARGET_TABLE, LOAD_METHOD, ROWS_LOADED, ROWS_REJECTED, STATUS, MESSAGE, STARTED_AT)
        VALUES (:P_BATCH_ID, :v_target, 'COPY_INTO', 0, 0, 'FAILED',
                'Header mismatch. expected=' || :v_expected || ' actual=' || :v_actual, :v_started);
        RETURN OBJECT_CONSTRUCT('status','FAILED','reason','HEADER_MISMATCH','expected',v_expected,'actual',v_actual);
    END IF;

    -- 2) Build COPY: positional columns + file metadata (+ batch id for RAW tables)
    v_is_landing := STARTSWITH(v_target, 'LANDING.');
    v_cols   := v_expected;
    v_select := (SELECT LISTAGG('$' || SEQ, ',') WITHIN GROUP (ORDER BY SEQ)
                 FROM (SELECT ROW_NUMBER() OVER (ORDER BY INDEX) AS SEQ
                       FROM TABLE(FLATTEN(INPUT => SPLIT(:v_expected, ',')))));
    IF (v_is_landing) THEN
        v_copy := 'COPY INTO ' || v_target || ' (' || v_cols || ',_FILE_NAME,_FILE_ROW) FROM (SELECT ' || v_select ||
                  ', METADATA$FILENAME, METADATA$FILE_ROW_NUMBER FROM @OPS.STG_INBOUND/' || P_STAGE_PATH ||
                  ') ON_ERROR = CONTINUE';
    ELSE
        v_copy := 'COPY INTO ' || v_target || ' (' || v_cols || ',SOURCE_FILE_NAME,BATCH_ID) FROM (SELECT ' || v_select ||
                  ', METADATA$FILENAME, ''' || REPLACE(P_BATCH_ID, '''', '') || ''' FROM @OPS.STG_INBOUND/' || P_STAGE_PATH ||
                  ') ON_ERROR = CONTINUE';
    END IF;
    EXECUTE IMMEDIATE :v_copy;
    v_qid := LAST_QUERY_ID();

    SELECT COALESCE(SUM("rows_loaded"), 0), COALESCE(SUM("errors_seen"), 0) INTO :v_loaded, :v_errors
    FROM TABLE(RESULT_SCAN(:v_qid));

    -- 3) Rejected records (from the COPY job just executed)
    IF (v_errors > 0) THEN
        EXECUTE IMMEDIATE
          'INSERT INTO AUDIT.INGESTION_REJECTS (BATCH_ID, TARGET_TABLE, SOURCE_FILE_NAME, ROW_NUMBER, COLUMN_NAME, ERROR_CODE, ERROR_MESSAGE, REJECTED_RECORD) ' ||
          'SELECT ''' || REPLACE(P_BATCH_ID, '''', '') || ''', ''' || v_target || ''', FILE, ROW_NUMBER, COLUMN_NAME, CODE, ERROR, REJECTED_RECORD ' ||
          'FROM TABLE(VALIDATE(' || v_target || ', JOB_ID => ''' || v_qid || '''))';
    END IF;

    INSERT INTO AUDIT.INGESTION_LOG (BATCH_ID, TARGET_TABLE, LOAD_METHOD, SOURCE_FILE_NAME, ROWS_LOADED, ROWS_REJECTED, STATUS, MESSAGE, STARTED_AT)
    VALUES (:P_BATCH_ID, :v_target, 'COPY_INTO', :P_STAGE_PATH, :v_loaded, :v_errors,
            IFF(:v_errors = 0, 'SUCCESS', 'PARTIAL'), 'copy_query_id=' || :v_qid, :v_started);

    RETURN OBJECT_CONSTRUCT('status', IFF(v_errors = 0, 'SUCCESS', 'PARTIAL'), 'target', v_target,
                            'rows_loaded', v_loaded, 'rows_rejected', v_errors, 'query_id', v_qid);
EXCEPTION
    WHEN OTHER THEN
        INSERT INTO AUDIT.PROCEDURE_LOG (PROCEDURE_NAME, RUN_ID, STEP, STATUS, MESSAGE)
        VALUES ('SP_LOAD_STAGE_PATH', :P_BATCH_ID, :P_STAGE_PATH, 'FAILED', :SQLCODE || ' ' || :SQLERRM);
        RAISE;
END;
$$;

/* ---------------------------------------------------------------------
   SP_PROMOTE_LANDING_PAYMENTS: landing (provider layout) -> RAW.PAYMENTS
   OBJECT_CONSTRUCT(*) turns any provider layout into a VARIANT payload,
   so onboarding a provider needs no change here.
   --------------------------------------------------------------------- */
CREATE OR REPLACE PROCEDURE OPS.SP_PROMOTE_LANDING_PAYMENTS(P_SOURCE_SYSTEM VARCHAR, P_BATCH_ID VARCHAR)
RETURNS VARIANT
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
    v_landing VARCHAR DEFAULT 'LANDING.PAYMENTS_' || P_SOURCE_SYSTEM;
    v_sql     VARCHAR;
    v_rows    NUMBER;
BEGIN
    -- guard against SQL injection: source system must be registered
    LET v_known NUMBER := (SELECT COUNT(*) FROM CONFIG.SOURCE_SYSTEM WHERE SOURCE_SYSTEM = :P_SOURCE_SYSTEM AND IS_ACTIVE);
    IF (v_known = 0) THEN
        RETURN OBJECT_CONSTRUCT('status','FAILED','reason','Unknown or inactive source system');
    END IF;
    v_sql := 'INSERT INTO RAW.PAYMENTS (SOURCE_SYSTEM, SOURCE_RECORD, RECORD_HASH, SOURCE_FILE_NAME, SOURCE_FILE_ROW, BATCH_ID) ' ||
             'SELECT ''' || P_SOURCE_SYSTEM || ''', rec, SHA2(''' || P_SOURCE_SYSTEM || ''' || TO_JSON(rec)), fname, frow, ''' ||
             REPLACE(P_BATCH_ID, '''', '') || ''' FROM (' ||
             'SELECT OBJECT_DELETE(OBJECT_CONSTRUCT(*), ''_FILE_NAME'', ''_FILE_ROW'', ''_LOADED_AT'') AS rec, ' ||
             '       _FILE_NAME AS fname, _FILE_ROW AS frow FROM ' || v_landing || ')';
    -- Keys arrive UPPERCASE from landing columns; dbt reads payload keys with
    -- GET_IGNORE_CASE, so synthetic (lowercase) and file (uppercase) payloads
    -- are handled by the same mapping.
    EXECUTE IMMEDIATE :v_sql;
    v_rows := SQLROWCOUNT;
    EXECUTE IMMEDIATE 'TRUNCATE TABLE ' || v_landing;
    INSERT INTO AUDIT.INGESTION_LOG (BATCH_ID, TARGET_TABLE, LOAD_METHOD, ROWS_LOADED, ROWS_REJECTED, STATUS, MESSAGE)
    VALUES (:P_BATCH_ID, 'RAW.PAYMENTS', 'PROMOTE_LANDING', :v_rows, 0, 'SUCCESS', 'from ' || :v_landing);
    RETURN OBJECT_CONSTRUCT('status','SUCCESS','rows',v_rows);
END;
$$;

-- Example end-to-end for one provider file:
-- CALL OPS.SP_LOAD_STAGE_PATH('payments/prov_a/', 'FILE-20260410-01');
-- CALL OPS.SP_PROMOTE_LANDING_PAYMENTS('PROV_A', 'FILE-20260410-01');
-- REMOVE @OPS.STG_INBOUND/payments/prov_a/;   -- after successful load (COPY also skips already-loaded files for 64 days)
