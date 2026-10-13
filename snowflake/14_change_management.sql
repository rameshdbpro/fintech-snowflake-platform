/* =====================================================================
   14_CHANGE_MANAGEMENT.SQL  -  configuration-driven architecture changes

   Two classes of change (CONFIG.MODEL_REGISTRY.CHANGE_CLASS):
   RUNTIME (this workflow, no code deployment; effect on next dbt build or
            immediately for procedures that read config at run time)
       STATUS_MAPPING_UPSERT, RECON_TOLERANCE_UPDATE, FRAUD_THRESHOLD_UPDATE,
       DQ_RULE_UPSERT, ROW_ACCESS_MAP_UPSERT
   DEPLOYMENT (rejected here with guidance; go through Git PR + CI + dbt deploy)
       new provider field mapping (dbt vars.payment_providers), new/changed
       models, grains, materialisations, metric formulas, semantic view DDL.

   Lifecycle (every step writes AUDIT.CHANGE_LOG)
     1 SUBMIT    OPS.SP_SUBMIT_CHANGE(type, payload, justification)
     2 VALIDATE  OPS.SP_VALIDATE_CHANGE(id)   rules + impact analysis + generated SQL + rollback SQL
     3 PREVIEW   OPS.SP_PREVIEW_CHANGE(id)    before/after rows, impacted models/metrics, SQL
     4 APPROVE   OPS.SP_APPROVE_CHANGE(id)    FINTECH_CONFIG_APPROVER only, approver <> requester
     5 APPLY     OPS.SP_APPLY_CHANGE(id)      KPI BEFORE snapshot + executes exactly the approved SQL
     6 BUILD     dbt build -s <impacted models>+   (command returned by APPLY; run from CI)
     7 VERIFY    OPS.SP_VERIFY_CHANGE(id)     KPI AFTER snapshot + before/after comparison
     8 ROLLBACK  OPS.SP_ROLLBACK_CHANGE(id)   executes stored rollback SQL, then rebuild (step 6)
   ===================================================================== */
USE ROLE FINTECH_DEPLOYER;
SET DB_NAME = 'FINTECH_DEV';
USE DATABASE IDENTIFIER($DB_NAME);
USE WAREHOUSE WH_FINTECH_LOAD;
USE SCHEMA OPS;

CREATE TABLE IF NOT EXISTS CONFIG.CHANGE_REQUEST (
    CHANGE_ID          VARCHAR(100) DEFAULT 'CR-' || TO_VARCHAR(SYSDATE(), 'YYYYMMDDHH24MISSFF3'),
    CHANGE_TYPE        VARCHAR(50)  NOT NULL,
    TARGET_TABLE       VARCHAR(200),
    PAYLOAD            VARIANT      NOT NULL,
    JUSTIFICATION      VARCHAR(2000),
    STATUS             VARCHAR(20)  DEFAULT 'DRAFT' COMMENT 'DRAFT|VALIDATED|REJECTED|APPROVED|APPLIED|VERIFIED|ROLLED_BACK',
    VALIDATION_RESULT  VARIANT,
    IMPACT             VARIANT,
    BEFORE_IMAGE       VARIANT,
    GENERATED_SQL      VARCHAR(16000),
    ROLLBACK_SQL       VARCHAR(16000),
    REQUESTED_BY       VARCHAR(100) DEFAULT CURRENT_USER(),
    REQUESTED_AT       TIMESTAMP_NTZ DEFAULT SYSDATE(),
    APPROVED_BY        VARCHAR(100),
    APPROVED_AT        TIMESTAMP_NTZ,
    APPLIED_AT         TIMESTAMP_NTZ,
    VERIFIED_AT        TIMESTAMP_NTZ,
    CONSTRAINT PK_CHANGE_REQUEST PRIMARY KEY (CHANGE_ID)
);

-- SQL literal helper (NULL-safe, quote-escaped) used to build reviewed SQL text
CREATE OR REPLACE FUNCTION OPS.SQL_LIT(V VARIANT)
RETURNS VARCHAR
IMMUTABLE
AS $$
  CASE
    WHEN V IS NULL OR IS_NULL_VALUE(V)          THEN 'NULL'
    WHEN IS_BOOLEAN(V)                          THEN IFF(V::BOOLEAN, 'TRUE', 'FALSE')
    WHEN IS_INTEGER(V) OR IS_DECIMAL(V) OR IS_DOUBLE(V) THEN TO_VARCHAR(V)
    ELSE '''' || REPLACE(REPLACE(V::VARCHAR, '\\', '\\\\'), '''', '''''') || ''''
  END
$$;

------------------------------------------------------------------ 1. submit
CREATE OR REPLACE PROCEDURE OPS.SP_SUBMIT_CHANGE(P_TYPE VARCHAR, P_PAYLOAD VARIANT, P_JUSTIFICATION VARCHAR)
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
    v_id VARCHAR DEFAULT 'CR-' || TO_VARCHAR(SYSDATE(), 'YYYYMMDDHH24MISSFF3');
BEGIN
    INSERT INTO CONFIG.CHANGE_REQUEST (CHANGE_ID, CHANGE_TYPE, PAYLOAD, JUSTIFICATION, REQUESTED_BY)
    SELECT :v_id, UPPER(:P_TYPE), :P_PAYLOAD, :P_JUSTIFICATION, CURRENT_USER();
    INSERT INTO AUDIT.CHANGE_LOG (CHANGE_ID, ACTION, DETAILS)
    SELECT :v_id, 'SUBMITTED', OBJECT_CONSTRUCT('type', :P_TYPE, 'payload', :P_PAYLOAD);
    RETURN v_id;
END;
$$;

------------------------------------------------------------------ 2. validate (+ impact, SQL, rollback SQL)
CREATE OR REPLACE PROCEDURE OPS.SP_VALIDATE_CHANGE(P_CHANGE_ID VARCHAR)
RETURNS VARIANT
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
    v_type    VARCHAR;
    v_p       VARIANT;
    v_errors  ARRAY DEFAULT ARRAY_CONSTRUCT();
    v_target  VARCHAR;
    v_cfg     VARCHAR;
    v_sql     VARCHAR;
    v_rb      VARCHAR;
    v_before  VARIANT;
    v_impact  VARIANT;
    v_n       NUMBER;
    v_status  VARCHAR;
BEGIN
    SELECT CHANGE_TYPE, PAYLOAD INTO :v_type, :v_p FROM CONFIG.CHANGE_REQUEST
    WHERE CHANGE_ID = :P_CHANGE_ID AND STATUS IN ('DRAFT', 'REJECTED', 'VALIDATED');

    IF (v_type = 'STATUS_MAPPING_UPSERT') THEN
        v_target := 'CONFIG.STATUS_MAPPING';  v_cfg := 'STATUS_MAPPING';
        v_n := (SELECT COUNT(*) FROM CONFIG.CANONICAL_STATUS
                WHERE STATUS_DOMAIN = GET(:v_p, 'status_domain')::VARCHAR AND CANONICAL_STATUS = GET(:v_p, 'canonical_status')::VARCHAR);
        IF (v_n = 0) THEN v_errors := ARRAY_APPEND(v_errors, 'canonical_status not allowed for domain'); END IF;
        IF (NOT ARRAY_CONTAINS(GET(v_p, 'status_category'), ARRAY_CONSTRUCT('SUCCESS','FAILURE','IN_PROGRESS','REVERSAL'))) THEN
            v_errors := ARRAY_APPEND(v_errors, 'status_category must be SUCCESS|FAILURE|IN_PROGRESS|REVERSAL');
        END IF;
        v_n := (SELECT COUNT(*) FROM CONFIG.SOURCE_SYSTEM WHERE SOURCE_SYSTEM = GET(:v_p, 'source_system')::VARCHAR);
        IF (v_n = 0 AND GET(v_p, 'source_system')::VARCHAR <> '*') THEN v_errors := ARRAY_APPEND(v_errors, 'unknown source_system'); END IF;
        IF (GET(v_p, 'source_status') IS NULL OR GET(v_p, 'is_terminal') IS NULL OR GET(v_p, 'status_rank') IS NULL) THEN
            v_errors := ARRAY_APPEND(v_errors, 'source_status, is_terminal and status_rank are required');
        END IF;
        v_before := (SELECT ANY_VALUE(OBJECT_CONSTRUCT(*)) FROM CONFIG.STATUS_MAPPING
                     WHERE SOURCE_SYSTEM = GET(:v_p, 'source_system')::VARCHAR AND STATUS_DOMAIN = GET(:v_p, 'status_domain')::VARCHAR
                       AND SOURCE_STATUS = GET(:v_p, 'source_status')::VARCHAR);
        v_sql := 'MERGE INTO CONFIG.STATUS_MAPPING t USING (SELECT ' ||
                 OPS.SQL_LIT(GET(v_p, 'source_system')) || ' AS SOURCE_SYSTEM, ' || OPS.SQL_LIT(GET(v_p, 'status_domain')) || ' AS STATUS_DOMAIN, ' ||
                 OPS.SQL_LIT(GET(v_p, 'source_status')) || ' AS SOURCE_STATUS, ' || OPS.SQL_LIT(GET(v_p, 'canonical_status')) || ' AS CANONICAL_STATUS, ' ||
                 OPS.SQL_LIT(GET(v_p, 'status_category')) || ' AS STATUS_CATEGORY, ' || OPS.SQL_LIT(GET(v_p, 'is_terminal')) || ' AS IS_TERMINAL, ' ||
                 OPS.SQL_LIT(GET(v_p, 'status_rank')) || ' AS STATUS_RANK) s ' ||
                 'ON t.SOURCE_SYSTEM = s.SOURCE_SYSTEM AND t.STATUS_DOMAIN = s.STATUS_DOMAIN AND t.SOURCE_STATUS = s.SOURCE_STATUS ' ||
                 'WHEN MATCHED THEN UPDATE SET CANONICAL_STATUS = s.CANONICAL_STATUS, STATUS_CATEGORY = s.STATUS_CATEGORY, ' ||
                 'IS_TERMINAL = s.IS_TERMINAL, STATUS_RANK = s.STATUS_RANK, IS_ACTIVE = TRUE, UPDATED_BY = CURRENT_USER(), UPDATED_AT = SYSDATE() ' ||
                 'WHEN NOT MATCHED THEN INSERT (SOURCE_SYSTEM, STATUS_DOMAIN, SOURCE_STATUS, CANONICAL_STATUS, STATUS_CATEGORY, IS_TERMINAL, STATUS_RANK) ' ||
                 'VALUES (s.SOURCE_SYSTEM, s.STATUS_DOMAIN, s.SOURCE_STATUS, s.CANONICAL_STATUS, s.STATUS_CATEGORY, s.IS_TERMINAL, s.STATUS_RANK)';
        v_rb := IFF(v_before IS NULL,
                 'DELETE FROM CONFIG.STATUS_MAPPING WHERE SOURCE_SYSTEM = ' || OPS.SQL_LIT(GET(v_p, 'source_system')) ||
                 ' AND STATUS_DOMAIN = ' || OPS.SQL_LIT(GET(v_p, 'status_domain')) || ' AND SOURCE_STATUS = ' || OPS.SQL_LIT(GET(v_p, 'source_status')),
                 'UPDATE CONFIG.STATUS_MAPPING SET CANONICAL_STATUS = ' || OPS.SQL_LIT(GET(v_before, 'CANONICAL_STATUS')) ||
                 ', STATUS_CATEGORY = ' || OPS.SQL_LIT(GET(v_before, 'STATUS_CATEGORY')) || ', IS_TERMINAL = ' || OPS.SQL_LIT(GET(v_before, 'IS_TERMINAL')) ||
                 ', STATUS_RANK = ' || OPS.SQL_LIT(GET(v_before, 'STATUS_RANK')) || ', IS_ACTIVE = ' || OPS.SQL_LIT(GET(v_before, 'IS_ACTIVE')) ||
                 ' WHERE SOURCE_SYSTEM = ' || OPS.SQL_LIT(GET(v_p, 'source_system')) || ' AND STATUS_DOMAIN = ' || OPS.SQL_LIT(GET(v_p, 'status_domain')) ||
                 ' AND SOURCE_STATUS = ' || OPS.SQL_LIT(GET(v_p, 'source_status')));

    ELSEIF (v_type = 'RECON_TOLERANCE_UPDATE') THEN
        v_target := 'CONFIG.RECON_TOLERANCE';  v_cfg := 'RECON_TOLERANCE';
        IF (COALESCE(GET(v_p, 'recon_scope')::VARCHAR, '?') NOT IN ('PAYMENT_SETTLEMENT', 'BATCH_BANK')) THEN v_errors := ARRAY_APPEND(v_errors, 'invalid recon_scope'); END IF;
        IF (NOT (COALESCE(GET(v_p, 'abs_tolerance')::NUMBER(18,2), -1) BETWEEN 0 AND 1000)) THEN v_errors := ARRAY_APPEND(v_errors, 'abs_tolerance must be 0..1000'); END IF;
        IF (NOT (COALESCE(GET(v_p, 'pct_tolerance')::NUMBER(9,6), -1) BETWEEN 0 AND 0.05)) THEN v_errors := ARRAY_APPEND(v_errors, 'pct_tolerance must be 0..0.05'); END IF;
        IF (NOT (COALESCE(GET(v_p, 'timing_grace_days')::NUMBER, -1) BETWEEN 0 AND 30)) THEN v_errors := ARRAY_APPEND(v_errors, 'timing_grace_days must be 0..30'); END IF;
        v_n := (SELECT COUNT(*) FROM STAGING.CURRENCY WHERE CURRENCY_CODE = GET(:v_p, 'currency_code')::VARCHAR);
        IF (v_n = 0) THEN v_errors := ARRAY_APPEND(v_errors, 'unknown currency_code'); END IF;
        v_before := (SELECT ANY_VALUE(OBJECT_CONSTRUCT(*)) FROM CONFIG.RECON_TOLERANCE
                     WHERE RECON_SCOPE = GET(:v_p, 'recon_scope')::VARCHAR AND CURRENCY_CODE = GET(:v_p, 'currency_code')::VARCHAR);
        v_sql := 'MERGE INTO CONFIG.RECON_TOLERANCE t USING (SELECT ' ||
                 OPS.SQL_LIT(GET(v_p, 'recon_scope')) || ' AS RECON_SCOPE, ' || OPS.SQL_LIT(GET(v_p, 'currency_code')) || ' AS CURRENCY_CODE, ' ||
                 OPS.SQL_LIT(GET(v_p, 'abs_tolerance')) || ' AS ABS_TOLERANCE, ' || OPS.SQL_LIT(GET(v_p, 'pct_tolerance')) || ' AS PCT_TOLERANCE, ' ||
                 OPS.SQL_LIT(GET(v_p, 'timing_grace_days')) || ' AS TIMING_GRACE_DAYS, ' || OPS.SQL_LIT(GET(v_p, 'fee_variance_pct')) || ' AS FEE_VARIANCE_PCT) s ' ||
                 'ON t.RECON_SCOPE = s.RECON_SCOPE AND t.CURRENCY_CODE = s.CURRENCY_CODE ' ||
                 'WHEN MATCHED THEN UPDATE SET ABS_TOLERANCE = s.ABS_TOLERANCE, PCT_TOLERANCE = s.PCT_TOLERANCE, ' ||
                 'TIMING_GRACE_DAYS = s.TIMING_GRACE_DAYS, FEE_VARIANCE_PCT = s.FEE_VARIANCE_PCT, UPDATED_BY = CURRENT_USER(), UPDATED_AT = SYSDATE() ' ||
                 'WHEN NOT MATCHED THEN INSERT (RECON_SCOPE, CURRENCY_CODE, ABS_TOLERANCE, PCT_TOLERANCE, TIMING_GRACE_DAYS, FEE_VARIANCE_PCT) ' ||
                 'VALUES (s.RECON_SCOPE, s.CURRENCY_CODE, s.ABS_TOLERANCE, s.PCT_TOLERANCE, s.TIMING_GRACE_DAYS, s.FEE_VARIANCE_PCT)';
        v_rb := IFF(v_before IS NULL,
                 'DELETE FROM CONFIG.RECON_TOLERANCE WHERE RECON_SCOPE = ' || OPS.SQL_LIT(GET(v_p, 'recon_scope')) ||
                 ' AND CURRENCY_CODE = ' || OPS.SQL_LIT(GET(v_p, 'currency_code')),
                 'UPDATE CONFIG.RECON_TOLERANCE SET ABS_TOLERANCE = ' || OPS.SQL_LIT(GET(v_before, 'ABS_TOLERANCE')) ||
                 ', PCT_TOLERANCE = ' || OPS.SQL_LIT(GET(v_before, 'PCT_TOLERANCE')) || ', TIMING_GRACE_DAYS = ' || OPS.SQL_LIT(GET(v_before, 'TIMING_GRACE_DAYS')) ||
                 ', FEE_VARIANCE_PCT = ' || OPS.SQL_LIT(GET(v_before, 'FEE_VARIANCE_PCT')) ||
                 ' WHERE RECON_SCOPE = ' || OPS.SQL_LIT(GET(v_p, 'recon_scope')) || ' AND CURRENCY_CODE = ' || OPS.SQL_LIT(GET(v_p, 'currency_code')));

    ELSEIF (v_type = 'FRAUD_THRESHOLD_UPDATE') THEN
        v_target := 'CONFIG.FRAUD_THRESHOLD';  v_cfg := 'FRAUD_THRESHOLD';
        v_before := (SELECT ANY_VALUE(OBJECT_CONSTRUCT(*)) FROM CONFIG.FRAUD_THRESHOLD WHERE RULE_CODE = GET(:v_p, 'rule_code')::VARCHAR);
        IF (v_before IS NULL) THEN v_errors := ARRAY_APPEND(v_errors, 'unknown rule_code (new rules need code: DEPLOYMENT)'); END IF;
        IF (NOT (COALESCE(GET(v_p, 'threshold_value')::NUMBER(18,4), 0) > 0)) THEN v_errors := ARRAY_APPEND(v_errors, 'threshold_value must be > 0'); END IF;
        IF (GET(v_p, 'rule_code')::VARCHAR IN ('VELOCITY_ATTEMPTS', 'VELOCITY_FAILED')
            AND COALESCE(GET(v_p, 'window_minutes')::NUMBER, 60) <> 60) THEN
            v_errors := ARRAY_APPEND(v_errors, 'velocity window is fixed at 60 minutes in int_customer_velocity (DEPLOYMENT change)');
        END IF;
        v_sql := 'UPDATE CONFIG.FRAUD_THRESHOLD SET THRESHOLD_VALUE = ' || OPS.SQL_LIT(GET(v_p, 'threshold_value')) ||
                 ', IS_ACTIVE = ' || OPS.SQL_LIT(COALESCE(GET(v_p, 'is_active'), TO_VARIANT(TRUE))) ||
                 ', UPDATED_BY = CURRENT_USER(), UPDATED_AT = SYSDATE() WHERE RULE_CODE = ' || OPS.SQL_LIT(GET(v_p, 'rule_code'));
        v_rb  := 'UPDATE CONFIG.FRAUD_THRESHOLD SET THRESHOLD_VALUE = ' || OPS.SQL_LIT(GET(v_before, 'THRESHOLD_VALUE')) ||
                 ', IS_ACTIVE = ' || OPS.SQL_LIT(GET(v_before, 'IS_ACTIVE')) || ' WHERE RULE_CODE = ' || OPS.SQL_LIT(GET(v_p, 'rule_code'));

    ELSEIF (v_type = 'DQ_RULE_UPSERT') THEN
        v_target := 'CONFIG.DQ_RULE';  v_cfg := 'DQ_RULE';
        IF (NOT ARRAY_CONTAINS(GET(v_p, 'rule_type'), ARRAY_CONSTRUCT('NOT_NULL','FRESHNESS_HOURS','ROW_COUNT_MIN','DUPLICATE_KEY','NON_NEGATIVE'))) THEN
            v_errors := ARRAY_APPEND(v_errors, 'unsupported rule_type');
        END IF;
        v_n := (SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS
                WHERE TABLE_SCHEMA || '.' || TABLE_NAME = UPPER(GET(:v_p, 'target_table')::VARCHAR)
                  AND (COLUMN_NAME = UPPER(GET(:v_p, 'column_name')::VARCHAR) OR GET(:v_p, 'column_name') IS NULL));
        IF (v_n = 0) THEN v_errors := ARRAY_APPEND(v_errors, 'target_table/column_name not found'); END IF;
        v_before := (SELECT ANY_VALUE(OBJECT_CONSTRUCT(*)) FROM CONFIG.DQ_RULE WHERE RULE_ID = GET(:v_p, 'rule_id')::VARCHAR);
        v_sql := 'MERGE INTO CONFIG.DQ_RULE t USING (SELECT ' || OPS.SQL_LIT(GET(v_p, 'rule_id')) || ' AS RULE_ID, ' ||
                 OPS.SQL_LIT(TO_VARIANT(UPPER(GET(v_p, 'target_table')::VARCHAR))) || ' AS TARGET_TABLE, ' || OPS.SQL_LIT(GET(v_p, 'rule_type')) || ' AS RULE_TYPE, ' ||
                 OPS.SQL_LIT(TO_VARIANT(UPPER(GET(v_p, 'column_name')::VARCHAR))) || ' AS COLUMN_NAME, ' || OPS.SQL_LIT(GET(v_p, 'threshold')) || ' AS THRESHOLD, ' ||
                 OPS.SQL_LIT(COALESCE(GET(v_p, 'severity'), TO_VARIANT('ERROR'))) || ' AS SEVERITY, ' || OPS.SQL_LIT(GET(v_p, 'description')) || ' AS DESCRIPTION) s ' ||
                 'ON t.RULE_ID = s.RULE_ID WHEN MATCHED THEN UPDATE SET TARGET_TABLE = s.TARGET_TABLE, RULE_TYPE = s.RULE_TYPE, ' ||
                 'COLUMN_NAME = s.COLUMN_NAME, THRESHOLD = s.THRESHOLD, SEVERITY = s.SEVERITY, DESCRIPTION = s.DESCRIPTION, IS_ACTIVE = TRUE ' ||
                 'WHEN NOT MATCHED THEN INSERT (RULE_ID, TARGET_TABLE, RULE_TYPE, COLUMN_NAME, THRESHOLD, SEVERITY, DESCRIPTION) ' ||
                 'VALUES (s.RULE_ID, s.TARGET_TABLE, s.RULE_TYPE, s.COLUMN_NAME, s.THRESHOLD, s.SEVERITY, s.DESCRIPTION)';
        v_rb := IFF(v_before IS NULL,
                 'DELETE FROM CONFIG.DQ_RULE WHERE RULE_ID = ' || OPS.SQL_LIT(GET(v_p, 'rule_id')),
                 'UPDATE CONFIG.DQ_RULE SET TARGET_TABLE = ' || OPS.SQL_LIT(GET(v_before, 'TARGET_TABLE')) || ', RULE_TYPE = ' || OPS.SQL_LIT(GET(v_before, 'RULE_TYPE')) ||
                 ', COLUMN_NAME = ' || OPS.SQL_LIT(GET(v_before, 'COLUMN_NAME')) || ', THRESHOLD = ' || OPS.SQL_LIT(GET(v_before, 'THRESHOLD')) ||
                 ', SEVERITY = ' || OPS.SQL_LIT(GET(v_before, 'SEVERITY')) || ', IS_ACTIVE = ' || OPS.SQL_LIT(GET(v_before, 'IS_ACTIVE')) ||
                 ' WHERE RULE_ID = ' || OPS.SQL_LIT(GET(v_p, 'rule_id')));

    ELSEIF (v_type = 'ROW_ACCESS_MAP_UPSERT') THEN
        v_target := 'CONFIG.ROW_ACCESS_MAP';  v_cfg := 'ROW_ACCESS_MAP';
        IF (COALESCE(GET(v_p, 'region')::VARCHAR, '?') NOT IN ('NORTH','SOUTH','EAST','WEST')) THEN v_errors := ARRAY_APPEND(v_errors, 'invalid region'); END IF;
        IF (NOT REGEXP_LIKE(COALESCE(GET(v_p, 'role_name')::VARCHAR, ''), '^FINTECH_ANALYST_[A-Z]+$')) THEN
            v_errors := ARRAY_APPEND(v_errors, 'role_name must be a FINTECH_ANALYST_<REGION> role');
        END IF;
        v_sql := 'INSERT INTO CONFIG.ROW_ACCESS_MAP (ROLE_NAME, REGION) SELECT ' || OPS.SQL_LIT(GET(v_p, 'role_name')) || ', ' ||
                 OPS.SQL_LIT(GET(v_p, 'region')) || ' WHERE NOT EXISTS (SELECT 1 FROM CONFIG.ROW_ACCESS_MAP WHERE ROLE_NAME = ' ||
                 OPS.SQL_LIT(GET(v_p, 'role_name')) || ' AND REGION = ' || OPS.SQL_LIT(GET(v_p, 'region')) || ')';
        v_rb  := 'DELETE FROM CONFIG.ROW_ACCESS_MAP WHERE ROLE_NAME = ' || OPS.SQL_LIT(GET(v_p, 'role_name')) || ' AND REGION = ' || OPS.SQL_LIT(GET(v_p, 'region'));

    ELSE
        v_errors := ARRAY_APPEND(v_errors,
            'Change type ' || COALESCE(v_type, 'NULL') || ' is a DEPLOYMENT change (dbt models / vars / semantic view DDL). ' ||
            'Open a pull request; CI runs dbt build + tests on FINTECH_TEST; release promotes to PROD.');
    END IF;

    -- Impact analysis: config table -> directly impacted nodes -> all downstream dbt nodes
    IF (v_cfg IS NOT NULL) THEN
        WITH RECURSIVE direct AS (
            SELECT IMPACTED_NODE, NODE_TYPE FROM CONFIG.CONFIG_IMPACT_MAP WHERE CONFIG_TABLE = :v_cfg
        ),
        downstream (node_name, depth) AS (
            SELECT LOWER(IMPACTED_NODE), 0 FROM direct WHERE NODE_TYPE = 'MODEL'
            UNION ALL
            SELECT l.NODE_NAME, d.depth + 1
            FROM AUDIT.DBT_MODEL_LINEAGE l JOIN downstream d ON LOWER(l.PARENT_NAME) = d.node_name
            WHERE d.depth < 20
        )
        SELECT OBJECT_CONSTRUCT(
            'config_table', :v_cfg,
            'direct', (SELECT ARRAY_AGG(OBJECT_CONSTRUCT('node', IMPACTED_NODE, 'type', NODE_TYPE)) FROM direct),
            'downstream_models', (SELECT ARRAY_AGG(DISTINCT node_name) FROM downstream),
            'metrics', (SELECT ARRAY_AGG(IMPACTED_NODE) FROM direct WHERE NODE_TYPE = 'METRIC'),
            'dbt_command', 'dbt build -s ' ||
                (SELECT LISTAGG(DISTINCT LOWER(IMPACTED_NODE) || '+', ' ') FROM direct WHERE NODE_TYPE = 'MODEL') ||
                IFF(:v_cfg = 'STATUS_MAPPING', ' --full-refresh', ''),
            'effective', IFF(:v_cfg IN ('DQ_RULE', 'ROW_ACCESS_MAP'), 'IMMEDIATE (read at run/query time)', 'NEXT dbt build of listed models'))
        INTO :v_impact;
    END IF;

    v_status := IFF(ARRAY_SIZE(v_errors) = 0, 'VALIDATED', 'REJECTED');
    UPDATE CONFIG.CHANGE_REQUEST
       SET STATUS = :v_status, TARGET_TABLE = :v_target,
           VALIDATION_RESULT = OBJECT_CONSTRUCT('errors', :v_errors, 'validated_at', SYSDATE()),
           IMPACT = :v_impact, BEFORE_IMAGE = :v_before, GENERATED_SQL = :v_sql, ROLLBACK_SQL = :v_rb
     WHERE CHANGE_ID = :P_CHANGE_ID;
    INSERT INTO AUDIT.CHANGE_LOG (CHANGE_ID, ACTION, DETAILS)
    SELECT :P_CHANGE_ID, :v_status, OBJECT_CONSTRUCT('errors', :v_errors, 'impact', :v_impact);
    RETURN OBJECT_CONSTRUCT('change_id', P_CHANGE_ID, 'status', v_status, 'errors', v_errors, 'impact', v_impact);
END;
$$;

------------------------------------------------------------------ 3. preview
CREATE OR REPLACE PROCEDURE OPS.SP_PREVIEW_CHANGE(P_CHANGE_ID VARCHAR)
RETURNS VARIANT
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
BEGIN
    RETURN (SELECT OBJECT_CONSTRUCT('change_id', CHANGE_ID, 'type', CHANGE_TYPE, 'status', STATUS,
                                    'before', BEFORE_IMAGE, 'after', PAYLOAD, 'sql_to_execute', GENERATED_SQL,
                                    'rollback_sql', ROLLBACK_SQL, 'impact', IMPACT, 'validation', VALIDATION_RESULT,
                                    'requested_by', REQUESTED_BY, 'justification', JUSTIFICATION)
            FROM CONFIG.CHANGE_REQUEST WHERE CHANGE_ID = :P_CHANGE_ID);
END;
$$;

------------------------------------------------------------------ 4. approve (four-eyes)
CREATE OR REPLACE PROCEDURE OPS.SP_APPROVE_CHANGE(P_CHANGE_ID VARCHAR, P_COMMENT VARCHAR)
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS OWNER
COMMENT = 'USAGE granted only to FINTECH_CONFIG_APPROVER. Approver must differ from requester.'
AS
$$
DECLARE
    v_req VARCHAR;
    v_st  VARCHAR;
BEGIN
    SELECT REQUESTED_BY, STATUS INTO :v_req, :v_st FROM CONFIG.CHANGE_REQUEST WHERE CHANGE_ID = :P_CHANGE_ID;
    IF (v_st <> 'VALIDATED') THEN
        RETURN 'REFUSED: status is ' || v_st || ' (must be VALIDATED)';
    END IF;
    IF (v_req = CURRENT_USER()) THEN
        RETURN 'REFUSED: requester cannot approve their own change';
    END IF;
    UPDATE CONFIG.CHANGE_REQUEST SET STATUS = 'APPROVED', APPROVED_BY = CURRENT_USER(), APPROVED_AT = SYSDATE()
     WHERE CHANGE_ID = :P_CHANGE_ID;
    INSERT INTO AUDIT.CHANGE_LOG (CHANGE_ID, ACTION, DETAILS)
    SELECT :P_CHANGE_ID, 'APPROVED', OBJECT_CONSTRUCT('comment', :P_COMMENT);
    RETURN 'APPROVED';
END;
$$;

------------------------------------------------------------------ 5. KPI snapshot helper
CREATE OR REPLACE PROCEDURE OPS.SP_CAPTURE_KPI_SNAPSHOT(P_CHANGE_ID VARCHAR, P_PHASE VARCHAR)
RETURNS NUMBER
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
BEGIN
    INSERT INTO AUDIT.KPI_SNAPSHOT (CHANGE_ID, PHASE, METRIC_NAME, METRIC_VALUE)
    SELECT :P_CHANGE_ID, :P_PHASE, metric_name, metric_value
    FROM (SELECT * FROM DASHBOARD.VW_EXECUTIVE_PAYMENT_KPIS WHERE period = 'ALL_TIME')
    UNPIVOT (metric_value FOR metric_name IN (
        payment_volume_inr, payment_attempt_count, successful_payment_count, payment_success_rate,
        payment_failure_rate, average_transaction_value_inr, refund_amount_inr, refund_rate,
        chargeback_amount_inr, chargeback_rate, settlement_match_rate, outstanding_settlement_inr, fraud_alert_count));
    INSERT INTO AUDIT.KPI_SNAPSHOT (CHANGE_ID, PHASE, METRIC_NAME, METRIC_VALUE)
    SELECT :P_CHANGE_ID, :P_PHASE, 'EXCEPTIONS_' || exception_type, COUNT(*)
    FROM MARTS.MART_RECONCILIATION_EXCEPTIONS GROUP BY exception_type
    UNION ALL
    SELECT :P_CHANGE_ID, :P_PHASE, 'CNL_EXCEPTIONS_' || exception_type, COUNT(*)
    FROM CANONICAL.CNL_EXCEPTIONS GROUP BY exception_type;
    RETURN SQLROWCOUNT;
END;
$$;

------------------------------------------------------------------ 6. apply
CREATE OR REPLACE PROCEDURE OPS.SP_APPLY_CHANGE(P_CHANGE_ID VARCHAR)
RETURNS VARIANT
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
    v_sql VARCHAR;
    v_st  VARCHAR;
    v_impact VARIANT;
BEGIN
    SELECT GENERATED_SQL, STATUS, IMPACT INTO :v_sql, :v_st, :v_impact
    FROM CONFIG.CHANGE_REQUEST WHERE CHANGE_ID = :P_CHANGE_ID;
    IF (v_st <> 'APPROVED') THEN
        RETURN OBJECT_CONSTRUCT('status', 'REFUSED', 'reason', 'change is ' || v_st || ', must be APPROVED');
    END IF;
    CALL OPS.SP_CAPTURE_KPI_SNAPSHOT(:P_CHANGE_ID, 'BEFORE');
    BEGIN TRANSACTION;
    EXECUTE IMMEDIATE :v_sql;            -- exactly the SQL that was previewed and approved
    UPDATE CONFIG.CHANGE_REQUEST SET STATUS = 'APPLIED', APPLIED_AT = SYSDATE() WHERE CHANGE_ID = :P_CHANGE_ID;
    INSERT INTO AUDIT.CHANGE_LOG (CHANGE_ID, ACTION, DETAILS)
    SELECT :P_CHANGE_ID, 'APPLIED', OBJECT_CONSTRUCT('sql', :v_sql);
    COMMIT;
    RETURN OBJECT_CONSTRUCT('status', 'APPLIED', 'next_step', GET(v_impact, 'dbt_command'),
                            'then', 'CALL OPS.SP_VERIFY_CHANGE(''' || P_CHANGE_ID || ''');');
EXCEPTION
    WHEN OTHER THEN
        ROLLBACK;
        INSERT INTO AUDIT.CHANGE_LOG (CHANGE_ID, ACTION, DETAILS)
        SELECT :P_CHANGE_ID, 'APPLY_FAILED', OBJECT_CONSTRUCT('error', :SQLERRM);
        RAISE;
END;
$$;

------------------------------------------------------------------ 7. verify (after dbt build)
CREATE OR REPLACE PROCEDURE OPS.SP_VERIFY_CHANGE(P_CHANGE_ID VARCHAR)
RETURNS VARIANT
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
    v_diff VARIANT;
    v_failed_tests NUMBER;
BEGIN
    CALL OPS.SP_CAPTURE_KPI_SNAPSHOT(:P_CHANGE_ID, 'AFTER');
    v_diff := (SELECT ARRAY_AGG(OBJECT_CONSTRUCT('metric', metric_name, 'before', before_value, 'after', after_value,
                                                 'delta', after_value - before_value))
               FROM CONFIG.VW_CHANGE_KPI_COMPARISON
               WHERE change_id = :P_CHANGE_ID AND COALESCE(before_value, -1) <> COALESCE(after_value, -1));
    v_failed_tests := (SELECT COUNT(*) FROM AUDIT.DBT_RUN_RESULTS
                       WHERE RESOURCE_TYPE = 'test' AND STATUS IN ('fail', 'error')
                         AND INVOCATION_ID = (SELECT INVOCATION_ID FROM AUDIT.DBT_RUN_RESULTS
                                              ORDER BY LOGGED_AT DESC LIMIT 1));
    UPDATE CONFIG.CHANGE_REQUEST SET STATUS = 'VERIFIED', VERIFIED_AT = SYSDATE() WHERE CHANGE_ID = :P_CHANGE_ID;
    INSERT INTO AUDIT.CHANGE_LOG (CHANGE_ID, ACTION, DETAILS)
    SELECT :P_CHANGE_ID, 'VERIFIED', OBJECT_CONSTRUCT('kpi_changes', :v_diff, 'failed_dbt_tests_last_run', :v_failed_tests);
    RETURN OBJECT_CONSTRUCT('kpi_changes', v_diff, 'failed_dbt_tests_last_run', v_failed_tests,
                            'advice', IFF(v_failed_tests > 0, 'dbt tests failed: consider SP_ROLLBACK_CHANGE', 'ok'));
END;
$$;

------------------------------------------------------------------ 8. rollback
CREATE OR REPLACE PROCEDURE OPS.SP_ROLLBACK_CHANGE(P_CHANGE_ID VARCHAR, P_REASON VARCHAR)
RETURNS VARIANT
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
    v_rb VARCHAR;
    v_st VARCHAR;
    v_impact VARIANT;
BEGIN
    SELECT ROLLBACK_SQL, STATUS, IMPACT INTO :v_rb, :v_st, :v_impact FROM CONFIG.CHANGE_REQUEST WHERE CHANGE_ID = :P_CHANGE_ID;
    IF (v_st NOT IN ('APPLIED', 'VERIFIED')) THEN
        RETURN OBJECT_CONSTRUCT('status', 'REFUSED', 'reason', 'only APPLIED/VERIFIED changes can be rolled back');
    END IF;
    BEGIN TRANSACTION;
    EXECUTE IMMEDIATE :v_rb;
    UPDATE CONFIG.CHANGE_REQUEST SET STATUS = 'ROLLED_BACK' WHERE CHANGE_ID = :P_CHANGE_ID;
    INSERT INTO AUDIT.CHANGE_LOG (CHANGE_ID, ACTION, DETAILS)
    SELECT :P_CHANGE_ID, 'ROLLED_BACK', OBJECT_CONSTRUCT('reason', :P_REASON, 'sql', :v_rb);
    COMMIT;
    RETURN OBJECT_CONSTRUCT('status', 'ROLLED_BACK', 'next_step', GET(v_impact, 'dbt_command'));
EXCEPTION
    WHEN OTHER THEN
        ROLLBACK;
        RAISE;
END;
$$;

CREATE OR REPLACE VIEW CONFIG.VW_CHANGE_KPI_COMPARISON AS
SELECT b.CHANGE_ID AS change_id, b.METRIC_NAME AS metric_name,
       b.METRIC_VALUE AS before_value, a.METRIC_VALUE AS after_value,
       a.METRIC_VALUE - b.METRIC_VALUE AS delta
FROM (SELECT * FROM AUDIT.KPI_SNAPSHOT WHERE PHASE = 'BEFORE'
      QUALIFY ROW_NUMBER() OVER (PARTITION BY CHANGE_ID, METRIC_NAME ORDER BY CAPTURED_AT DESC) = 1) b
FULL OUTER JOIN (SELECT * FROM AUDIT.KPI_SNAPSHOT WHERE PHASE = 'AFTER'
      QUALIFY ROW_NUMBER() OVER (PARTITION BY CHANGE_ID, METRIC_NAME ORDER BY CAPTURED_AT DESC) = 1) a
  ON a.CHANGE_ID = b.CHANGE_ID AND a.METRIC_NAME = b.METRIC_NAME;

------------------------------------------------------------------ grants
GRANT USAGE ON PROCEDURE OPS.SP_SUBMIT_CHANGE(VARCHAR, VARIANT, VARCHAR) TO ROLE FINTECH_OPS;
GRANT USAGE ON PROCEDURE OPS.SP_VALIDATE_CHANGE(VARCHAR)                TO ROLE FINTECH_OPS;
GRANT USAGE ON PROCEDURE OPS.SP_PREVIEW_CHANGE(VARCHAR)                 TO ROLE FINTECH_OPS;
GRANT USAGE ON PROCEDURE OPS.SP_PREVIEW_CHANGE(VARCHAR)                 TO ROLE FINTECH_CONFIG_APPROVER;
GRANT USAGE ON PROCEDURE OPS.SP_APPROVE_CHANGE(VARCHAR, VARCHAR)        TO ROLE FINTECH_CONFIG_APPROVER;
GRANT USAGE ON PROCEDURE OPS.SP_APPLY_CHANGE(VARCHAR)                   TO ROLE FINTECH_OPS;
GRANT USAGE ON PROCEDURE OPS.SP_VERIFY_CHANGE(VARCHAR)                  TO ROLE FINTECH_OPS;
GRANT USAGE ON PROCEDURE OPS.SP_ROLLBACK_CHANGE(VARCHAR, VARCHAR)       TO ROLE FINTECH_OPS;
GRANT USAGE ON SCHEMA OPS TO ROLE FINTECH_CONFIG_APPROVER;
GRANT SELECT ON VIEW CONFIG.VW_CHANGE_KPI_COMPARISON TO ROLE FINTECH_OPS;
GRANT SELECT ON VIEW CONFIG.VW_CHANGE_KPI_COMPARISON TO ROLE FINTECH_CONFIG_APPROVER;
-- FINTECH_OPS has USAGE on all OPS procedures (10_security) EXCEPT approval: revoke it explicitly.
REVOKE USAGE ON PROCEDURE OPS.SP_APPROVE_CHANGE(VARCHAR, VARCHAR) FROM ROLE FINTECH_OPS;

/* ---------------------------------------------------------------------
   WORKED EXAMPLE (run as indicated roles)
   ---------------------------------------------------------------------
   -- (ops user A) Provider C starts sending 'P1' for "processing":
   CALL OPS.SP_SUBMIT_CHANGE('STATUS_MAPPING_UPSERT',
        PARSE_JSON('{"source_system":"PROV_C","status_domain":"PAYMENT","source_status":"P1",
                     "canonical_status":"PENDING","status_category":"IN_PROGRESS",
                     "is_terminal":false,"status_rank":20}'),
        'PROV_C release 4.2 introduces P1 = processing');
   -- returns CR-...; then:
   CALL OPS.SP_VALIDATE_CHANGE('CR-...');
   CALL OPS.SP_PREVIEW_CHANGE('CR-...');
   -- (approver user B, role FINTECH_CONFIG_APPROVER)
   CALL OPS.SP_APPROVE_CHANGE('CR-...', 'checked with PROV_C spec');
   -- (ops user A)
   CALL OPS.SP_APPLY_CHANGE('CR-...');
   -- CI / developer: dbt build -s cnl_payment_attempt+ cnl_payment_event+ ... --full-refresh  (command returned)
   CALL OPS.SP_VERIFY_CHANGE('CR-...');
   SELECT * FROM CONFIG.VW_CHANGE_KPI_COMPARISON WHERE change_id = 'CR-...';
   -- If something is wrong:
   CALL OPS.SP_ROLLBACK_CHANGE('CR-...', 'unexpected success-rate shift');  -- then rebuild again
   -- Point-in-time inspection of any config table (Time Travel, retention 7d on CONFIG):
   SELECT * FROM CONFIG.STATUS_MAPPING AT (OFFSET => -3600);
   --------------------------------------------------------------------- */
