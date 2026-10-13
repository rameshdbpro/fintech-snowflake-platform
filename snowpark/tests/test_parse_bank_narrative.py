"""CI unit tests for the Snowpark UDF handler (plain Python, no Snowflake needed).
Run: python -m pytest snowpark/tests  (or: python snowpark/tests/test_parse_bank_narrative.py)
"""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from parse_bank_narrative import parse  # noqa: E402

# Same rows as CONFIG.BANK_NARRATIVE_PATTERN (02_config_tables.sql), unescaped.
PATTERNS = [
    {"bank_code": "HDFC", "priority": 1, "pattern": r"SETTL\s+SB-(?P<prov>[A-Z]{2})-(?P<dt>\d{8})"},
    {"bank_code": "ICICI", "priority": 1, "pattern": r"/SETTLEMENT/SB(?P<prov>[A-Z]{2})(?P<dt>\d{8})/"},
    {"bank_code": "SBI", "priority": 1, "pattern": r"ref:SB_(?P<prov>[A-Z]{2})_(?P<dt>\d{8})"},
    {"bank_code": "*", "priority": 99, "pattern": r"SB[-_]?(?P<prov>[A-Z]{2})[-_]?(?P<dt>20\d{6})"},
]


def test_hdfc():
    r = parse("NEFT CR-HDFC0000123-PROVIDER PAYMENTS-SETTL SB-PA-20260401", "HDFC", PATTERNS)
    assert r["settlement_ref"] == "SB-PA-20260401" and r["match_source"] == "BANK_PATTERN"


def test_icici_normalises_compact_reference():
    r = parse("IMPS/P2A/612345678901/SETTLEMENT/SBPB20260401/PROVB", "ICICI", PATTERNS)
    assert r["settlement_ref"] == "SB-PB-20260401"


def test_sbi_underscores():
    r = parse("BY TRANSFER-INB ref:SB_PC_20260401 PROVIDER-C", "SBI", PATTERNS)
    assert r["settlement_ref"] == "SB-PC-20260401" and r["settlement_date"] == "2026-04-01"


def test_unknown_bank_uses_generic_fallback():
    r = parse("RTGS INWARD SBPX20260415 BETA", "AXIS", PATTERNS)
    assert r["settlement_ref"] == "SB-PX-20260415" and r["match_source"] == "GENERIC_PATTERN"


def test_non_settlement_entry():
    r = parse("INT.CREDIT CURRENT ACCOUNT", "HDFC", PATTERNS)
    assert r["settlement_ref"] is None and r["match_source"] == "NO_MATCH"


def test_invalid_calendar_date_rejected():
    r = parse("NEFT CR-SETTL SB-PA-20260231", "HDFC", PATTERNS)
    assert r["settlement_ref"] is None and any("invalid date" in e for e in r["errors"])


def test_bad_pattern_reported_not_raised():
    bad = [{"bank_code": "HDFC", "priority": 1, "pattern": "SB-(?P<prov"}] + PATTERNS
    r = parse("NEFT CR-HDFC-SETTL SB-PA-20260401", "HDFC", bad)
    assert r["settlement_ref"] == "SB-PA-20260401" and r["errors"]


def test_null_inputs():
    assert parse(None, "HDFC", PATTERNS)["match_source"] == "NULL_NARRATIVE"
    assert parse("SETTL SB-PA-20260401", None, None)["settlement_ref"] is None


def test_edge_case_batches():
    assert parse("NEFT CR-HDFC0000123-PROVIDER PAYMENTS-SETTL SB-PE-20260411", "HDFC", PATTERNS)["settlement_ref"] == "SB-PE-20260411"
    assert parse("NEFT CR-HDFC0000123-PROVIDER PAYMENTS-SETTL SB-PE-20260413", "HDFC", PATTERNS)["settlement_ref"] == "SB-PE-20260413"


if __name__ == "__main__":
    tests = [v for k, v in sorted(globals().items()) if k.startswith("test_")]
    for t in tests:
        t()
    print(f"{len(tests)} tests passed")
