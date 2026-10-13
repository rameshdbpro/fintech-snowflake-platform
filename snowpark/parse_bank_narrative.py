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
