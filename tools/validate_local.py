"""Local (no-Snowflake) validation of the project artifacts. CI/dev tool only.

Checks
 1. Every top-level statement in snowflake/*.sql and snowsight/*.sql is split
    correctly (quotes, comments, $$ bodies) and parsed by sqlglot's Snowflake
    dialect, except statement kinds sqlglot does not model (reported, not failed).
 2. Python bodies embedded in $$ blocks (LANGUAGE PYTHON) compile.
 3. 08_snowpark.sql embeds exactly snowpark/parse_bank_narrative.py.
 4. Every DASHBOARD.VW_* view required by the spec is defined.
 5. Every object referenced as DASHBOARD.VW_* in snowsight/ exists in 11/13.
 6. All 12 RAW tables are created.
Exit code 1 on any hard failure.
Usage: python tools/validate_local.py
"""
import glob
import os
import re
import sys

import sqlglot
from sqlglot.errors import ParseError

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
failures, notes = [], []

# sqlglot has no grammar for these Snowflake statement kinds; they are checked by review / in Snowflake.
UNMODELLED = re.compile(
    r"^\s*(CREATE\s+(OR\s+REPLACE\s+|OR\s+ALTER\s+)?(PROCEDURE|FUNCTION|TASK|ALERT|STREAM|STAGE|FILE\s+FORMAT|"
    r"MASKING\s+POLICY|ROW\s+ACCESS\s+POLICY|TAG|SEMANTIC\s+VIEW|AGENT|CORTEX\s+SEARCH\s+SERVICE|RESOURCE\s+MONITOR|"
    r"WAREHOUSE|ROLE|DATABASE|SCHEMA|NOTIFICATION)|ALTER\s+(TASK|ALERT|WAREHOUSE|SCHEMA|TABLE\s+\S+\s+(MODIFY|SET|ADD|DROP))|"
    r"GRANT|REVOKE|CALL|EXECUTE|SET\s|USE\s|MERGE|SHOW|COPY)",
    re.I,
)


def split_statements(sql):
    out, buf, i, n = [], [], 0, len(sql)
    while i < n:
        c = sql[i]
        if sql.startswith("$$", i):
            j = sql.index("$$", i + 2) + 2
            buf.append(sql[i:j]); i = j; continue
        if sql.startswith("--", i):
            j = sql.find("\n", i); j = n if j == -1 else j
            i = j; continue
        if sql.startswith("/*", i):
            i = sql.index("*/", i) + 2; continue
        if c == "'":
            j = i + 1
            while j < n:
                if sql[j] == "\\": j += 2; continue
                if sql[j] == "'":
                    if j + 1 < n and sql[j + 1] == "'": j += 2; continue
                    break
                j += 1
            buf.append(sql[i:j + 1]); i = j + 1; continue
        if c == ";":
            s = "".join(buf).strip()
            if s: out.append(s)
            buf = []; i += 1; continue
        buf.append(c); i += 1
    s = "".join(buf).strip()
    if s: out.append(s)
    return out


parsed = skipped = 0
python_bodies = 0
for path in sorted(glob.glob(os.path.join(ROOT, "snowflake", "*.sql")) + glob.glob(os.path.join(ROOT, "snowsight", "*.sql"))):
    rel = os.path.relpath(path, ROOT)
    for stmt in split_statements(open(path).read()):
        if re.search(r"LANGUAGE\s+PYTHON", stmt, re.I):
            body = stmt[stmt.index("$$") + 2: stmt.rindex("$$")]
            try:
                compile(body, f"{rel}:python", "exec"); python_bodies += 1
            except SyntaxError as e:
                failures.append(f"{rel}: python body does not compile: {e}")
        if UNMODELLED.match(stmt):
            skipped += 1; continue
        try:
            # Snowflake session variables ($x) are not modelled by sqlglot
            sqlglot.parse_one(re.sub(r"(?<!\w)\$(\w+)", r"'\1'", stmt), read="snowflake"); parsed += 1
        except ParseError as e:
            failures.append(f"{rel}: {str(e).splitlines()[0][:160]}\n      {stmt[:120]!r}")

# 3. embedded UDF == tested source
tpl_ok = os.system(f"{sys.executable} {os.path.join(ROOT, 'tools', 'build_snowpark_sql.py')} --check > /dev/null") == 0
if not tpl_ok:
    failures.append("08_snowpark.sql is stale versus snowpark/parse_bank_narrative.py")

# 4./5. dashboard views
views_sql = open(os.path.join(ROOT, "snowflake", "11_dashboard_views.sql")).read() + \
            open(os.path.join(ROOT, "snowflake", "13_cortex_ai.sql")).read()
defined = set(re.findall(r"CREATE OR REPLACE VIEW DASHBOARD\.(VW_\w+)", views_sql))
required = {"VW_EXECUTIVE_PAYMENT_KPIS", "VW_DAILY_PAYMENT_TREND", "VW_PAYMENT_CHANNEL_PERFORMANCE",
            "VW_MERCHANT_PERFORMANCE", "VW_REFUND_AND_CHARGEBACK_SUMMARY", "VW_SETTLEMENT_RECONCILIATION_SUMMARY",
            "VW_DATA_QUALITY_STATUS", "VW_PIPELINE_EXECUTION_STATUS", "VW_FRAUD_MONITORING_SUMMARY"}
for v in sorted(required - defined):
    failures.append(f"missing required dashboard view {v}")
for path in glob.glob(os.path.join(ROOT, "snowsight", "*.sql")):
    for v in set(re.findall(r"DASHBOARD\.(VW_\w+)", open(path).read())) - defined:
        failures.append(f"{os.path.basename(path)} references undefined DASHBOARD.{v}")

# 6. RAW tables
raw_sql = open(os.path.join(ROOT, "snowflake", "01_raw_tables.sql")).read()
raw_tables = set(re.findall(r"CREATE TABLE IF NOT EXISTS RAW\.(\w+)", raw_sql))
if len(raw_tables) != 12:
    failures.append(f"expected 12 RAW tables, found {len(raw_tables)}: {sorted(raw_tables)}")

print(f"SQL statements parsed by sqlglot (snowflake dialect): {parsed}")
print(f"Snowflake-specific statements not modelled by sqlglot (reviewed, not parsed): {skipped}")
print(f"Embedded Python bodies compiled: {python_bodies}")
print(f"Dashboard views defined: {len(defined)} (required 9 present: {required <= defined})")
print(f"RAW tables defined: {len(raw_tables)}")
if failures:
    print("\nFAILURES:")
    for f in failures:
        print(" -", f)
    sys.exit(1)
print("\nALL LOCAL CHECKS PASSED")
