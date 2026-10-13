"""CI/dev tool. Usage (from dbt/): python ../tools/offline_compile.py full|incremental <profiles_dir>
Offline dbt compile: renders all Jinja with dbt-snowflake but never connects.
get_relation -> None means every incremental model compiles in full-refresh form;
a second pass with a fake relation compiles the incremental branches too."""
import sys, os
from dbt.cli.main import dbtRunner
from dbt.adapters.snowflake import SnowflakeAdapter
from dbt.adapters.snowflake.relation import SnowflakeRelation
mode = sys.argv[1]  # full | incremental
def fake_get_relation(self, database, schema, identifier):
    if mode == 'incremental':
        return SnowflakeRelation.create(database=database, schema=schema, identifier=identifier, type='table')
    return None
SnowflakeAdapter.get_relation = fake_get_relation
res = dbtRunner().invoke(["compile", "--no-populate-cache", "--profiles-dir", sys.argv[2],
                          "--target-path", f"target_{mode}", "--quiet"])
print("SUCCESS" if res.success else f"FAILED: {res.exception}")
if not res.success and res.result:
    for r in res.result:
        if r.status != 'success': print(r.node.name, r.status, r.message)
