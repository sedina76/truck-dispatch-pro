# Static review packet — NOT APPROVED FOR PRODUCTION

Expanded tests and SQL have NOT been executed. This packet authorizes no execution.

## Exact operations

1. Runner creates a fresh local cluster and two NOLOGIN roles (`anon`,
   `authenticated`), then databases `td0148_reference` and `td0148_model`.
2. Fixture creates only synthetic schemas, tables, functions, constraints, triggers,
   indexes, policies, grants and rows inside those databases. It installs dormant
   0072 functions containing UPDATE statements; tests do not call those functions.
3. Reference target applies the source-derived 0136 schema fragment, the 0138
   classifier, new carrier index and 23 explicit anon revocations.
4. Candidate acquires advisory key (148,148) and alphabetically ordered exclusive
   public-table locks; unknown pre-state or row hashes abort. DDL/revocations and
   exact post-state comparison share one transaction with bounded timeouts.
5. Existing delete policies are preserved only after matching complete manifest
   tuples: table, name, command, roles, permissiveness, USING and WITH CHECK.
6. No carrier ownership is populated by repair; no provenance or migration-history
   objects are created. No existing financial/recipient fields are updated.
7. Backfill stays disabled; preview is read-only and aggregate-only. Old default
   index and old default-setting RPC remain until a separately approved cutover.

## Destructive and privilege-changing statements and targets

| Context | Operation / explicit target |
|---|---|
| Fixture | Drop/recreate `set_updated_at` on factoring_companies and factoring_relationships; `factoring_relationships_guard_org`; `factoring_companies_guard_deactivation`. Fresh model only. |
| Fixture | Drop/recreate `factoring_companies_delete` and `factoring_relationships_delete` on their respective public tables, using modeled 0140 definitions. |
| Schema stage | Replace `guard_factoring_relationship_org()`; drop/recreate `factoring_relationships_guard_org`; drop-if-present/create `factoring_relationships_guard_protected_fields`. |
| Schema stage | Revoke DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE from anon on the exact 23 tables listed below. |
| Schema stage | Revoke PUBLIC execution on the new classifier and grant authenticated execution. |
| Rollback | Drop new `classify_carrier_factoring_readiness(uuid,uuid,uuid)` and `factoring_relationships_one_default_per_carrier`. |
| Rollback | Drop new protected-fields trigger/function and replace org guard/trigger with exact modeled legacy body. |
| Rollback | Drop only 14 newly added factoring_relationships columns and carriers.factoring_mode. |
| Rollback | Drop carrier_factoring_mode and factoring_submission_method types. Convert integration_settings.provider temporarily to text, drop/recreate the model's integration_provider enum, cast back. No CASCADE. |
| Rollback | Restore the exact seven anon privileges on the 23 synthetic tables. This is a LOCAL rollback test, never authorization to restore insecure production privileges. |
| Negative tests | One synthetic invoice's amount_paid and one synthetic relationship's carrier_id are changed in deliberately aborted transactions; no committed cleanup or backfill. |
| Negative tests | Introduce ACL/default/policy/trigger/enum/table/history drift within deliberately aborted transactions. |
| Filesystem cleanup | `shutil.rmtree` only on the validated generated cluster root, only after successful shutdown and successful tests. |

Added relationship columns: carrier_id, remittance_instructions,
remittance_reference, noa_template_text, noa_document_id, noa_reference,
noa_effective_date, noa_approved, noa_approved_by, noa_approved_at,
submission_method, submission_destination_email, submission_integration_id,
submission_notes.

23 tables: public.activity_logs, public.brokers, public.carriers, public.customers,
public.dispatches, public.documents, public.drivers, public.factored_invoices,
public.factoring_companies, public.factoring_events, public.factoring_relationships,
public.integration_settings, public.invoice_line_items, public.invoices,
public.load_stops, public.loads, public.organizations, public.payments,
public.profiles, public.settlement_line_items, public.settlements, public.trailers,
public.trucks.

There is no DROP DATABASE, DROP TABLE, TRUNCATE statement or DELETE FROM in the
candidate/rollback/test flow. TRUNCATE and DELETE occur in privilege lists.
Foreign-key ON DELETE clauses are definitions, not executed deletions.
No DROP of the old organization-scoped index exists anywhere in the package.

## Isolation and inspection

- Root: `tempfile.mkdtemp(prefix="td0148-local-", dir="/private/tmp")`, mode 0700.
- Socket `<root>/socket`, data `<root>/data`, log `<root>/server.log`; port 55489.
- Control DB/user postgres; workload DB names are explicit and allowlisted.
- Empty listen_addresses; runtime NULL inet_server_addr and full identity checks.
- Explicit child environment, no PGSERVICE or inherited PG variables. HOME and
  TMPDIR point inside root. Nonexistent local PGSERVICEFILE and empty 0600
  PGPASSFILE prevent home service/password-file fallback; psql uses -X -w.
- Absolute Homebrew binaries, subprocess argument lists, no shell=True; shlex.join
  protects pg_ctl's option string. No subprocess command comes from database data.
- SQL is captured after exact SHA-256 checks and passed through stdin. The sole
  psql meta-command is `\set ON_ERROR_STOP on`. No includes or shell escapes.
- Reviewed SQL contains no dblink, foreign server/FDW, COPY PROGRAM, filesystem
  writing calls, external connection, production URL/project credential or repository
  write. Dynamic SQL only quotes local catalog identifiers for SELECT/LOCK.
- try/finally, SIGINT/SIGTERM handling and atexit shut down the exact data directory.
- Root owner/mode/inode/device and descendant containment are revalidated; cleanup
  refuses symlinks, device changes and unsafe rmtree implementations.
- Failures retain root, server log and any completed synthetic catalog/hash evidence.
  Successful runs remove all cluster artifacts; no repository writes during tests.

## Remaining risks and required approvals

No exact live catalog manifest exists here. Synthetic auth is not a real JWT/RLS
security test. Schema/row normalization is logical, not physical byte preservation.
The reference uses the same schema fragment: it cannot independently validate the
specification. This is a bounded fixture serializer, not exhaustive coverage of
all PostgreSQL dependency types or version-specific catalog details. A runtime
rehearsal is still needed; static review does not establish SQL compatibility.

Enum reversal is safe only under the modeled exact dependencies and original rows.
Unexpected dependencies should cause transaction failure, never CASCADE. Real
production enum reversal needs separate DBA design. Full 0137 backfill, signed
approval enforcement, old-index removal and full 0138/0139–0147 transitions are
unimplemented. New NULL columns and the new partial index alone do not establish
carrier-default completeness. No financial cleanup is safe automatically.

Trusted binaries, trusted same-user filesystem state, and a functioning OS are
assumptions. SIGKILL/power loss can bypass finalizers. Concurrent hostile DDL by
another superuser is outside the isolated cluster model. The 0.5-second test pause
encourages overlapping apply attempts; it is not a broad business-workload test.

Approvals outstanding: review/authorization to run this expanded local rehearsal;
Security and Application Security privilege/RPC review; Lead DBA exact-state,
repair, dependency, rollback and verifier approval; Finance/AR aggregate and recipient
review; Factoring Operations lifecycle/ownership/default semantics approval;
Release/change manager maintenance, traffic-control and final-audit approval.

No production remediation may begin until all required approvals are recorded.
