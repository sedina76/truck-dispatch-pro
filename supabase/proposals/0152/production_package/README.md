# Production package (Proposal 0152) -- PREPARED, NOT RUN, NOT AUTHORIZED

Nothing in this directory has been run against production, staging or any hosted project. Nothing here approves, certifies or authorizes production execution. Running anything below against production needs **separate written Owner authorization**, given at the time.

| file | purpose | changes anything? |
|---|---|---|
| `discovery_guard.py` | `check-files` statically proves the discovery/conflict SQL is read-only (no network); `confirm-target` refuses unless the reference equals the explicitly configured production ref, is not the deleted test project, and the typed confirmation matches. **Never connects.** | no |
| `../freeze/01_discovery_readonly.sql` (**P01**) | version, identity, roles, memberships, role/database settings, sessions, pg_cron + jobs, schema/table inventory | no (one SELECT) |
| `P02_schema_objects_readonly.sql` | extensions, schemas, tables/owners/RLS, policies, sequences, default privileges, triggers, event triggers, publications, migration history, and presence of every table/column 0150 treats as evidence (finding F-11) | no (one SELECT) |
| `P03_privileges_readonly.sql` | table/column/function privileges; SECURITY DEFINER functions with anon/PUBLIC EXECUTE (blocker F-05); DELETE privileges on financial tables | no (one SELECT) |
| `../../../PRODUCTION_PREFLIGHT_0130_0147_READONLY.sql` (**P04**) and `../*/preflight.sql` | the existing reviewed boundary/landmark audits and per-proposal preflights | no |
| `legacy_conflict_queries.sql` (**P05**) | Q01-Q16 conflict queries behind `../LEGACY_CONFLICT_WORKSHEET.md`; run ONE at a time | no |
| `static_scan_migrations.py` | reproducible repository-only scan behind findings F-05/F-09/F-14 | no |
| `check_risk_acceptance.py` | mechanical check of a completed `../OWNER_RISK_ACCEPTANCE.md` copy | no |
| `api_freeze_probe_production.py` | production external freeze probe: **refuses by default** (see its docstring) | only sends requests to the dedicated probe objects when explicitly run in the window |
| `PROD_PROBE_FIXTURE_PROPOSAL.sql` / `PROD_PROBE_FIXTURE_CLEANUP.sql` | the dedicated probe objects and their removal: **PROPOSALS, not applied, need separate Owner approval** | yes if applied (additive) |
| `tests_production_package.py` | local tests of all of the above (disposable local PostgreSQL + local mock server only) | disposable only |

## Discovery procedure (only after Owner authorization; nothing is run by the assistant)
1. `python3 discovery_guard.py check-files` -> every file `ok`.
2. Export `TDP_PROD_PROJECT_REF=<the production ref>`; `python3 discovery_guard.py confirm-target --ref <ref> --confirm 'DISCOVER PRODUCTION <ref>'` -> `GO`. **Then compare the ref with the Supabase dashboard URL/Settings yourself**: SQL cannot know its own project ref, so this is a human gate.
3. In the SQL Editor of that project only, run **one file at a time**: P01, P02, P03, then P04's audit, then Q01..Q16 individually. Save every result outside the repository. These files contain no secrets and select no passwords.
4. **The results must be reviewed by the Owner and the Reviewer before any production freeze or migration.** Discovery is separate from every mutating command: nothing in this package mutates, and no mutating script may be run in the same step.
5. Stop conditions after discovery: any P03 row 20/21 (anon/PUBLIC EXECUTE on a SECURITY DEFINER function); any worksheet query with unresolved records; pg_cron installed or any relevant cron job (separate hosted pg_cron test required); any schema/table not classified for the freeze; any deviation from the expected 0129 boundary.

## F-30 synthetic role/grant extension (local preparation only)

`role_fixture/README.md` documents the guarded two-organization model, deterministic identities, exact pilot authorization matrix, generated install/reset/cleanup/verification files, and local tests. `api_freeze_probe_production.py --role-model` adds its role/tenant probes to the existing generic freeze probe; this option **refuses production** and requires a separately designated non-production reference, trusted database marker, PostgreSQL 17.6, matching fixture fingerprints and all synthetic identity tokens before writes. The generic probe assertions are unchanged.

The fixture records synthetic action receipts; it does not apply application migrations, issue financial documents or enable factoring. Local tests model direct, reused transaction-pool and new physical backends using disposable Unix-socket PostgreSQL. They do not establish hosted Supavisor/PostgREST behavior. A replacement test project must be created and positively identified before any hosted rerun; none is configured or contacted by these preparation scripts.
