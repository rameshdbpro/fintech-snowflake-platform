# Security and Governance

| Control | Implementation (`snowflake/10_security_governance.sql` unless noted) |
|---|---|
| RBAC, least privilege | Functional roles per duty (deployer, loader, transformer, ops, analyst, regional analyst, KYC officer, AI user, config approver); grants only on the schemas each needs. Analysts never get RAW/LANDING. |
| Environment separation | Separate databases DEV/TEST/PROD; dbt targets map 1:1; CI promotes the same commit. |
| Deployment vs execution | FINTECH_DEPLOYER owns objects and is used only by CI (`SVC_DEPLOY`); FINTECH_TRANSFORMER executes dbt (`SVC_DBT_*`) and cannot grant (managed-access schemas). |
| Masked / tokenised identifiers | No PAN/VPA/account number is ever ingested: instruments are provider tokens + last 4. PAN on customers is synthetic and stored as `pan_token` (SHA-256) downstream. |
| Restricted KYC | Masking policies on names, e-mail, phone, DOB, PAN, KYC document type; clear values only for FINTECH_KYC_OFFICER (and the dbt service role that builds the tables). |
| Row access | `RAP_MERCHANT_REGION` on merchant-level marts; regional roles mapped in `CONFIG.ROW_ACCESS_MAP` (changeable via the change workflow). |
| Classification | Tag `GOVERNANCE.DATA_CLASS` (PII / KYC / FINANCIAL). |
| Audit logging | AUDIT schema (see operations.md) + ACCESS_HISTORY query for PII reads. |
| Secrets | No passwords or tokens in any file. Service users use key-pair auth (`TYPE = SERVICE`); dbt profile reads env vars; CI secrets stay in the CI secret store. |
| AI safety | Read-only AI role, dedicated warehouse with timeout + resource monitor, semantic-view scope. |
| Retention | Guidance in section 7 of the script (RAW 13 months, AUDIT ≥ 7 years if regulatory evidence, Time Travel 1/7 days). |

Edition note: masking and row access policies and tags require Enterprise Edition or higher. On Standard edition,
skip sections 2–3 and build dbt with `--vars '{apply_governance_policies: false}'`; restrict PII by not granting
CANONICAL/RAW and by excluding PII columns from analyst-facing views.
