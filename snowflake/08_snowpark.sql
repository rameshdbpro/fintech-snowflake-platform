/* =====================================================================
   08_SNOWPARK.SQL  -  justified Snowpark Python components (run in Snowflake)
   Generated from 08_snowpark.sql.template + snowpark/parse_bank_narrative.py
   by tools/build_snowpark_sql.py (keeps UDF code identical to the unit-tested
   source). Edit the .py / template, then rebuild.

   Components
   1. OPS.PARSE_BANK_NARRATIVE (Python UDF)   - configurable bank narrative parser
   2. OPS.SP_PROFILE_TABLE (Python procedure)  - schema-agnostic column profiling
   Everything else (transformations, KPIs, reconciliation) is SQL/dbt by design.

   Prerequisites
   * Anaconda/Snowflake Python packages terms accepted by ORGADMIN
     (Snowsight > Admin > Billing & Terms > Anaconda), needed for PACKAGES.
   * Roles: FINTECH_DEPLOYER creates; USAGE granted to FINTECH_TRANSFORMER
     (calls the UDF from dbt) and FINTECH_OPS (calls the procedure).
   * Runtime 3.11; packages: snowflake-snowpark-python (procedure only).
   If Python UDFs are unavailable: run dbt with
     --vars '{use_snowpark_narrative_parser: false}'  (pure SQL REGEXP fallback)
   and use OPS.SP_PROFILE_TABLE_SQL below instead of the Snowpark profiler.
   ===================================================================== */
USE ROLE FINTECH_DEPLOYER;
USE DATABASE FINTECH_DEV;
USE WAREHOUSE WH_FINTECH_TRANSFORM;
USE SCHEMA OPS;

------------------------------------------------------------------------
-- 1. UDF: OPS.PARSE_BANK_NARRATIVE(narrative, bank_code, patterns)
--    Input : narrative VARCHAR, bank_code VARCHAR,
--            patterns ARRAY of {bank_code, priority, pattern}
--            (dbt passes ARRAY_AGG(...) from CONFIG.BANK_NARRATIVE_PATTERN)
--    Output: OBJECT {settlement_ref, provider_code, settlement_date,
--                    match_source, priority, errors[]}
--    Errors: never raises for bad data/patterns; reports them in "errors".
------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION OPS.PARSE_BANK_NARRATIVE(NARRATIVE VARCHAR, BANK_CODE VARCHAR, PATTERNS ARRAY)
RETURNS OBJECT
LANGUAGE PYTHON
IMMUTABLE
RUNTIME_VERSION = '3.11'
COMMENT = 'Extracts settlement batch reference from bank-specific narratives using CONFIG.BANK_NARRATIVE_PATTERN'
HANDLER = 'parse'
AS
$$
"""Snowpark Python UDF handler: OPS.PARSE_BANK_NARRATIVE.

Runs INSIDE Snowflake (deployed by snowflake/08_snowpark.sql, which embeds this
exact code). This file exists so the logic can be unit-tested in CI with plain
Python (snowpark/tests/test_parse_bank_narrative.py). No external service.

Why Python instead of SQL REGEXP:
  * patterns come from CONFIG.BANK_NARRATIVE_PATTERN as an ordered list with
    named groups (?P<prov>..)(?P<dt>..); Snowflake REGEXP has no named groups,
    so SQL needs one hard-coded REGEXP_SUBSTR pair per bank format;
  * first-match-wins across bank-specific then generic patterns, with the
    match source returned for audit;
  * the date component is validated as a real calendar date (20260231 rejected);
  * bad patterns are reported per row instead of failing the whole query.
The SQL fallback (macro parse_settlement_ref with use_snowpark_narrative_parser=false)
covers the three known bank formats without these extras.
"""
import re
from datetime import datetime

_COMPILED = {}


def _compile(pattern):
    rx = _COMPILED.get(pattern)
    if rx is None:
        rx = re.compile(pattern)
        _COMPILED[pattern] = rx
    return rx


def parse(narrative, bank_code, patterns):
    """Return {settlement_ref, provider_code, settlement_date, match_source, priority, errors}."""
    result = {"settlement_ref": None, "provider_code": None, "settlement_date": None,
              "match_source": "NO_MATCH", "priority": None, "errors": []}
    if narrative is None:
        result["match_source"] = "NULL_NARRATIVE"
        return result
    patterns = patterns or []
    bank = (bank_code or "").upper()
    # bank-specific patterns first (by priority), then generic '*' patterns
    ordered = sorted(
        [p for p in patterns if p and str(p.get("bank_code", "")).upper() in (bank, "*")],
        key=lambda p: (0 if str(p.get("bank_code", "")).upper() == bank else 1, int(p.get("priority", 999))),
    )
    for p in ordered:
        try:
            rx = _compile(p["pattern"])
        except (re.error, KeyError, TypeError) as exc:
            result["errors"].append(f"bad pattern {p.get('bank_code')}/{p.get('priority')}: {exc}")
            continue
        m = rx.search(narrative)
        if not m:
            continue
        groups = m.groupdict()
        prov, dt = groups.get("prov"), groups.get("dt")
        if not prov or not dt:
            result["errors"].append(f"pattern {p.get('bank_code')}/{p.get('priority')} lacks prov/dt groups")
            continue
        try:
            settle_date = datetime.strptime(dt, "%Y%m%d").date()
        except ValueError:
            result["errors"].append(f"invalid date '{dt}'")
            continue
        result.update({
            "settlement_ref": f"SB-{prov.upper()}-{dt}",
            "provider_code": prov.upper(),
            "settlement_date": settle_date.isoformat(),
            "match_source": "BANK_PATTERN" if str(p.get("bank_code", "")).upper() == bank else "GENERIC_PATTERN",
            "priority": int(p.get("priority", 0)),
        })
        return result
    return result
$$;

-- Validation queries (expected values in comments)
SELECT OPS.PARSE_BANK_NARRATIVE('IMPS/P2A/612345678901/SETTLEMENT/SBPB20260401/PROVB', 'ICICI',
         (SELECT ARRAY_AGG(OBJECT_CONSTRUCT('bank_code',BANK_CODE,'priority',PRIORITY,'pattern',PATTERN))
          FROM CONFIG.BANK_NARRATIVE_PATTERN WHERE IS_ACTIVE)):settlement_ref::VARCHAR AS ref;   -- SB-PB-20260401
SELECT OPS.PARSE_BANK_NARRATIVE('NEFT CR-SETTL SB-PA-20260231', 'HDFC',
         (SELECT ARRAY_AGG(OBJECT_CONSTRUCT('bank_code',BANK_CODE,'priority',PRIORITY,'pattern',PATTERN))
          FROM CONFIG.BANK_NARRATIVE_PATTERN WHERE IS_ACTIVE)) AS invalid_date;                -- settlement_ref null, errors populated

-- Equivalent SQL (what the dbt fallback does, one REGEXP pair per bank format):
--   'SB-' || REGEXP_SUBSTR(narrative, '/SETTLEMENT/SB([A-Z]{2})([0-9]{8})/', 1, 1, 'e', 1)
--   || '-' || REGEXP_SUBSTR(narrative, '/SETTLEMENT/SB([A-Z]{2})([0-9]{8})/', 1, 1, 'e', 2)
-- It cannot read patterns from config, validate dates, or report bad patterns.

------------------------------------------------------------------------
-- 2. PROCEDURE: OPS.SP_PROFILE_TABLE(table_name, run_id)
--    Profiles every column of any RAW/CANONICAL/CORE table (rows, nulls,
--    distinct, min, max) into AUDIT.DATA_PROFILE in ONE scan, building the
--    aggregate list from the table schema with the Snowpark DataFrame API.
--    Why Snowpark: column lists are dynamic per table; in SQL this needs
--    string-built dynamic SQL per column type. Here it is a typed loop.
--    Input : table_name 'SCHEMA.TABLE' (validated against INFORMATION_SCHEMA)
--    Output: VARIANT {status, table, columns, rows}
------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE OPS.SP_PROFILE_TABLE(TABLE_NAME VARCHAR, RUN_ID VARCHAR)
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'run'
COMMENT = 'Snowpark column profiler -> AUDIT.DATA_PROFILE'
EXECUTE AS OWNER
AS
$$
import re
from snowflake.snowpark import functions as F
from snowflake.snowpark.types import StringType, VariantType, ArrayType, MapType

ALLOWED_SCHEMAS = {"RAW", "LANDING", "CANONICAL", "STAGING", "CORE", "MARTS"}


def _log(session, run_id, status, message, rows=None):
    session.sql(
        "INSERT INTO AUDIT.PROCEDURE_LOG (PROCEDURE_NAME, RUN_ID, STEP, STATUS, ROWS_AFFECTED, MESSAGE) "
        "VALUES ('SP_PROFILE_TABLE', ?, 'PROFILE', ?, ?, ?)",
        params=[run_id, status, rows, message[:4000]],
    ).collect()


def run(session, table_name, run_id):
    try:
        if not re.fullmatch(r"[A-Za-z_]+\.[A-Za-z0-9_]+", table_name or ""):
            raise ValueError(f"invalid table name {table_name!r}")
        schema, table = [p.upper() for p in table_name.split(".")]
        if schema not in ALLOWED_SCHEMAS:
            raise ValueError(f"schema {schema} not allowed for profiling")
        exists = session.sql(
            "SELECT COUNT(*) AS N FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA = ? AND TABLE_NAME = ?",
            params=[schema, table],
        ).collect()[0]["N"]
        if exists == 0:
            raise ValueError(f"{schema}.{table} not found")

        df = session.table(f"{schema}.{table}")
        fields = df.schema.fields
        aggs = [F.count(F.lit(1)).alias("__ROWS")]
        for i, f in enumerate(fields):
            col = F.col(f.column_identifier.quoted_name)
            aggs.append(F.count_if(col.is_null()).alias(f"N{i}"))
            if isinstance(f.datatype, (VariantType, ArrayType, MapType)):
                aggs += [F.lit(None).alias(f"D{i}"), F.lit(None).alias(f"MN{i}"), F.lit(None).alias(f"MX{i}")]
            else:
                aggs += [F.approx_count_distinct(col).alias(f"D{i}"),
                         F.min(col).cast(StringType()).alias(f"MN{i}"),
                         F.max(col).cast(StringType()).alias(f"MX{i}")]
        r = df.agg(*aggs).collect()[0]   # single scan of the table
        rows = [(run_id, f"{schema}.{table}", f.name, str(f.datatype), r["__ROWS"],
                 r[f"N{i}"], r[f"D{i}"], r[f"MN{i}"], r[f"MX{i}"]) for i, f in enumerate(fields)]
        out = session.create_dataframe(rows, schema=["PROFILE_RUN_ID", "TABLE_NAME", "COLUMN_NAME", "DATA_TYPE",
                                                     "ROW_COUNT", "NULL_COUNT", "DISTINCT_COUNT", "MIN_VALUE", "MAX_VALUE"])
        out.write.mode("append").save_as_table("AUDIT.DATA_PROFILE", column_order="name")
        _log(session, run_id, "SUCCESS", f"profiled {schema}.{table}", len(rows))
        return {"status": "SUCCESS", "table": f"{schema}.{table}", "columns": len(rows), "rows": r["__ROWS"]}
    except Exception as exc:  # logged, then surfaced to the caller / task
        _log(session, run_id, "FAILED", f"{type(exc).__name__}: {exc}")
        raise
$$;

-- Invoke / validate
-- CALL OPS.SP_PROFILE_TABLE('RAW.PAYMENTS', 'PROFILE-ADHOC');
-- SELECT * FROM AUDIT.DATA_PROFILE WHERE PROFILE_RUN_ID = 'PROFILE-ADHOC' ORDER BY COLUMN_NAME;
-- Expect one row per RAW.PAYMENTS column; ROW_COUNT equal to SELECT COUNT(*) FROM RAW.PAYMENTS.

------------------------------------------------------------------------
-- SQL-only alternative profiler (accounts without Python): row count and
-- null counts per column via generated dynamic SQL.
------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE OPS.SP_PROFILE_TABLE_SQL(P_SCHEMA VARCHAR, P_TABLE VARCHAR, P_RUN_ID VARCHAR)
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
    v_sql VARCHAR;
BEGIN
    SELECT 'INSERT INTO AUDIT.DATA_PROFILE (PROFILE_RUN_ID, TABLE_NAME, COLUMN_NAME, DATA_TYPE, ROW_COUNT, NULL_COUNT) ' ||
           LISTAGG('SELECT ''' || :P_RUN_ID || ''', ''' || TABLE_SCHEMA || '.' || TABLE_NAME || ''', ''' || COLUMN_NAME ||
                   ''', ''' || DATA_TYPE || ''', COUNT(*), COUNT_IF("' || COLUMN_NAME || '" IS NULL) FROM ' ||
                   TABLE_SCHEMA || '.' || TABLE_NAME, ' UNION ALL ') WITHIN GROUP (ORDER BY ORDINAL_POSITION)
      INTO :v_sql
    FROM INFORMATION_SCHEMA.COLUMNS
    WHERE TABLE_SCHEMA = UPPER(:P_SCHEMA) AND TABLE_NAME = UPPER(:P_TABLE);
    IF (v_sql IS NULL) THEN
        RETURN 'table not found';
    END IF;
    EXECUTE IMMEDIATE :v_sql;
    RETURN 'profiled';
END;
$$;
