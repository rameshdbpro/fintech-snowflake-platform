/* =====================================================================
   07_INGESTION_CONTROLS_AND_DQ.SQL
   Runtime controls on RAW (before dbt):
     * OPS.SP_RUN_INGESTION_CONTROLS : consumes RAW streams, records batch
       arrivals, row counts, control totals and duplicate deliveries.
     * OPS.SP_RUN_DQ_RULES           : executes CONFIG.DQ_RULE (metadata-driven).
   dbt tests (schema.yml + tests/) cover STAGING..MARTS. Both write to
   AUDIT.DQ_RESULTS so DASHBOARD.VW_DATA_QUALITY_STATUS has one picture.
   Requires streams from 09_streams_tasks.sql (create 09 before CALLing).
   ===================================================================== */
USE ROLE FINTECH_DEPLOYER;
USE DATABASE FINTECH_DEV;
USE WAREHOUSE WH_FINTECH_LOAD;

CREATE TABLE IF NOT EXISTS AUDIT.RAW_ARRIVALS (
    TARGET_TABLE   VARCHAR(200),
    BATCH_ID       VARCHAR(100),
    ROWS_ARRIVED   NUMBER(38,0),
    FIRST_INGESTED TIMESTAMP_NTZ,
    LAST_INGESTED  TIMESTAMP_NTZ,
    DETECTED_AT    TIMESTAMP_NTZ DEFAULT SYSDATE(),
    CONTROLLED     BOOLEAN DEFAULT FALSE
);

CREATE OR REPLACE PROCEDURE OPS.SP_RUN_INGESTION_CONTROLS()
RETURNS VARIANT
LANGUAGE SQL
EXECUTE AS OWNER
COMMENT = 'Consumes RAW append-only streams; writes arrivals, control totals and duplicates to AUDIT.'
AS
$$
DECLARE
    v_run VARCHAR DEFAULT 'CTRL-' || TO_VARCHAR(SYSDATE(), 'YYYYMMDDHH24MISS');
    v_arrivals NUMBER;
BEGIN
    -- 1) Consume streams (one transaction so offsets advance atomically)
    BEGIN TRANSACTION;
    INSERT INTO AUDIT.RAW_ARRIVALS (TARGET_TABLE, BATCH_ID, ROWS_ARRIVED, FIRST_INGESTED, LAST_INGESTED)
    SELECT 'RAW.PAYMENTS', BATCH_ID, COUNT(*), MIN(INGESTED_AT), MAX(INGESTED_AT) FROM OPS.STRM_RAW_PAYMENTS GROUP BY BATCH_ID
    UNION ALL
    SELECT 'RAW.PAYMENT_STATUS_HISTORY', BATCH_ID, COUNT(*), MIN(INGESTED_AT), MAX(INGESTED_AT) FROM OPS.STRM_RAW_PAYMENT_STATUS GROUP BY BATCH_ID
    UNION ALL
    SELECT 'RAW.BANK_SETTLEMENTS', BATCH_ID, COUNT(*), MIN(INGESTED_AT), MAX(INGESTED_AT) FROM OPS.STRM_RAW_SETTLEMENTS GROUP BY BATCH_ID
    UNION ALL
    SELECT 'RAW.BANK_STATEMENT_TRANSACTIONS', BATCH_ID, COUNT(*), MIN(INGESTED_AT), MAX(INGESTED_AT) FROM OPS.STRM_RAW_BANK_STATEMENT GROUP BY BATCH_ID;
    v_arrivals := SQLROWCOUNT;
    COMMIT;

    -- 2) Control totals for batches not yet controlled
    INSERT INTO AUDIT.CONTROL_TOTALS (BATCH_ID, CONTROL_POINT, OBJECT_NAME, CURRENCY_CODE, ROW_COUNT, AMOUNT_TOTAL)
    SELECT p.BATCH_ID, 'RAW_BATCH', 'RAW.PAYMENTS', NULL, COUNT(*), NULL
    FROM RAW.PAYMENTS p
    WHERE p.BATCH_ID IN (SELECT BATCH_ID FROM AUDIT.RAW_ARRIVALS WHERE TARGET_TABLE = 'RAW.PAYMENTS' AND NOT CONTROLLED)
    GROUP BY p.BATCH_ID
    UNION ALL
    SELECT s.BATCH_ID, 'RAW_BATCH', 'RAW.BANK_SETTLEMENTS', s.CURRENCY_CODE, COUNT(*), SUM(s.NET_AMOUNT)
    FROM RAW.BANK_SETTLEMENTS s
    WHERE s.BATCH_ID IN (SELECT BATCH_ID FROM AUDIT.RAW_ARRIVALS WHERE TARGET_TABLE = 'RAW.BANK_SETTLEMENTS' AND NOT CONTROLLED)
    GROUP BY s.BATCH_ID, s.CURRENCY_CODE
    UNION ALL
    SELECT b.BATCH_ID, 'RAW_BATCH', 'RAW.BANK_STATEMENT_TRANSACTIONS', b.CURRENCY_CODE, COUNT(*),
           SUM(IFF(b.DR_CR = 'CR', b.AMOUNT, -b.AMOUNT))
    FROM RAW.BANK_STATEMENT_TRANSACTIONS b
    WHERE b.BATCH_ID IN (SELECT BATCH_ID FROM AUDIT.RAW_ARRIVALS WHERE TARGET_TABLE = 'RAW.BANK_STATEMENT_TRANSACTIONS' AND NOT CONTROLLED)
    GROUP BY b.BATCH_ID, b.CURRENCY_CODE;

    -- 3) Duplicate deliveries (exact payload re-sent) - informational:
    --    staging dedups on RECORD_HASH, so these never double count.
    INSERT INTO AUDIT.DUPLICATE_LOG (TARGET_TABLE, DUPLICATE_KEY, OCCURRENCES, FIRST_BATCH_ID, LAST_BATCH_ID)
    SELECT 'RAW.PAYMENTS', RECORD_HASH, COUNT(*), MIN_BY(BATCH_ID, INGESTED_AT), MAX_BY(BATCH_ID, INGESTED_AT)
    FROM RAW.PAYMENTS
    WHERE RECORD_HASH IN (SELECT RECORD_HASH FROM RAW.PAYMENTS
                          WHERE BATCH_ID IN (SELECT BATCH_ID FROM AUDIT.RAW_ARRIVALS
                                             WHERE TARGET_TABLE = 'RAW.PAYMENTS' AND NOT CONTROLLED))
    GROUP BY RECORD_HASH HAVING COUNT(*) > 1
    UNION ALL
    SELECT 'RAW.PAYMENT_STATUS_HISTORY', SOURCE_SYSTEM || '|' || EVENT_ID, COUNT(*),
           MIN_BY(BATCH_ID, INGESTED_AT), MAX_BY(BATCH_ID, INGESTED_AT)
    FROM RAW.PAYMENT_STATUS_HISTORY
    WHERE BATCH_ID IN (SELECT BATCH_ID FROM AUDIT.RAW_ARRIVALS
                       WHERE TARGET_TABLE = 'RAW.PAYMENT_STATUS_HISTORY' AND NOT CONTROLLED)
       OR EVENT_ID IN (SELECT EVENT_ID FROM RAW.PAYMENT_STATUS_HISTORY
                       WHERE BATCH_ID IN (SELECT BATCH_ID FROM AUDIT.RAW_ARRIVALS
                                          WHERE TARGET_TABLE = 'RAW.PAYMENT_STATUS_HISTORY' AND NOT CONTROLLED))
    GROUP BY SOURCE_SYSTEM, EVENT_ID HAVING COUNT(*) > 1;

    UPDATE AUDIT.RAW_ARRIVALS SET CONTROLLED = TRUE WHERE NOT CONTROLLED;

    INSERT INTO AUDIT.PROCEDURE_LOG (PROCEDURE_NAME, RUN_ID, STEP, STATUS, ROWS_AFFECTED, MESSAGE)
    VALUES ('SP_RUN_INGESTION_CONTROLS', :v_run, 'END', 'SUCCESS', :v_arrivals, 'arrival groups consumed');
    RETURN OBJECT_CONSTRUCT('status','SUCCESS','arrival_groups',v_arrivals);
EXCEPTION
    WHEN OTHER THEN
        ROLLBACK;
        INSERT INTO AUDIT.PROCEDURE_LOG (PROCEDURE_NAME, RUN_ID, STEP, STATUS, MESSAGE)
        VALUES ('SP_RUN_INGESTION_CONTROLS', :v_run, 'ERROR', 'FAILED', :SQLCODE || ' ' || :SQLERRM);
        RAISE;
END;
$$;

/* ---------------------------------------------------------------------
   Metadata-driven DQ rules. Adding a rule = INSERT into CONFIG.DQ_RULE
   (runtime change, no deployment). Identifiers come only from config,
   and are validated with IDENTIFIER-safe pattern checks before use.
   --------------------------------------------------------------------- */
CREATE OR REPLACE PROCEDURE OPS.SP_RUN_DQ_RULES()
RETURNS VARIANT
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
    v_run   VARCHAR DEFAULT 'DQ-' || TO_VARCHAR(SYSDATE(), 'YYYYMMDDHH24MISS');
    v_sql   VARCHAR;
    v_obs   NUMBER;
    v_fail  NUMBER DEFAULT 0;
    v_total NUMBER DEFAULT 0;
    v_status VARCHAR;
    v_rule VARCHAR; v_table VARCHAR; v_type VARCHAR; v_col VARCHAR; v_thr NUMBER(18,4); v_sev VARCHAR;
    c1 CURSOR FOR SELECT RULE_ID, TARGET_TABLE, RULE_TYPE, COLUMN_NAME, THRESHOLD, SEVERITY
                  FROM CONFIG.DQ_RULE WHERE IS_ACTIVE;
BEGIN
    FOR r IN c1 DO
        -- copy record fields into variables (bind variables are used in SQL statements)
        v_rule := r.RULE_ID;  v_table := r.TARGET_TABLE;  v_type := r.RULE_TYPE;
        v_col  := r.COLUMN_NAME;  v_thr := r.THRESHOLD;  v_sev := r.SEVERITY;
        v_total := v_total + 1;
        v_obs := NULL;
        -- reject anything that is not a plain SCHEMA.TABLE / COLUMN identifier
        IF (NOT REGEXP_LIKE(v_table, '^[A-Z_]+\\.[A-Z0-9_]+$')
            OR (v_col IS NOT NULL AND NOT REGEXP_LIKE(v_col, '^[A-Z0-9_]+$'))) THEN
            v_status := 'ERROR';
        ELSE
            v_sql := CASE v_type
              WHEN 'NOT_NULL'        THEN 'SELECT COUNT(*) FROM ' || v_table || ' WHERE ' || v_col || ' IS NULL'
              WHEN 'NON_NEGATIVE'    THEN 'SELECT COUNT(*) FROM ' || v_table || ' WHERE ' || v_col || ' < 0'
              WHEN 'ROW_COUNT_MIN'   THEN 'SELECT COUNT(*) FROM ' || v_table
              WHEN 'FRESHNESS_HOURS' THEN 'SELECT COALESCE(DATEDIFF(hour, MAX(' || v_col || '), SYSDATE()), 999999) FROM ' || v_table
              WHEN 'DUPLICATE_KEY'   THEN 'SELECT COUNT(*) FROM (SELECT ' || v_col || ' FROM ' || v_table ||
                                          ' GROUP BY 1 HAVING COUNT(*) > 1)'
            END;
            EXECUTE IMMEDIATE :v_sql;
            SELECT $1 INTO :v_obs FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));
            v_status := CASE
              WHEN v_type = 'ROW_COUNT_MIN'   AND v_obs <  v_thr THEN IFF(v_sev = 'WARN','WARN','FAIL')
              WHEN v_type = 'FRESHNESS_HOURS' AND v_obs >  v_thr THEN IFF(v_sev = 'WARN','WARN','FAIL')
              WHEN v_type IN ('NOT_NULL','NON_NEGATIVE','DUPLICATE_KEY') AND v_obs > v_thr
                                                                   THEN IFF(v_sev = 'WARN','WARN','FAIL')
              ELSE 'PASS' END;
        END IF;
        IF (v_status IN ('FAIL','ERROR')) THEN v_fail := v_fail + 1; END IF;
        INSERT INTO AUDIT.DQ_RESULTS (DQ_RUN_ID, RULE_ID, CHECK_SOURCE, TARGET_OBJECT, RULE_TYPE, SEVERITY, STATUS,
                                      FAILING_ROWS, OBSERVED_VALUE, THRESHOLD, DETAILS)
        VALUES (:v_run, :v_rule, 'RUNTIME_RULE', :v_table, :v_type, :v_sev, :v_status,
                IFF(:v_type IN ('NOT_NULL','NON_NEGATIVE','DUPLICATE_KEY'), :v_obs, NULL),
                TO_VARCHAR(:v_obs), TO_VARCHAR(:v_thr), :v_col);
    END FOR;

    INSERT INTO AUDIT.PROCEDURE_LOG (PROCEDURE_NAME, RUN_ID, STEP, STATUS, ROWS_AFFECTED, MESSAGE)
    VALUES ('SP_RUN_DQ_RULES', :v_run, 'END', IFF(:v_fail = 0, 'SUCCESS', 'WARN'), :v_total, :v_fail || ' failing rules');
    RETURN OBJECT_CONSTRUCT('run_id', v_run, 'rules', v_total, 'failing', v_fail);
END;
$$;
