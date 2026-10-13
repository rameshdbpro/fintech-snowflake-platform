"""Developer tool (not needed at runtime): embeds snowpark/parse_bank_narrative.py
into snowflake/08_snowpark.sql so the deployed UDF is byte-identical to the
unit-tested source.   Usage: python tools/build_snowpark_sql.py [--check]"""
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
template = (ROOT / "snowflake" / "08_snowpark.sql.template").read_text()
source = (ROOT / "snowpark" / "parse_bank_narrative.py").read_text().rstrip("\n")
if "$$" in source:
    sys.exit("python source must not contain $$")
rendered = template.replace("{{PYTHON_SOURCE}}", source)
target = ROOT / "snowflake" / "08_snowpark.sql"
if "--check" in sys.argv:
    ok = target.exists() and target.read_text() == rendered
    print("08_snowpark.sql is up to date" if ok else "08_snowpark.sql is STALE - rebuild")
    sys.exit(0 if ok else 1)
target.write_text(rendered)
print(f"wrote {target.relative_to(ROOT)}")
