-- Production preflight for migrations 0130-0147. READ ONLY.
-- Run with psql -X -v ON_ERROR_STOP=1 -f this_file.sql and preserve all output.
-- Optional-schema rows are inspected through to_jsonb(record), so absent later
-- columns never cause parse errors. Optional tables are queried only by SELECTs
-- emitted from catalog-confirmed names through psql's \gexec.
\set ON_ERROR_STOP on
\pset pager off
begin transaction read only;

-- Every migration has a landmark introduced at its boundary. Prefix violations
-- identify partial/manual installation. A completely absent or complete prefix is
-- valid; deployment readiness is evaluated separately from post-0146 health.
with landmarks(migration, present) as (values
 ('0130',to_regclass('public.carrier_remittance_profiles') is not null),
 ('0131',to_regclass('public.carrier_brokers') is not null and to_regclass('public.carrier_customers') is not null),
 ('0132',to_regclass('public.trailer_ownership_scope_audit') is not null),
 ('0133',to_regclass('public.carrier_backfill_0133_provenance') is not null),
 ('0134',to_regclass('public.dispatch_status_transitions') is not null),
 ('0135',to_regclass('public.dispatch_resource_reassignments') is not null),
 ('0136',exists(select 1 from information_schema.columns where table_schema='public' and table_name='factoring_relationships' and column_name='carrier_id')),
 ('0137',to_regclass('public.carrier_backfill_0137_provenance') is not null),
 ('0138',to_regprocedure('public.set_default_factoring_relationship(uuid)') is not null),
 ('0139',to_regclass('public.carrier_factoring_integrations') is not null),
 ('0140',exists(select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname='approve_factoring_relationship_noa')),
 ('0141',to_regclass('public.factoring_integration_lifecycle_idempotency') is not null),
 ('0142',to_regclass('public.carrier_invoices') is not null and to_regclass('public.carrier_invoice_issuance_snapshots') is not null),
 ('0143',exists(select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname='update_carrier_invoice_draft')),
 ('0144',to_regprocedure('public.guard_load_stops_parent_lock()') is not null),
 ('0145',to_regclass('public.carrier_dispatch_service_agreements') is not null),
 ('0146',to_regclass('public.carrier_invoice_payments') is not null)
), x as (select *, bool_or(not present) over(order by migration) as absent_seen from landmarks)
select 'migration_state' section, 'migration_'||migration check_name,
 case when present and lag(absent_seen,1,false) over(order by migration) then 'BLOCKER' else 'INFO' end severity,
 not (present and lag(absent_seen,1,false) over(order by migration)) ok,
 (present::int)::bigint affected_count,
 case when present then 'landmark present' else 'landmark absent' end details,
 'Objects must form one contiguous applied prefix; investigate manual/partial application.' remediation
from x order by migration;

with c as (select organization_id,count(*) n from public.carriers group by organization_id)
select 'organizations_carriers' section, v.check_name, v.severity, v.ok, v.affected_count, v.details, v.remediation
from (values
 ('organization_count','INFO',true,(select count(*) from public.organizations)::bigint,'Total organizations','None.'),
 ('organizations_zero_carriers','WARNING',(select count(*) from public.organizations o left join c on c.organization_id=o.id where c.organization_id is null)=0,(select count(*) from public.organizations o left join c on c.organization_id=o.id where c.organization_id is null)::bigint,'Organizations without carriers','Review whether these organizations should participate.'),
 ('organizations_one_carrier','INFO',true,(select count(*) from c where n=1)::bigint,'Single-carrier organizations','None.'),
 ('organizations_multiple_carriers','INFO',true,(select count(*) from c where n>1)::bigint,'Multi-carrier organizations','Review deterministic ownership evidence.'),
 ('active_carriers','INFO',true,(select count(*) from public.carriers where is_active)::bigint,'Active carriers','None.'),
 ('inactive_carriers','INFO',true,(select count(*) from public.carriers where not is_active)::bigint,'Inactive carriers','None.'),
 ('invalid_carrier_organization','BLOCKER',(select count(*) from public.carriers c left join public.organizations o on o.id=c.organization_id where o.id is null)=0,(select count(*) from public.carriers c left join public.organizations o on o.id=c.organization_id where o.id is null)::bigint,'Carrier references missing organization','Repair cross-organization/referential corruption before deployment.')
) v(check_name,severity,ok,affected_count,details,remediation);

with evidence as (
 select l.id,l.organization_id,
   nullif(to_jsonb(l)->>'carrier_id','')::uuid load_carrier,
   array_remove(array_agg(distinct d.carrier_id),null) dispatch_carriers,
   count(distinct d.carrier_id) filter(where d.status::text <> 'cancelled') candidates,
   bool_or(d.organization_id<>l.organization_id or c.organization_id<>l.organization_id) cross_org
 from public.loads l left join public.dispatches d on d.load_id=l.id
 left join public.carriers c on c.id=d.carrier_id group by l.id,l.organization_id
), classified as (
 select *, coalesce(array_length(dispatch_carriers,1),0)=1 as deterministic,
   load_carrier is not null and exists(select 1 from unnest(dispatch_carriers) x where x<>load_carrier) as conflict
 from evidence
)
select 'load_dispatch_trailer' section, v.check_name,v.severity,v.ok,v.affected_count,v.details,v.remediation from (values
 ('deterministic_load_carrier','INFO',true,(select count(*) from classified where load_carrier is not null or deterministic)::bigint,'Loads with deterministic carrier evidence','None.'),
 ('missing_carrier_evidence','WARNING',(select count(*) from classified where load_carrier is null and not deterministic)=0,(select count(*) from classified where load_carrier is null and not deterministic)::bigint,'Loads with no carrier evidence','Review; 0132/0133 records safe unresolved cases.'),
 ('multiple_non_cancelled_candidates','BLOCKER',(select count(*) from classified where candidates>1)=0,(select count(*) from classified where candidates>1)::bigint,'Loads with multiple non-cancelled carrier candidates','Resolve structural carrier ambiguity.'),
 ('dispatch_load_carrier_conflict','BLOCKER',(select count(*) from classified where conflict)=0,(select count(*) from classified where conflict)::bigint,'Dispatch carrier conflicts with load carrier','Resolve conflict before deployment.'),
 ('cross_organization_load_dispatch','BLOCKER',(select count(*) from classified where cross_org)=0,(select count(*) from classified where cross_org)::bigint,'Cross-organization load/dispatch/carrier references','Repair tenant boundary violation.')
) v(check_name,severity,ok,affected_count,details,remediation);

-- Legacy invoice facts; to_jsonb keeps this valid across additive column changes.
select 'legacy_invoices' section, x.check_name,x.severity,x.ok,x.affected_count,x.details,x.remediation from (values
 ('legacy_invoice_total','INFO',true,(select count(*) from public.invoices)::bigint,'Existing legacy invoices; migrations do not auto-convert them','Keep as historical records.'),
 ('paid_or_part_paid','INFO',true,(select count(*) from public.invoices where coalesce((to_jsonb(invoices)->>'amount_paid')::numeric,0)>0)::bigint,'Paid or partially-paid legacy invoices','Do not auto-convert.'),
 ('missing_recipient','WARNING',(select count(*) from public.invoices where broker_id is null and customer_id is null)=0,(select count(*) from public.invoices where broker_id is null and customer_id is null)::bigint,'Legacy invoices without broker/customer recipient','Review historically; do not invent recipient.'),
 ('conflicting_carrier_evidence','BLOCKER',(select count(*) from public.invoices i join public.dispatches d on d.id=i.dispatch_id join public.loads l on l.id=i.load_id where d.carrier_id is distinct from nullif(to_jsonb(l)->>'carrier_id','')::uuid)=0,(select count(*) from public.invoices i join public.dispatches d on d.id=i.dispatch_id join public.loads l on l.id=i.load_id where d.carrier_id is distinct from nullif(to_jsonb(l)->>'carrier_id','')::uuid)::bigint,'Legacy invoice dispatch/load carrier conflict','Resolve structural conflict.')
) x(check_name,severity,ok,affected_count,details,remediation);

-- Exact optional-table counts, emitted only after catalog validation. No value
-- from a configuration or snapshot payload is selected.
select format($q$select %L section,%L check_name,%L severity,true ok,count(*)::bigint affected_count,%L details,%L remediation from %I.%I;$q$,
 'optional_objects', table_name, 'INFO', 'Exact row count; no payload values selected.', 'Review count in context.', table_schema,table_name)
from information_schema.tables where table_schema='public' and table_name in
 ('carrier_remittance_profiles','unresolved_carrier_records','carrier_brokers','carrier_customers','factoring_companies','factoring_relationships','carrier_factoring_integrations','carrier_invoices','carrier_invoice_issuance_snapshots','carrier_invoice_payments','carrier_dispatch_service_agreements') order by table_name \gexec

select format($q$select 'carrier_invoice' section,'snapshot_version_'||issuance_schema_version||'_'||invoice_document_type::text check_name,
 case when to_regclass('public.carrier_invoice_payments') is null then 'BLOCKER' else 'INFO' end severity,
 to_regclass('public.carrier_invoice_payments') is not null ok,count(*)::bigint affected_count,
 'Snapshot counts by version and document type; payload omitted' details,
 'Before 0146 any snapshot is a hard stop; after 0146 preserve and review.' remediation
 from public.carrier_invoice_issuance_snapshots group by issuance_schema_version,invoice_document_type$q$)
where to_regclass('public.carrier_invoice_issuance_snapshots') is not null \gexec

-- Security posture: required extensions, RLS, and direct client grants.
select 'security' section,x.check_name,x.severity,x.ok,x.affected_count,x.details,x.remediation from (values
 ('pgcrypto_installed','BLOCKER',exists(select 1 from pg_extension where extname='pgcrypto'),(not exists(select 1 from pg_extension where extname='pgcrypto'))::int::bigint,'pgcrypto is required','Install through the approved migration path.'),
 ('btree_gist_for_0145','WARNING',to_regclass('public.carrier_dispatch_service_agreements') is null or exists(select 1 from pg_extension where extname='btree_gist'),(to_regclass('public.carrier_dispatch_service_agreements') is not null and not exists(select 1 from pg_extension where extname='btree_gist'))::int::bigint,'btree_gist required at/after 0145','Stop if 0145 objects exist without extension.'),
 ('protected_tables_without_rls','BLOCKER',not exists(select 1 from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relname in ('carrier_remittance_profiles','carrier_brokers','carrier_customers','carrier_invoices','carrier_invoice_issuance_snapshots','carrier_invoice_payments') and not c.relrowsecurity),(select count(*) from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relname in ('carrier_remittance_profiles','carrier_brokers','carrier_customers','carrier_invoices','carrier_invoice_issuance_snapshots','carrier_invoice_payments') and not c.relrowsecurity)::bigint,'Protected business tables missing RLS','Enable expected RLS/policies via the owning migration.'),
 ('unexpected_client_table_grants','BLOCKER',not exists(select 1 from information_schema.role_table_grants where table_schema='public' and table_name in ('carrier_invoice_issuance_snapshots','carrier_invoice_payments') and grantee='anon'),(select count(*) from information_schema.role_table_grants where table_schema='public' and table_name in ('carrier_invoice_issuance_snapshots','carrier_invoice_payments') and grantee='anon')::bigint,'Anonymous grants on protected financial tables','Compare grants with post-apply verifier and revoke unexpected access.')
) x(check_name,severity,ok,affected_count,details,remediation);

-- One computed decision. This deliberately repeats only decision inputs and
-- never calls application functions. Post-0146 rows are operational state,
-- while snapshots/payments at a pre-0146 partial boundary are blockers.
with lm(p) as (values
 (to_regclass('public.carrier_remittance_profiles') is not null),(to_regclass('public.carrier_brokers') is not null),
 (to_regclass('public.trailer_ownership_scope_audit') is not null),(to_regclass('public.carrier_backfill_0133_provenance') is not null),
 (to_regclass('public.dispatch_status_transitions') is not null),(to_regclass('public.dispatch_resource_reassignments') is not null),
 (exists(select 1 from information_schema.columns where table_schema='public' and table_name='factoring_relationships' and column_name='carrier_id')),
 (to_regclass('public.carrier_backfill_0137_provenance') is not null),(to_regprocedure('public.set_default_factoring_relationship(uuid)') is not null),
 (to_regclass('public.carrier_factoring_integrations') is not null),(exists(select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname='approve_factoring_relationship_noa')),
 (to_regclass('public.factoring_integration_lifecycle_idempotency') is not null),(to_regclass('public.carrier_invoices') is not null),
 (exists(select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname='update_carrier_invoice_draft')),(to_regprocedure('public.guard_load_stops_parent_lock()') is not null),
 (to_regclass('public.carrier_dispatch_service_agreements') is not null),(to_regclass('public.carrier_invoice_payments') is not null)
), state as (select count(*) filter(where p) present, bool_or(p and prior_absent) partial from (select p,bool_or(not p) over(rows between unbounded preceding and 1 preceding) prior_absent from lm) s),
conflicts as (select count(*) n from public.loads l join public.dispatches d on d.load_id=l.id where (nullif(to_jsonb(l)->>'carrier_id','') is not null and d.carrier_id<>nullif(to_jsonb(l)->>'carrier_id','')::uuid) or d.organization_id<>l.organization_id),
warns as (select count(*) n from public.loads l where nullif(to_jsonb(l)->>'carrier_id','') is null and not exists(select 1 from public.dispatches d where d.load_id=l.id))
select 'FINAL_DECISION' section,'overall_deployment_decision' check_name,
 case when not exists(select 1 from pg_class where oid=to_regclass('public.organizations')) then 'SCHEMA_STATE_UNKNOWN'
      when state.partial or conflicts.n>0 or not exists(select 1 from pg_extension where extname='pgcrypto') then 'BLOCKED'
      when warns.n>0 then 'READY_WITH_WARNINGS' else 'READY' end decision,
 (state.partial::int + (conflicts.n>0)::int + (not exists(select 1 from pg_extension where extname='pgcrypto'))::int) blocker_count,(warns.n>0)::int warning_count,
 (select count(*) from lm)::int informational_count,
 case when state.partial then 'STOP: investigate partial/manual migration objects.' when conflicts.n>0 then 'STOP: resolve carrier conflicts.' when not exists(select 1 from pg_extension where extname='pgcrypto') then 'STOP: required pgcrypto extension is missing.'
      when warns.n>0 then 'Review warnings, document unresolved records, then obtain go approval.' else 'Proceed only under the deployment runbook and authorization.' end required_next_action
from state,conflicts,warns;

-- Phase 3C.0A authoritative finding matrix. Earlier result sets are detail
-- diagnostics; only this matrix drives the computed decision for this slice.
-- All optional column reads use to_jsonb; optional relation counts use fixed,
-- SELECT-only literals after catalog detection. This file requires psql.
with
family(migration, a, b) as (values
 ('0130',to_regclass('public.carrier_remittance_profiles') is not null,exists(select 1 from information_schema.columns where table_schema='public' and table_name='carriers' and column_name='invoice_code')),
 ('0131',to_regclass('public.carrier_brokers') is not null,to_regclass('public.carrier_customers') is not null),
 ('0132',to_regclass('public.trailer_ownership_scope_audit') is not null,exists(select 1 from information_schema.columns where table_schema='public' and table_name='loads' and column_name='carrier_id')),
 ('0133',to_regclass('public.carrier_backfill_0133_provenance') is not null,coalesce(col_description(to_regclass('public.loads'),(select attnum from pg_attribute where attrelid=to_regclass('public.loads') and attname='carrier_id')) ilike '%backfilled by migration 0133%',false)),
 ('0134',to_regclass('public.dispatch_status_transitions') is not null,exists(select 1 from pg_proc p where p.pronamespace='public'::regnamespace and p.proname='transition_dispatch_status')),
 ('0135',to_regclass('public.dispatch_resource_reassignments') is not null,exists(select 1 from pg_proc p where p.pronamespace='public'::regnamespace and p.proname='reassign_dispatch_resources')),
 ('0136',exists(select 1 from information_schema.columns where table_schema='public' and table_name='factoring_relationships' and column_name='carrier_id'),exists(select 1 from information_schema.columns where table_schema='public' and table_name='carriers' and column_name='factoring_mode')),
 ('0137',to_regclass('public.carrier_backfill_0137_provenance') is not null,exists(select 1 from pg_policy where polname='carrier_backfill_0137_provenance_select')),
 ('0138',exists(select 1 from pg_proc p where p.pronamespace='public'::regnamespace and p.proname='classify_carrier_factoring_readiness'),exists(select 1 from pg_proc p where p.pronamespace='public'::regnamespace and p.proname='set_default_factoring_relationship')),
 ('0139',to_regclass('public.carrier_factoring_integrations') is not null,to_regclass('public.factoring_policy_idempotency') is not null),
 ('0140',exists(select 1 from pg_policy p where p.polname='factoring_relationships_delete'),exists(select 1 from pg_policy p where p.polname='factoring_companies_delete')),
 ('0141',to_regclass('public.factoring_integration_lifecycle_idempotency') is not null,exists(select 1 from pg_proc p where p.pronamespace='public'::regnamespace and p.proname='classify_carrier_factoring_readiness')),
 ('0142',to_regclass('public.carrier_invoices') is not null,to_regclass('public.carrier_invoice_issuance_snapshots') is not null),
 ('0143',exists(select 1 from pg_proc p where p.pronamespace='public'::regnamespace and p.proname='update_carrier_invoice_draft'),exists(select 1 from pg_proc p where p.pronamespace='public'::regnamespace and p.proname='compute_financial_request_fingerprint')),
 ('0144',to_regprocedure('public.guard_load_stops_parent_lock()') is not null,exists(select 1 from pg_proc p where p.pronamespace='public'::regnamespace and p.proname='issue_carrier_invoice')),
 ('0145',to_regclass('public.carrier_dispatch_service_agreements') is not null,to_regclass('public.carrier_dispatch_service_agreement_versions') is not null),
 ('0146',to_regclass('public.carrier_invoice_payments') is not null,to_regtype('public.carrier_invoice_payment_status') is not null),
 ('0147',to_regclass('public.carrier_invoice_draft_create_idempotency') is not null,exists(select 1 from pg_proc p where p.pronamespace='public'::regnamespace and p.proname='delete_carrier_invoice_draft'))
), fam as (select *, a and b installed,a<>b split from family),
-- The SQL text passed to query_to_xml is a fixed SELECT literal. The branch
-- executes only when both the relation and its version column exist.
history_catalog as (select to_regclass('supabase_migrations.schema_migrations') is not null present,
 exists(select 1 from pg_attribute where attrelid=to_regclass('supabase_migrations.schema_migrations') and attname='version' and not attisdropped) version_ok),
history_xml as (select case when present and version_ok then
 query_to_xml('SELECT version FROM supabase_migrations.schema_migrations',false,false,'') else null::xml end doc
 from history_catalog),
history_versions as (select regexp_replace((unnest(xpath('/table/row/version/text()',doc)))::text,'<[^>]+>','','g') version from history_xml where doc is not null),
history_state as (select f.migration,f.installed,
 exists(select 1 from history_versions h where h.version=f.migration) recorded from fam f),

cb_xml as (select case when to_regclass('public.carrier_brokers') is not null then query_to_xml('SELECT to_jsonb(t)::text AS payload FROM public.carrier_brokers t',false,false,'') else null::xml end doc),
cb as (select (unnest(xpath('/table/row/payload/text()',doc)))::text::jsonb j from cb_xml where doc is not null),
cc_xml as (select case when to_regclass('public.carrier_customers') is not null then query_to_xml('SELECT to_jsonb(t)::text AS payload FROM public.carrier_customers t',false,false,'') else null::xml end doc),
cc as (select (unnest(xpath('/table/row/payload/text()',doc)))::text::jsonb j from cc_xml where doc is not null),
fr_xml as (select case when to_regclass('public.factoring_relationships') is not null then query_to_xml('SELECT to_jsonb(t)::text AS payload FROM public.factoring_relationships t',false,false,'') else null::xml end doc),
fr as (select (unnest(xpath('/table/row/payload/text()',doc)))::text::jsonb j from fr_xml where doc is not null),
fc_xml as (select case when to_regclass('public.factoring_companies') is not null then query_to_xml('SELECT to_jsonb(t)::text AS payload FROM public.factoring_companies t',false,false,'') else null::xml end doc),
fc as (select (unnest(xpath('/table/row/payload/text()',doc)))::text::jsonb j from fc_xml where doc is not null),
toa_xml as (select case when to_regclass('public.trailer_ownership_scope_audit') is not null then query_to_xml('SELECT to_jsonb(t)::text AS payload FROM public.trailer_ownership_scope_audit t',false,false,'') else null::xml end doc),
toa as (select (unnest(xpath('/table/row/payload/text()',doc)))::text::jsonb j from toa_xml where doc is not null),
cfi_xml as (select case when to_regclass('public.carrier_factoring_integrations') is not null then query_to_xml('SELECT to_jsonb(t)::text AS payload FROM public.carrier_factoring_integrations t',false,false,'') else null::xml end doc),
cfi as (select (unnest(xpath('/table/row/payload/text()',doc)))::text::jsonb j from cfi_xml where doc is not null),
fi_xml as (select case when to_regclass('public.factored_invoices') is not null then query_to_xml('SELECT to_jsonb(t)::text AS payload FROM public.factored_invoices t',false,false,'') else null::xml end doc),
fi as (select (unnest(xpath('/table/row/payload/text()',doc)))::text::jsonb j from fi_xml where doc is not null),
pv_xml as (select case when to_regclass('public.carrier_backfill_0137_provenance') is not null then query_to_xml('SELECT to_jsonb(t)::text AS payload FROM public.carrier_backfill_0137_provenance t',false,false,'') else null::xml end doc),
pv as (select (unnest(xpath('/table/row/payload/text()',doc)))::text::jsonb j from pv_xml where doc is not null),
ur_xml as (select case when to_regclass('public.unresolved_carrier_records') is not null then query_to_xml('SELECT to_jsonb(t)::text AS payload FROM public.unresolved_carrier_records t',false,false,'') else null::xml end doc),
ur as (select (unnest(xpath('/table/row/payload/text()',doc)))::text::jsonb j from ur_xml where doc is not null),
docs_xml as (select case when to_regclass('public.documents') is not null then query_to_xml('SELECT to_jsonb(t)::text AS payload FROM public.documents t',false,false,'') else null::xml end doc),
docs as (select (unnest(xpath('/table/row/payload/text()',doc)))::text::jsonb j from docs_xml where doc is not null),
payments_xml as (select case when to_regclass('public.payments') is not null then query_to_xml('SELECT to_jsonb(t)::text AS payload FROM public.payments t',false,false,'') else null::xml end doc),
legacy_payments as (select (unnest(xpath('/table/row/payload/text()',doc)))::text::jsonb j from payments_xml where doc is not null),
legacy_review_xml as (select case when to_regclass('public.legacy_invoice_carrier_migration_review') is not null then query_to_xml('SELECT to_jsonb(t)::text AS payload FROM public.legacy_invoice_carrier_migration_review t',false,false,'') else null::xml end doc),
legacy_review as (select (unnest(xpath('/table/row/payload/text()',doc)))::text::jsonb j from legacy_review_xml where doc is not null),
-- Phase 3C.0E: carrier-invoice/snapshot/billing/payment optional-table
-- CTEs. Every one follows the SAME catalog-guarded query_to_xml/xpath
-- pattern as cb/cc/fr/fc/cfi above so this file remains valid against
-- every pre-0142 boundary fixture (the tables below do not exist there).
-- carrier_invoice_issuance_snapshots.snapshot_payload is NEVER selected
-- via to_jsonb(t) (that would serialize the full immutable financial
-- payload into this file's output) -- civs_ids selects only the
-- invoice_id column, and civs_problem selects only a derived,
-- version-aware problem_code (mirroring the installed
-- carrier_invoice_payment_snapshot_problem(uuid), 0146) plus a boolean
-- factoring flag, never any snapshot content.
civ_xml as (select case when to_regclass('public.carrier_invoices') is not null then query_to_xml('SELECT to_jsonb(t)::text AS payload FROM public.carrier_invoices t',false,false,'') else null::xml end doc),
civ as (select (unnest(xpath('/table/row/payload/text()',doc)))::text::jsonb j from civ_xml where doc is not null),
civp_xml as (select case when to_regclass('public.carrier_invoice_payments') is not null then query_to_xml('SELECT to_jsonb(t)::text AS payload FROM public.carrier_invoice_payments t',false,false,'') else null::xml end doc),
civp as (select (unnest(xpath('/table/row/payload/text()',doc)))::text::jsonb j from civp_xml where doc is not null),
cdsa_xml as (select case when to_regclass('public.carrier_dispatch_service_agreements') is not null then query_to_xml('SELECT to_jsonb(t)::text AS payload FROM public.carrier_dispatch_service_agreements t',false,false,'') else null::xml end doc),
cdsa as (select (unnest(xpath('/table/row/payload/text()',doc)))::text::jsonb j from cdsa_xml where doc is not null),
cdsav_xml as (select case when to_regclass('public.carrier_dispatch_service_agreement_versions') is not null then query_to_xml('SELECT to_jsonb(t)::text AS payload FROM public.carrier_dispatch_service_agreement_versions t',false,false,'') else null::xml end doc),
cdsav as (select (unnest(xpath('/table/row/payload/text()',doc)))::text::jsonb j from cdsav_xml where doc is not null),
cdsbl_xml as (select case when to_regclass('public.carrier_dispatch_service_billing_lines') is not null then query_to_xml('SELECT to_jsonb(t)::text AS payload FROM public.carrier_dispatch_service_billing_lines t',false,false,'') else null::xml end doc),
cdsbl as (select (unnest(xpath('/table/row/payload/text()',doc)))::text::jsonb j from cdsbl_xml where doc is not null),
civli_xml as (select case when to_regclass('public.carrier_invoice_lifecycle_idempotency') is not null then query_to_xml('SELECT to_jsonb(t)::text AS payload FROM public.carrier_invoice_lifecycle_idempotency t',false,false,'') else null::xml end doc),
civli as (select (unnest(xpath('/table/row/payload/text()',doc)))::text::jsonb j from civli_xml where doc is not null),
cdsai_xml as (select case when to_regclass('public.carrier_dispatch_service_agreement_idempotency') is not null then query_to_xml('SELECT to_jsonb(t)::text AS payload FROM public.carrier_dispatch_service_agreement_idempotency t',false,false,'') else null::xml end doc),
cdsai as (select (unnest(xpath('/table/row/payload/text()',doc)))::text::jsonb j from cdsai_xml where doc is not null),
-- Column-existence guards (not just table-existence) below: a partial/stub
-- installation fixture may create carrier_invoice_issuance_snapshots with
-- only some of its real columns, and referencing a specific column name
-- that a stub omits is a parse-time error inside query_to_xml regardless
-- of to_jsonb wrapping. Table-shape corruption itself remains caught by
-- SCHEMA_LANDMARK_0142/SCHEMA_PARTIAL above; these CTEs simply see no rows.
civs_shape_ok as (select
 exists(select 1 from information_schema.columns where table_schema='public' and table_name='carrier_invoice_issuance_snapshots' and column_name='invoice_id') has_invoice_id,
 exists(select 1 from information_schema.columns where table_schema='public' and table_name='carrier_invoice_issuance_snapshots' and column_name='snapshot_payload') has_payload,
 exists(select 1 from information_schema.columns where table_schema='public' and table_name='carrier_invoice_issuance_snapshots' and column_name='organization_id') has_org
),
civs_ids_xml as (select case when to_regclass('public.carrier_invoice_issuance_snapshots') is not null and (select has_invoice_id from civs_shape_ok) then query_to_xml('SELECT invoice_id::text AS invoice_id FROM public.carrier_invoice_issuance_snapshots',false,false,'') else null::xml end doc),
civs_ids as (select (unnest(xpath('/table/row/invoice_id/text()',doc)))::text invoice_id from civs_ids_xml where doc is not null),
civs_problem_xml as (select case when to_regclass('public.carrier_invoice_issuance_snapshots') is not null and to_regclass('public.carrier_invoices') is not null
 and (select has_invoice_id and has_payload and has_org from civs_shape_ok) then query_to_xml($sq$
 select to_jsonb(x)::text as payload from (
  select ci.id::text as invoice_id, ci.invoice_document_type::text as invoice_document_type,
   case
    when not (s.snapshot_payload ? 'schema_version') then 'VERSION_MISSING'
    when jsonb_typeof(s.snapshot_payload->'schema_version') = 'null' then 'VERSION_NULL'
    when jsonb_typeof(s.snapshot_payload->'schema_version') is distinct from 'number' then 'VERSION_NOT_NUMBER'
    when (s.snapshot_payload->>'schema_version')::numeric is distinct from 2 then 'VERSION_UNSUPPORTED'
    when (s.snapshot_payload->>'invoice_id') is distinct from ci.id::text then 'INVOICE_ID_MISMATCH'
    when (s.snapshot_payload->>'invoice_document_type') is distinct from ci.invoice_document_type::text then 'DOCUMENT_TYPE_MISMATCH'
    when s.organization_id is distinct from ci.organization_id then 'ORG_MISMATCH'
    when (s.snapshot_payload->>'currency') is distinct from ci.currency then 'CURRENCY_MISMATCH'
    when jsonb_typeof(s.snapshot_payload->'total_amount') is distinct from 'number' then 'TOTAL_AMOUNT_MISMATCH'
    when (s.snapshot_payload->>'total_amount')::numeric is distinct from ci.total_amount then 'TOTAL_AMOUNT_MISMATCH'
    when not (s.snapshot_payload ? 'factoring') then 'FACTORING_KEY_MISSING'
    when ci.invoice_document_type = 'carrier_freight_invoice' and jsonb_typeof(s.snapshot_payload->'issuer') is distinct from 'object' then 'ISSUER_MALFORMED'
    when ci.invoice_document_type = 'carrier_freight_invoice' and (s.snapshot_payload->'issuer'->>'carrier_id') is distinct from ci.carrier_id::text then 'CARRIER_ID_MISMATCH'
    when ci.invoice_document_type = 'carrier_freight_invoice' and jsonb_typeof(s.snapshot_payload->'recipient') is distinct from 'object' then 'RECIPIENT_MALFORMED'
    when ci.invoice_document_type = 'carrier_freight_invoice' and (s.snapshot_payload->'recipient'->>'type') not in ('broker','customer') then 'RECIPIENT_TYPE_MISMATCH'
    when ci.invoice_document_type = 'carrier_freight_invoice' and (s.snapshot_payload->'recipient'->>'type') is distinct from ci.recipient_type::text then 'RECIPIENT_TYPE_MISMATCH'
    when ci.invoice_document_type = 'carrier_freight_invoice' and jsonb_typeof(s.snapshot_payload->'factoring') is distinct from 'object' then 'FACTORING_OBJECT_MALFORMED'
    when ci.invoice_document_type = 'carrier_freight_invoice' and not (s.snapshot_payload->'factoring' ? 'mode') then 'FACTORING_MODE_MISSING'
    when ci.invoice_document_type = 'carrier_freight_invoice' and (s.snapshot_payload->'factoring'->>'mode') not in ('direct','factored') then 'FACTORING_MODE_UNKNOWN'
    when ci.invoice_document_type = 'carrier_freight_invoice' and (s.snapshot_payload->'factoring'->>'mode') = 'factored' and ((s.snapshot_payload->'factoring'->>'relationship_id') is null or jsonb_typeof(s.snapshot_payload->'factoring'->'company') is distinct from 'object' or (s.snapshot_payload->'factoring'->'company'->>'id') is null or (s.snapshot_payload->'factoring'->'company'->>'legal_name') is null) then 'FACTORING_OBJECT_MALFORMED'
    when ci.invoice_document_type = 'dispatch_service_invoice' and jsonb_typeof(s.snapshot_payload->'recipient') is distinct from 'object' then 'RECIPIENT_MALFORMED'
    when ci.invoice_document_type = 'dispatch_service_invoice' and (s.snapshot_payload->'recipient'->>'type') is distinct from 'carrier' then 'RECIPIENT_TYPE_MISMATCH'
    when ci.invoice_document_type = 'dispatch_service_invoice' and (s.snapshot_payload->'recipient'->>'carrier_id') is distinct from ci.carrier_id::text then 'CARRIER_ID_MISMATCH'
    when ci.invoice_document_type = 'dispatch_service_invoice' and jsonb_typeof(s.snapshot_payload->'factoring') is distinct from 'null' then 'FACTORING_NOT_PERMITTED_FOR_DOCUMENT_TYPE'
    else null
   end as problem_code,
   (ci.invoice_document_type = 'carrier_freight_invoice' and (s.snapshot_payload->'factoring'->>'mode') = 'factored') as is_factored,
   case when jsonb_typeof(s.snapshot_payload->'schema_version')='number' then (s.snapshot_payload->>'schema_version') else null end as schema_version_raw,
   -- Phase 3C.0E.1 supplementary fields: NOT part of the installed
   -- carrier_invoice_payment_snapshot_problem(uuid)'s own documented
   -- cross-checks (identity/currency/total/recipient/factoring only), so
   -- deliberately kept OUT of problem_code/the equivalence proof above --
   -- each gets its own finding ID instead of being folded into a check
   -- that claims equivalence with a function that does not perform it.
   (public.jsonb_contains_forbidden_key(s.snapshot_payload, array['secret_reference','api_key','access_token','refresh_token','password','client_secret','credential','credentials','private_key'])) as has_forbidden_key,
   ((s.snapshot_payload->>'invoice_number') is distinct from ci.invoice_number) as number_mismatch,
   ((s.snapshot_payload->>'issued_at') is not null and (s.snapshot_payload->>'issued_at')::timestamptz is distinct from ci.issued_at) as issued_at_mismatch,
   ((s.snapshot_payload->>'issued_by') is distinct from ci.issued_by::text) as issued_by_mismatch,
   (ci.invoice_document_type = 'carrier_freight_invoice' and jsonb_typeof(s.snapshot_payload->'dispatch_service') is distinct from 'null') as dispatch_service_should_be_null_bad,
   (ci.invoice_document_type = 'dispatch_service_invoice' and jsonb_typeof(s.snapshot_payload->'dispatch_service') is distinct from 'object') as dispatch_service_missing_bad,
   (ci.invoice_document_type = 'dispatch_service_invoice' and (s.snapshot_payload->'issuer'->>'organization_id') is distinct from ci.organization_id::text) as dispatch_issuer_org_mismatch,
   (jsonb_typeof(s.snapshot_payload->'source_loads') is distinct from 'array') as loads_shape_bad,
   -- Route shape only (Phase 3C.0E.2 Section F): every source_loads element
   -- must carry an origin/destination object -- NEVER their facility_name/
   -- city/state/address contents, which this check does not read at all.
   (ci.invoice_document_type='carrier_freight_invoice' and jsonb_typeof(s.snapshot_payload->'source_loads')='array' and exists(select 1 from jsonb_array_elements(s.snapshot_payload->'source_loads') e where jsonb_typeof(e->'origin') is distinct from 'object' or jsonb_typeof(e->'destination') is distinct from 'object')) as route_shape_bad,
   (jsonb_typeof(s.snapshot_payload->'line_items') is distinct from 'array') as line_items_shape_bad
  from public.carrier_invoice_issuance_snapshots s join public.carrier_invoices ci on ci.id = s.invoice_id
 ) x
$sq$,false,false,'') else null::xml end doc),
civs_problem as (select (unnest(xpath('/table/row/payload/text()',doc)))::text::jsonb j from civs_problem_xml where doc is not null),
-- Phase 3C.0E.2: line items, invoice-load links, and the number-counter
-- table -- same optional-table pattern, safe against every pre-0142/0144
-- boundary fixture.
civil_xml as (select case when to_regclass('public.carrier_invoice_line_items') is not null then query_to_xml('SELECT to_jsonb(t)::text AS payload FROM public.carrier_invoice_line_items t',false,false,'') else null::xml end doc),
civil as (select (unnest(xpath('/table/row/payload/text()',doc)))::text::jsonb j from civil_xml where doc is not null),
civl_xml as (select case when to_regclass('public.carrier_invoice_loads') is not null then query_to_xml('SELECT to_jsonb(t)::text AS payload FROM public.carrier_invoice_loads t',false,false,'') else null::xml end doc),
civl as (select (unnest(xpath('/table/row/payload/text()',doc)))::text::jsonb j from civl_xml where doc is not null),
civnc_xml as (select case when to_regclass('public.carrier_invoice_number_counters') is not null then query_to_xml('SELECT to_jsonb(t)::text AS payload FROM public.carrier_invoice_number_counters t',false,false,'') else null::xml end doc),
civnc as (select (unnest(xpath('/table/row/payload/text()',doc)))::text::jsonb j from civnc_xml where doc is not null),
-- Numbering: parse format {prefix}-{year}-{5-digit-sequence} (0142/0144)
-- from the relational invoice_number only -- the parsed pieces are used
-- solely for internal comparison, never projected to output.
civ_numbering as (
 select j->>'id' invoice_id, j->>'invoice_document_type' doctype,
  j->>'carrier_id' carrier_id, j->>'organization_id' org_id, j->>'issued_at' issued_at_text,
  (j->>'invoice_number') ~ '^[A-Z0-9][A-Z0-9-]{0,15}-[0-9]{4}-[0-9]{5}$' as format_ok,
  substring(j->>'invoice_number' from '-([0-9]{4})-[0-9]{5}$') as num_year,
  substring(j->>'invoice_number' from '-([0-9]{5})$')::int as num_seq,
  case when j->>'invoice_document_type'='carrier_freight_invoice' then j->>'carrier_id' else j->>'organization_id' end as issuer_id
 from civ where nullif(j->>'invoice_number','') is not null
),
party_broker as (
 select x.j, c.organization_id carrier_org, b.organization_id party_org,b.is_blacklisted,
        b.company_name, x.j->>'status' status,
        nullif(x.j->>'carrier_id','')::uuid carrier_id,
        nullif(x.j->>'broker_id','')::uuid broker_id
 from cb x left join public.carriers c on c.id=nullif(x.j->>'carrier_id','')::uuid
 left join public.brokers b on b.id=nullif(x.j->>'broker_id','')::uuid
),
party_customer as (
 select x.j,c.organization_id carrier_org,u.organization_id party_org,u.is_active customer_active,
        u.company_name,x.j->>'status' status,
        nullif(x.j->>'carrier_id','')::uuid carrier_id,
        nullif(x.j->>'customer_id','')::uuid customer_id
 from cc x left join public.carriers c on c.id=nullif(x.j->>'carrier_id','')::uuid
 left join public.customers u on u.id=nullif(x.j->>'customer_id','')::uuid
),
load_party as (
 select l.id,l.organization_id,l.broker_id,l.customer_id,l.status::text load_status,
        nullif(to_jsonb(l)->>'carrier_id','')::uuid carrier_id
 from public.loads l
),
factor_rel as (
 select x.j,c.organization_id carrier_org,f.j->>'organization_id' company_org,
        coalesce((f.j->>'is_active')::boolean,false) company_active,
        nullif(x.j->>'carrier_id','')::uuid carrier_id,
        nullif(x.j->>'factoring_company_id','')::uuid company_id
 from fr x left join public.carriers c on c.id=nullif(x.j->>'carrier_id','')::uuid
 left join fc f on f.j->>'id'=x.j->>'factoring_company_id'
),
-- Exact 0137 plan: invoice dispatch wins over invoice load; no status filter.
-- A single invoice with two non-null, different carriers aborts the migration.
factor_invoice_evidence as (
 select r.j->>'id' relationship_id,d.carrier_id dispatch_carrier,nullif(to_jsonb(l)->>'carrier_id','')::uuid load_carrier,
        coalesce(d.carrier_id,nullif(to_jsonb(l)->>'carrier_id','')::uuid) chosen_carrier,
        d.carrier_id is not null and nullif(to_jsonb(l)->>'carrier_id','') is not null and d.carrier_id<>nullif(to_jsonb(l)->>'carrier_id','')::uuid internal_conflict
 from fr r join fi f on f.j->>'factoring_relationship_id'=r.j->>'id'
 join public.invoices i on i.id=nullif(f.j->>'invoice_id','')::uuid
 left join public.dispatches d on d.id=i.dispatch_id
 left join public.loads l on l.id=i.load_id
), factor_0137_groups as (
 select r.j->>'id' relationship_id,r.j->>'organization_id' organization_id,
        (select count(*) from public.carriers c where c.organization_id=nullif(r.j->>'organization_id','')::uuid) org_carrier_count,
        count(distinct e.chosen_carrier) evidence_count,
        min(e.chosen_carrier::text)::uuid evidence_carrier,
        coalesce(bool_or(e.internal_conflict),false) internal_conflict,
        coalesce(bool_or(e.dispatch_carrier is not null),false) dispatch_evidence,
        coalesce(bool_or(e.load_carrier is not null),false) load_evidence,
        nullif(r.j->>'carrier_id','')::uuid current_carrier
 from fr r left join factor_invoice_evidence e on e.relationship_id=r.j->>'id'
 group by r.j
), factor_0137_plan as (
 select g.*,
   case when org_carrier_count=1 then 'single_carrier_org'
        when evidence_count=1 then 'multi_carrier_org_provable'
        when evidence_count=0 then 'unresolved_no_evidence'
        else 'unresolved_multiple' end resolution,
   case when org_carrier_count=1 then (select c.id from public.carriers c where c.organization_id=g.organization_id::uuid limit 1)
        when evidence_count=1 then evidence_carrier else null::uuid end predicted_carrier
 from factor_0137_groups g
), factor_0137_check as (
 select p.*,c.organization_id current_carrier_org,v.j provenance
 from factor_0137_plan p left join public.carriers c on c.id=p.current_carrier
 left join pv v on v.j->>'relationship_id'=p.relationship_id
),
factor_integ as (
 select x.j,r.j relationship,ic.organization_id::text integration_carrier_org,
        icomp.j->>'organization_id' integration_company_org,
        rcomp.j->>'organization_id' relationship_company_org,
        nullif(x.j->>'factoring_relationship_id','')::uuid relationship_id
 from cfi x left join fr r on r.j->>'id'=x.j->>'factoring_relationship_id'
 left join public.carriers ic on ic.id=nullif(x.j->>'carrier_id','')::uuid
 left join fc icomp on icomp.j->>'id'=x.j->>'factoring_company_id'
 left join fc rcomp on rcomp.j->>'id'=r.j->>'factoring_company_id'
),
legacy_invoice_class as (
 -- Phase 3C.2, Section C/F: the carrier-evidence branch is boundary-aware.
 -- Pre-0147 it mirrors the STILL-INSTALLED 0142 classifier's own literal
 -- carrier_resolution checks (including the impossible 'conflicting'
 -- value, unreachable except via a constraint-bypass corruption fixture)
 -- -- this is what lets a fixed corruption fixture prove BLOCKER #1 at
 -- exactly the 0146 boundary. Post-0147 it mirrors the CORRECTED
 -- classifier's own live public.dispatches recomputation (0133's C1/C2/
 -- C3/C4 CASE) exactly, never the frozen/impossible alternatives -- the
 -- SAME corruption fixture then predicts a live, current result instead,
 -- proving the fix is structural (the corrupted column is no longer even
 -- consulted), not merely a relabeling.
 select i.id,i.organization_id,i.status::text status,i.total_amount,i.amount_paid,i.load_id,i.broker_id,i.customer_id,
        to_jsonb(i) invoice_json,to_jsonb(l) load_json,
        case
          when i.status::text='void' then 'voided_cancelled'
          when i.status::text='paid' or i.amount_paid>0 and i.amount_paid<i.total_amount then 'paid_or_partially_paid'
          when exists(select 1 from fi f where f.j->>'invoice_id'=i.id::text) then 'existing_factoring_activity'
          when i.broker_id is not null and i.customer_id is not null then 'conflicting_recipient_evidence'
          when i.broker_id is null and i.customer_id is null then 'missing_recipient'
          when i.load_id is null or l.id is null then 'missing_carrier_evidence'
          when (select installed from fam where migration='0147') then
            -- POST-0147: mirrors the REAL corrected function's own exact
            -- check order (carrier_id not null -> safely_identifiable;
            -- else live derivation from public.dispatches).
            case
              when nullif(to_jsonb(l)->>'carrier_id','') is not null then 'safely_identifiable_legacy'
              when lde.resolved_carrier_id is not null then 'safely_identifiable_legacy'
              when lde.n_disp = 0 then 'missing_carrier_evidence'
              else 'conflicting_carrier_evidence'
            end
          else
            -- PRE-0147: mirrors the STILL-INSTALLED 0142 function's own
            -- exact check order -- carrier_resolution is tested
            -- REGARDLESS of carrier_id's own non-null-ness, exactly like
            -- the installed function, so a corruption fixture that sets
            -- BOTH carrier_id and carrier_resolution inconsistently (the
            -- only way the impossible 'conflicting' value can ever exist)
            -- still reaches the dead branch correctly. Collapsing this to
            -- "carrier_id not null => safe" first, as POST-0147 correctly
            -- does, would silently break equivalence with the INSTALLED
            -- pre-0147 function for exactly this corruption shape.
            case
              when nullif(to_jsonb(l)->>'carrier_id','') is null then 'missing_carrier_evidence'
              when to_jsonb(l)->>'carrier_resolution'='conflicting' then 'conflicting_carrier_evidence'
              when to_jsonb(l)->>'carrier_resolution'='unresolved' then 'missing_carrier_evidence'
              else 'safely_identifiable_legacy'
            end
        end classification,
        nullif(to_jsonb(l)->>'carrier_id','') carrier_label,
        case when i.broker_id is not null and i.customer_id is null then 'broker' when i.customer_id is not null and i.broker_id is null then 'customer' else null end recipient_type,
        coalesce(i.broker_id,i.customer_id)::text recipient_label
 from public.invoices i left join public.loads l on l.id=i.load_id
 left join lateral (
   select
     (select d.carrier_id from public.dispatches d where d.id = l.financial_dispatch_id and d.load_id = l.id) as fdi_carrier,
     (select coalesce(array_agg(distinct d.carrier_id),'{}'::uuid[]) from public.dispatches d where d.load_id = l.id and d.status <> 'cancelled') as noncanc,
     (select coalesce(array_agg(distinct d.carrier_id),'{}'::uuid[]) from public.dispatches d where d.load_id = l.id) as allc,
     (select count(*) from public.dispatches d where d.load_id = l.id) as n_disp
 ) dv on true
 left join lateral (
   select case
     when dv.fdi_carrier is not null and (array_length(dv.noncanc,1) is null or (array_length(dv.noncanc,1)=1 and dv.noncanc[1]=dv.fdi_carrier)) then dv.fdi_carrier
     when dv.fdi_carrier is null and array_length(dv.noncanc,1)=1 then dv.noncanc[1]
     when dv.fdi_carrier is null and array_length(dv.noncanc,1) is null and array_length(dv.allc,1)=1 then dv.allc[1]
     else null
   end as resolved_carrier_id, dv.n_disp
 ) lde on true
),
ordered as (select *,coalesce(bool_or(not installed) over(order by migration rows between unbounded preceding and 1 preceding),false) prior_absent from fam),
schema_state as (select count(*) filter(where installed) installed_count, count(*) filter(where split or installed and prior_absent) bad_count from ordered),
org_counts as (select o.id,count(c.id) n from public.organizations o left join public.carriers c on c.organization_id=o.id group by o.id),
load_evidence as (
 select l.id,l.organization_id,nullif(to_jsonb(l)->>'carrier_id','')::uuid load_carrier,
  nullif(to_jsonb(l)->>'financial_dispatch_id','')::uuid controller_id,
  count(distinct d.carrier_id) filter(where d.status::text<>'cancelled') active_carriers,
  count(distinct d.carrier_id) all_carriers,
  bool_or(d.organization_id<>l.organization_id or c.organization_id<>l.organization_id) cross_org
 from public.loads l left join public.dispatches d on d.load_id=l.id left join public.carriers c on c.id=d.carrier_id group by l.id,l.organization_id
), le as (
 select e.*,fd.carrier_id financial_carrier,fd.load_id financial_load_id,
  (select count(*) from public.dispatches d where d.load_id=e.id and d.carrier_id is distinct from e.load_carrier and e.load_carrier is not null) differing_dispatches
 from load_evidence e left join public.dispatches fd on fd.id=e.controller_id
), tr as (
 select t.id,t.organization_id,t.carrier_id,to_jsonb(t)->>'ownership_scope' scope,
  count(distinct d.carrier_id) filter(where d.status::text<>'cancelled') used_carriers,
  bool_or(d.carrier_id<>t.carrier_id) filter(where d.status::text<>'cancelled') cross_use,
  c.organization_id carrier_org
 from public.trailers t left join public.dispatches d on d.trailer_id=t.id left join public.carriers c on c.id=t.carrier_id
 group by t.id,t.organization_id,t.carrier_id,c.organization_id
), raw(finding_id,section,check_name,severity,affected_count,details,remediation) as (
 select 'SCHEMA_0129','schema','expected_0129_boundary','INFO',(select (installed_count=0)::int from schema_state)::bigint,'No 0130-0146 family installed.','Confirm with migration history.' union all
 select 'SCHEMA_0146','schema','complete_post_0146_boundary','INFO',(select (installed_count=17)::int from schema_state)::bigint,'All 17 migration families installed (0147 not yet applied) -- this is the VULNERABLE, pre-remediation boundary: all seven Phase 3C.0 release BLOCKERs are expected present here.','Confirm post-apply output; do not treat this boundary as deployable.' union all
 select 'SCHEMA_0147','schema','complete_post_0147_boundary','INFO',(select (installed_count=18)::int from schema_state)::bigint,'All 18 migration families installed, including 0147 -- this is the CORRECTED, post-remediation boundary: all seven Phase 3C.0 release BLOCKERs are expected resolved here (FUNC_RAISE_LEAKS_CONTEXT remains an intentional, separate WARNING, unaffected by 0147).','Confirm post-apply output.' union all
 select 'SCHEMA_HISTORY_ABSENT','schema','migration_history_absent','INFO',(select (not present)::int from history_catalog)::bigint,'Supabase history relation absent; object inspection remains authoritative.','Confirm the database boundary independently.' union all
 select 'SCHEMA_HISTORY_SHAPE','schema','migration_history_version_unrecognized','INFO',(select (present and not version_ok)::int from history_catalog)::bigint,'History relation exists without recognized version column.','Stop until its catalog shape is identified.' union all
 select 'SCHEMA_HISTORY_DISAGREE','schema','migration_history_object_disagreement','BLOCKER',(select count(*) from history_state where recorded<>installed and (select present and version_ok from history_catalog))::bigint,'History versions disagree with required landmarks.','Stop and reconcile without editing history rows.' union all
 select 'SCHEMA_HISTORY_LATER','schema','unexpected_later_history_version','BLOCKER',(select count(*) from history_versions where version ~ '^0?(14[8-9]|1[5-9][0-9])')::bigint,'A migration later than the range this audit package supports (0130-0147) is recorded in history.','Stop; this audit package must be extended before proceeding -- fail closed as unsupported rather than guessing.' union all
 select 'SCHEMA_LANDMARK_'||migration,'schema','missing_landmark_'||migration,'BLOCKER',split::int::bigint,
 'Migration '||migration||' landmark missing: '||case when not a then name_a else name_b end,
 'Stop; compare this migration with its preflight and post-apply verifiers.'
 from fam join (values
 ('0130','carrier_remittance_profiles','carriers.invoice_code'),('0131','carrier_brokers','carrier_customers'),
 ('0132','trailer_ownership_scope_audit','loads.carrier_id'),('0133','carrier_backfill_0133_provenance','loads.carrier_id backfill marker'),
 ('0134','dispatch_status_transitions','transition_dispatch_status function'),('0135','dispatch_resource_reassignments','reassign_dispatch_resources function'),
 ('0136','factoring_relationships.carrier_id','carriers.factoring_mode'),('0137','carrier_backfill_0137_provenance','factoring_relationships.carrier_id marker'),
 ('0138','classify_carrier_factoring_readiness function','set_default_factoring_relationship function'),
 ('0139','carrier_factoring_integrations','factoring_policy_idempotency'),('0140','factoring_relationships_delete policy','factoring_companies_delete policy'),
 ('0141','factoring_integration_lifecycle_idempotency','classify_carrier_factoring_readiness function'),
 ('0142','carrier_invoices','carrier_invoice_issuance_snapshots'),('0143','update_carrier_invoice_draft function','compute_financial_request_fingerprint function'),
 ('0144','guard_load_stops_parent_lock function','issue_carrier_invoice function'),('0145','carrier_dispatch_service_agreements','carrier_dispatch_service_agreement_versions'),
 ('0146','carrier_invoice_payments','carrier_invoice_payment_status type')
 ) names(mig,name_a,name_b) on mig=migration union all
 select 'SCHEMA_PARTIAL','schema','partial_installation','BLOCKER',(select bad_count from schema_state)::bigint,'Split family or non-contiguous installed prefix.','Stop and inspect missing landmarks.' union all
 select 'SCHEMA_LATER','schema','unexpected_later_object','BLOCKER',(to_regclass('public.carrier_invoice_0147_provenance') is not null)::int::bigint,'Known 0147 marker encountered.','Stop and identify later schema.' union all
 select 'SCHEMA_PGCRYPTO','schema','required_pgcrypto','BLOCKER',(not exists(select 1 from pg_extension where extname='pgcrypto'))::int::bigint,'Required extension absent.','Install through approved migration path.' union all
 select 'SCHEMA_RLS','schema','required_rls','BLOCKER',(select count(*) from pg_class c where c.relnamespace='public'::regnamespace and c.relname in ('carrier_remittance_profiles','carrier_brokers','carrier_customers','carrier_invoices','carrier_invoice_issuance_snapshots','carrier_invoice_payments') and not c.relrowsecurity)::bigint,'Installed protected tables without RLS.','Stop; restore owning migration security.' union all
 select 'SCHEMA_GRANTS','schema','broad_table_grants','BLOCKER',(select count(*) from information_schema.role_table_grants where table_schema='public' and table_name in ('carrier_invoice_issuance_snapshots','carrier_invoice_payments') and grantee='anon')::bigint,'Anonymous protected-table grants.','Revoke unexpected grants after review.' union all
 select 'ORG_TOTAL','organization','organization_count','INFO',(select count(*) from public.organizations)::bigint,'Organization count.','Review inventory.' union all
 select 'ORG_ZERO','organization','zero_carrier_organizations','WARNING',(select count(*) from org_counts where n=0)::bigint,'Organizations without carriers.','Review configuration; do not infer a carrier.' union all
 select 'ORG_ONE','organization','one_carrier_organizations','INFO',(select count(*) from org_counts where n=1)::bigint,'Single-carrier organizations.','Review inventory.' union all
 select 'ORG_MULTI','organization','multi_carrier_organizations','INFO',(select count(*) from org_counts where n>1)::bigint,'Multi-carrier organizations.','Review scope evidence.' union all
 select 'CARRIER_ACTIVE','carrier','active_carriers','INFO',(select count(*) from public.carriers where is_active)::bigint,'Active carrier count.','Review inventory.' union all
 select 'CARRIER_INACTIVE','carrier','inactive_carriers','INFO',(select count(*) from public.carriers where not is_active)::bigint,'Inactive carrier count.','Review inventory.' union all
 select 'CARRIER_ORG','carrier','invalid_carrier_organization','BLOCKER',(select count(*) from public.carriers c left join public.organizations o on o.id=c.organization_id where o.id is null)::bigint,'Carrier refers to absent organization.','Repair tenant boundary.' union all
 select 'CARRIER_CODE','carrier','missing_invoice_code','WARNING',(select count(*) from public.carriers c where c.is_active and (select installed from fam where migration='0130') and nullif(to_jsonb(c)->>'invoice_code','') is null)::bigint,'Active carrier invoice code missing; inactive carriers remain visible historically.','Configure before accepting new work or issuance.' union all
 select 'CARRIER_DUP_CODE','carrier','duplicate_invoice_code','BLOCKER',(select count(*) from (select organization_id,to_jsonb(c)->>'invoice_code' code from public.carriers c where nullif(to_jsonb(c)->>'invoice_code','') is not null group by organization_id,to_jsonb(c)->>'invoice_code' having count(*)>1) x)::bigint,'Duplicate code within organization.','Resolve before issuance.' union all
 select 'CARRIER_REMIT','carrier','missing_remittance_profile','WARNING',
 (select count(*) from public.carriers c where is_active and (select installed from fam where migration='0130') and
 not exists(select 1 from
 (select (unnest(xpath('/table/row/carrier_id/text()',doc)))::text carrier_id from
 (select case when to_regclass('public.carrier_remittance_profiles') is not null then
 query_to_xml('SELECT carrier_id FROM public.carrier_remittance_profiles',false,false,'') else null::xml end doc) q) r
 where c.id::text=r.carrier_id))::bigint,
 'Active carrier lacks a remittance profile.','Create its profile through an approved configuration path.' union all
 select 'CARRIER_TERMS','carrier','missing_dispatch_terms','WARNING',(select count(*) from public.carriers c where (select installed from fam where migration='0130') and nullif(to_jsonb(c)->>'dispatch_service_terms_days','') is null and not exists(select 1 from public.platform_settings p where nullif(to_jsonb(p)->>'dispatch_service_terms_days','') is not null))::bigint,'Neither carrier override nor platform terms available.','Configure dispatch terms.' union all
 select 'CARRIER_BAD_TERMS','carrier','invalid_dispatch_terms','BLOCKER',(select count(*) from public.carriers c where nullif(to_jsonb(c)->>'dispatch_service_terms_days','') is not null and (to_jsonb(c)->>'dispatch_service_terms_days')::int not between 0 and 365)::bigint,'Carrier override outside approved range.','Repair invalid configuration.' union all
 select 'DISPATCH_PREFIX','carrier','missing_dispatch_invoice_prefix','WARNING',(select count(*) from public.platform_settings p where (select installed from fam where migration='0142') and nullif(to_jsonb(p)->>'dispatch_invoice_prefix','') is null)::bigint,'Dispatch invoice prefix missing.','Configure valid prefix before issuance.' union all
 select 'LOAD_DETERMINISTIC','load','deterministic_carrier','INFO',(select count(*) from le where load_carrier is not null or financial_carrier is not null or active_carriers=1 or (active_carriers=0 and all_carriers=1))::bigint,'At least one deterministic carrier signal.','Verify 0133 classification.' union all
 -- Row 27: counts must correspond to 0133's ACTUAL three precedence-
 -- ordered rules (migrations/0133, lines ~290-298), not just "any signal
 -- present". C1 (financial_dispatch_id resolves) outranks C2 (exactly one
 -- distinct NON-CANCELLED dispatch carrier), which outranks C3 (exactly
 -- one distinct carrier overall, reached only when every dispatch is
 -- cancelled). Mutually exclusive by construction (each lower tier's
 -- condition explicitly excludes having already matched a higher one) --
 -- their sum must never double-count a load matched by a higher-precedence
 -- rule, and never includes an ambiguous (2+ distinct carrier) load, which
 -- is row 28's own separate, deliberate exclusion.
 select 'LOAD_CLASS_C1','load','classification_c1_financial_controller','INFO',(select count(*) from le where financial_carrier is not null)::bigint,'Loads deterministically resolved via C1 (financial_dispatch_id controller).','Verify against 0133''s own C1_financial_controller rule.' union all
 select 'LOAD_CLASS_C2','load','classification_c2_sole_noncancelled_carrier','INFO',(select count(*) from le where financial_carrier is null and active_carriers=1)::bigint,'Loads deterministically resolved via C2 (sole non-cancelled dispatch carrier, no financial controller).','Verify against 0133''s own C2_sole_noncancelled_carrier rule.' union all
 select 'LOAD_CLASS_C3','load','classification_c3_sole_cancelled_carrier','INFO',(select count(*) from le where financial_carrier is null and active_carriers=0 and all_carriers=1)::bigint,'Loads deterministically resolved via C3 (sole carrier among cancelled-only dispatches, no financial controller, no non-cancelled dispatch).','Verify against 0133''s own C3_sole_cancelled_carrier rule.' union all
 select 'LOAD_CLASS_OVERLAP','load','classification_tiers_not_mutually_exclusive','BLOCKER',(select count(*) from le where (case when financial_carrier is not null then 1 else 0 end + case when financial_carrier is null and active_carriers=1 then 1 else 0 end + case when financial_carrier is null and active_carriers=0 and all_carriers=1 then 1 else 0 end) > 1)::bigint,'A load matched more than one 0133 classification tier -- the tiers are no longer mutually exclusive.','Stop; the audit''s own tier definitions have diverged from 0133''s precedence.' union all
 select 'LOAD_NO_EVIDENCE','load','no_carrier_evidence','WARNING',(select count(*) from le where load_carrier is null and financial_carrier is null and all_carriers=0)::bigint,'No carrier evidence; remain unresolved.','Review manually; do not guess.' union all
 -- Row 28: "never guess" requires distinguishing genuinely NO evidence
 -- (LOAD_NO_EVIDENCE, all_carriers=0) from genuinely AMBIGUOUS evidence
 -- (2+ distinct non-cancelled dispatch carriers, no financial controller
 -- to break the tie) -- the two are currently conflated under the single
 -- generic missing_carrier_evidence WARNING; this is 0133's own
 -- unresolved_multiple outcome, distinct from unresolved_no_evidence, and
 -- deserves its own distinguishable signal since the correct remediation
 -- differs (resolve the conflict vs. supply evidence).
 select 'LOAD_CLASS_AMBIGUOUS','load','classification_unresolved_multiple_candidates','BLOCKER',(select count(*) from le where load_carrier is null and financial_carrier is null and active_carriers>=2)::bigint,'Load has 2+ distinct non-cancelled dispatch carriers and no financial controller to break the tie -- 0133''s own unresolved_multiple outcome. Never auto-resolved; must not be silently guessed.','Resolve the conflicting dispatch assignment manually; do not select a carrier automatically.' union all
 select 'LOAD_CONFLICT','load','load_dispatch_conflict','BLOCKER',(select count(*) from le where differing_dispatches>0)::bigint,'Load and dispatch carrier differ.','Stop and resolve structural conflict.' union all
 select 'LOAD_FIN_CONFLICT','load','financial_dispatch_conflict','BLOCKER',(select count(*) from le where financial_carrier is not null and load_carrier is not null and financial_carrier<>load_carrier)::bigint,'Financial controller differs from load carrier.','Stop and resolve controller.' union all
 select 'LOAD_MULTI','load','multiple_active_dispatch_carriers','BLOCKER',(select count(*) from le where active_carriers>1)::bigint,'Multiple noncancelled carrier candidates.','Review ambiguity; never guess.' union all
 select 'LOAD_FIN_WRONG','load','financial_dispatch_wrong_load','BLOCKER',(select count(*) from le where controller_id is not null and financial_load_id is distinct from id)::bigint,'Financial dispatch belongs to another load or is absent.','Repair controller link.' union all
 select 'LOAD_CROSS_ORG','load','cross_organization_dispatch','BLOCKER',(select count(*) from le where cross_org)::bigint,'Cross-organization load/dispatch/carrier.','Repair tenant boundary.' union all
 select 'TRAILER_CARRIER','trailer','carrier_owned_trailers','INFO',(select count(*) from tr where carrier_id is not null and (scope is null or scope='carrier'))::bigint,'Carrier-owned trailer count.','Review scope.' union all
 select 'TRAILER_SHARED','trailer','shared_trailers','INFO',(select count(*) from tr where scope='organization_shared')::bigint,'Explicit organization-shared trailer count.','Check approval audit.' union all
 select 'TRAILER_UNRESOLVED','trailer','unresolved_trailers','WARNING',(select count(*) from tr where carrier_id is null and (scope is null or scope='unresolved'))::bigint,'Trailer ownership unresolved.','Owner/admin must classify.' union all
 select 'TRAILER_BAD_SCOPE','trailer','invalid_scope_carrier','BLOCKER',(select count(*) from tr where (scope='carrier' and carrier_id is null) or (scope='organization_shared' and carrier_id is not null) or (carrier_org is not null and carrier_org<>organization_id))::bigint,'Invalid trailer scope/carrier organization combination.','Stop and resolve.' union all
 select 'TRAILER_CROSS_USE','trailer','cross_carrier_use_without_shared_scope','BLOCKER',(select count(*) from tr where cross_use and scope is distinct from 'organization_shared')::bigint,'Trailer used across carriers without approved shared scope.','Stop and review assignments.' union all
 -- Row 35: trailer_ownership_scope_audit COVERAGE, not just its existence
 -- (already proven, PLAT_RLS_MISSING/PLAT_GRANTS_ANON family). Direct
 -- client writes to trailers.ownership_scope are structurally impossible
 -- (confirmed directly: authenticated has no table-level UPDATE grant on
 -- trailers at all -- "permission denied for table trailers"), and
 -- 'organization_shared' is never the trigger-derived default (only
 -- 'carrier'/'unresolved' are auto-derived by trailers_derive_ownership_
 -- scope) -- so a trailer currently in 'organization_shared' scope with
 -- zero matching trailer_ownership_scope_audit rows can only mean the
 -- approve_trailer_ownership_scope() RPC's own audit insert was bypassed
 -- (e.g. a direct superuser/migration-context write), not that no
 -- approval ever happened.
 select 'TRAILER_AUDIT_COVERAGE_GAP','trailer','ownership_scope_audit_coverage_gap','BLOCKER',(select count(*) from tr where scope='organization_shared' and not exists(select 1 from toa a where nullif(a.j->>'trailer_id','')::uuid=tr.id))::bigint,'A trailer is in organization_shared scope (only ever reachable via the approve_trailer_ownership_scope() RPC) with no corresponding trailer_ownership_scope_audit row -- the approval RPC''s own audit insert was bypassed.','Stop; identify how the scope changed outside the guarded RPC.' union all
 select 'PARTY_BROKER_TOTAL','carrier_party','carrier_broker_relationship_total','INFO',(select count(*) from cb)::bigint,'Carrier-broker relationship count; no party details.','Review relationship inventory.' union all
 select 'PARTY_CUSTOMER_TOTAL','carrier_party','carrier_customer_relationship_total','INFO',(select count(*) from cc)::bigint,'Carrier-customer relationship count; no party details.','Review relationship inventory.' union all
 select 'FACTOR_REL_TOTAL','factoring','factoring_relationship_total','INFO',(select count(*) from fr)::bigint,'Factoring relationship count; no terms or credentials.','Review relationship inventory.' union all
 select 'FACTOR_0137_SINGLE','factoring','0137_single_carrier_org','INFO',(select count(*) from factor_0137_plan where resolution='single_carrier_org')::bigint,'0137 single-carrier organization classification.','Compare with provenance.' union all
 select 'FACTOR_0137_PROVABLE','factoring','0137_multi_carrier_provable','INFO',(select count(*) from factor_0137_plan where resolution='multi_carrier_org_provable')::bigint,'0137 one distinct invoice-evidence carrier.','Compare with provenance.' union all
 select 'FACTOR_0137_NO_EVIDENCE','factoring','0137_unresolved_no_evidence','WARNING',(select count(*) from factor_0137_plan where resolution='unresolved_no_evidence')::bigint,'0137 has no resolved factored-invoice carrier evidence.','Review unresolved worklist.' union all
 select 'FACTOR_0137_MULTIPLE','factoring','0137_unresolved_multiple','WARNING',(select count(*) from factor_0137_plan where resolution='unresolved_multiple')::bigint,'0137 has multiple distinct invoice-evidence carriers.','Review unresolved worklist.' union all
 select 'FACTOR_0137_CONFLICT','factoring','0137_internal_invoice_conflict','BLOCKER',(select count(*) from factor_0137_plan where internal_conflict)::bigint,'A factored invoice dispatch and load disagree; 0137 would abort.','Resolve structural conflict before applying 0137.' union all
 select 'FACTOR_0137_PREEXISTING','factoring','0137_preexisting_assignment','BLOCKER',(select count(*) from factor_0137_check where current_carrier is not null and (select installed from fam where migration='0137')=false)::bigint,'A pre-0137 carrier assignment violates its rerun guard.','Stop and investigate before 0137.' union all
 select 'FACTOR_0137_CROSS_ORG','factoring','assigned_carrier_outside_relationship_org','BLOCKER',(select count(*) from factor_0137_check where current_carrier is not null and current_carrier_org is distinct from organization_id::uuid)::bigint,'Assigned carrier is outside relationship organization.','Repair tenant boundary.' union all
 select 'FACTOR_0137_ASSIGNMENT_DISAGREE','factoring','assignment_disagrees_with_0137_evidence','BLOCKER',(select count(*) from factor_0137_check where current_carrier is not null and predicted_carrier is not null and current_carrier<>predicted_carrier)::bigint,'Current assignment differs from 0137 deterministic choice.','Investigate provenance and later authorized changes.' union all
 select 'FACTOR_0137_PROVENANCE_MISSING','factoring','0137_provenance_missing','BLOCKER',(select count(*) from factor_0137_check where (select installed from fam where migration='0137') and provenance is null)::bigint,'0137 provenance row absent.','Stop and reconcile migration state.' union all
 select 'FACTOR_0137_PROVENANCE_DISAGREE','factoring','0137_provenance_disagrees','BLOCKER',(select count(*) from factor_0137_check where provenance is not null and (provenance->>'resolution' is distinct from resolution or nullif(provenance->>'carrier_id','')::uuid is distinct from predicted_carrier))::bigint,'0137 provenance differs from recomputed classification.','Review historical evidence and provenance.' union all
 select 'FACTOR_0137_PROVENANCE_ORG','factoring','0137_provenance_organization_disagrees','BLOCKER',(select count(*) from factor_0137_check where provenance is not null and provenance->>'organization_id' is distinct from organization_id)::bigint,'0137 provenance organization differs from relationship.','Stop and repair provenance integrity.' union all
 select 'FACTOR_0137_PROVENANCE_STATE','factoring','0137_provenance_carrier_state_invalid','BLOCKER',(select count(*) from factor_0137_check where provenance is not null and ((provenance->>'resolution' in ('single_carrier_org','multi_carrier_org_provable')) <> (nullif(provenance->>'carrier_id','') is not null)))::bigint,'Provenance resolution and carrier/null state disagree.','Stop and repair provenance integrity.' union all
 select 'FACTOR_0137_UNRESOLVED_LINK','factoring','0137_unresolved_record_missing_or_invalid','BLOCKER',(select count(*) from factor_0137_check x where provenance is not null and provenance->>'resolution' in ('unresolved_no_evidence','unresolved_multiple') and not exists(select 1 from ur u where u.j->>'id'=x.provenance->>'unresolved_carrier_record_id' and u.j->>'record_type'='factoring_relationship' and u.j->>'record_id'=x.relationship_id and u.j->>'organization_id'=x.organization_id and u.j->>'status'='unresolved'))::bigint,'Unresolved provenance lacks its matching open unresolved record.','Stop and reconcile unresolved lifecycle.' union all
 select 'FACTOR_0137_RESOLVED_UNRESOLVED','factoring','0137_resolved_has_open_unresolved_record','BLOCKER',(select count(*) from factor_0137_check x where current_carrier is not null and exists(select 1 from ur u where u.j->>'record_type'='factoring_relationship' and u.j->>'record_id'=x.relationship_id and u.j->>'status'='unresolved'))::bigint,'Resolved relationship still has an open unresolved record.','Resolve the stale exception record.' union all
 select 'PARTY_BROKER_ACTIVE','carrier_party','active_carrier_broker_relationships','INFO',(select count(*) from party_broker where status='active')::bigint,'Active carrier-broker relationships counted.','Review active inventory.' union all
 select 'PARTY_BROKER_INACTIVE','carrier_party','inactive_carrier_broker_relationships','INFO',(select count(*) from party_broker where status<>'active')::bigint,'Historical or inactive relationships counted.','Exclude from new work.' union all
 select 'PARTY_BROKER_CROSS_ORG','carrier_party','cross_organization_carrier_broker','BLOCKER',(select count(*) from party_broker where carrier_org is distinct from (j->>'organization_id')::uuid or party_org is distinct from (j->>'organization_id')::uuid)::bigint,'Carrier, broker, or relationship tenant differs.','Stop and repair tenant references.' union all
 select 'PARTY_BROKER_DUP','carrier_party','duplicate_carrier_broker','BLOCKER',(select count(*) from (select carrier_id,broker_id from party_broker group by carrier_id,broker_id having count(*)>1) q)::bigint,'Duplicate carrier-broker pairs.','Resolve duplicate relationships.' union all
 select 'PARTY_BROKER_BLACKLIST','carrier_party','active_blacklisted_broker','BLOCKER',(select count(*) from party_broker where status='active' and is_blacklisted)::bigint,'Active relationship with blacklisted broker.','Deactivate or resolve broker eligibility.' union all
 select 'PARTY_BROKER_BILLING','carrier_party','active_broker_billing_incomplete','WARNING',(select count(*) from party_broker where status='active' and (nullif(btrim(coalesce(company_name,'')),'') is null or nullif(btrim(coalesce(j->>'billing_email','')),'') is null or nullif(j->>'payment_terms_days','') is null))::bigint,'Active broker relationship lacks billing identity or terms.','Complete required billing configuration.' union all
 select 'PARTY_CUSTOMER_ACTIVE','carrier_party','active_carrier_customer_relationships','INFO',(select count(*) from party_customer where status='active')::bigint,'Active carrier-customer relationships counted.','Review active inventory.' union all
 select 'PARTY_CUSTOMER_INACTIVE','carrier_party','inactive_carrier_customer_relationships','INFO',(select count(*) from party_customer where status<>'active')::bigint,'Historical or inactive relationships counted.','Exclude from new work.' union all
 select 'PARTY_CUSTOMER_CROSS_ORG','carrier_party','cross_organization_carrier_customer','BLOCKER',(select count(*) from party_customer where carrier_org is distinct from (j->>'organization_id')::uuid or party_org is distinct from (j->>'organization_id')::uuid)::bigint,'Carrier, customer, or relationship tenant differs.','Stop and repair tenant references.' union all
 select 'PARTY_CUSTOMER_DUP','carrier_party','duplicate_carrier_customer','BLOCKER',(select count(*) from (select carrier_id,customer_id from party_customer group by carrier_id,customer_id having count(*)>1) q)::bigint,'Duplicate carrier-customer pairs.','Resolve duplicate relationships.' union all
 select 'PARTY_CUSTOMER_INELIGIBLE','carrier_party','active_inactive_customer','BLOCKER',(select count(*) from party_customer where status='active' and not coalesce(customer_active,false))::bigint,'Active relationship with inactive customer.','Deactivate relationship or restore eligibility.' union all
 select 'PARTY_CUSTOMER_BILLING','carrier_party','active_customer_billing_incomplete','WARNING',(select count(*) from party_customer where status='active' and (nullif(btrim(coalesce(company_name,'')),'') is null or nullif(btrim(coalesce(j->>'billing_email','')),'') is null or nullif(j->>'payment_terms_days','') is null))::bigint,'Active customer relationship lacks billing identity or terms.','Complete required billing configuration.' union all
 select 'PARTY_CUSTOMER_BILLING_IDENTITY','carrier_party','active_customer_identity_missing','WARNING',(select count(*) from party_customer where status='active' and nullif(btrim(coalesce(company_name,'')),'') is null)::bigint,'Active customer lacks billing identity.','Complete customer identity.' union all
 select 'PARTY_CUSTOMER_EMAIL','carrier_party','active_customer_billing_email_missing','WARNING',(select count(*) from party_customer where status='active' and nullif(btrim(coalesce(j->>'billing_email','')),'') is null)::bigint,'Active customer relationship lacks required billing email.','Complete billing email.' union all
 select 'PARTY_CUSTOMER_TERMS','carrier_party','active_customer_payment_terms_invalid','BLOCKER',(select count(*) from party_customer where status='active' and (nullif(j->>'payment_terms_days','') is null or (j->>'payment_terms_days')::int not between 0 and 365))::bigint,'Active customer relationship has invalid payment terms.','Repair payment terms before new work.' union all
 select 'LOAD_BROKER_REL_MISSING','carrier_party','load_broker_relationship_missing','WARNING',(select count(*) from load_party l where l.carrier_id is not null and l.broker_id is not null and l.customer_id is null and l.load_status<>'cancelled' and not exists(select 1 from party_broker p where p.carrier_id=l.carrier_id and p.broker_id=l.broker_id))::bigint,'Carrier/broker relationship missing for a deterministically scoped load.','Configure relationship before issuance.' union all
 select 'LOAD_BROKER_REL_INACTIVE','carrier_party','load_broker_relationship_inactive','WARNING',(select count(*) from load_party l where l.carrier_id is not null and l.broker_id is not null and l.customer_id is null and l.load_status<>'cancelled' and exists(select 1 from party_broker p where p.carrier_id=l.carrier_id and p.broker_id=l.broker_id and p.status<>'active'))::bigint,'Carrier/broker relationship inactive for new work.','Activate an eligible relationship before issuance.' union all
 select 'LOAD_BROKER_BLACKLIST','carrier_party','load_broker_blacklisted','BLOCKER',(select count(*) from load_party l where l.carrier_id is not null and l.broker_id is not null and l.customer_id is null and l.load_status<>'cancelled' and exists(select 1 from party_broker p where p.carrier_id=l.carrier_id and p.broker_id=l.broker_id and p.is_blacklisted))::bigint,'Deterministically scoped load names a blacklisted broker.','Stop and resolve recipient eligibility.' union all
 select 'LOAD_CUSTOMER_REL_MISSING','carrier_party','load_customer_relationship_missing','WARNING',(select count(*) from load_party l where l.carrier_id is not null and l.customer_id is not null and l.broker_id is null and l.load_status<>'cancelled' and not exists(select 1 from party_customer p where p.carrier_id=l.carrier_id and p.customer_id=l.customer_id))::bigint,'Carrier/customer relationship missing for a deterministically scoped load.','Configure relationship before issuance.' union all
 select 'LOAD_CUSTOMER_REL_INACTIVE','carrier_party','load_customer_relationship_inactive','WARNING',(select count(*) from load_party l where l.carrier_id is not null and l.customer_id is not null and l.broker_id is null and l.load_status<>'cancelled' and exists(select 1 from party_customer p where p.carrier_id=l.carrier_id and p.customer_id=l.customer_id and p.status<>'active'))::bigint,'Carrier/customer relationship inactive for new work.','Activate an eligible relationship before issuance.' union all
 select 'LOAD_CUSTOMER_INACTIVE','carrier_party','load_customer_inactive','BLOCKER',(select count(*) from load_party l where l.carrier_id is not null and l.customer_id is not null and l.broker_id is null and l.load_status<>'cancelled' and exists(select 1 from party_customer p where p.carrier_id=l.carrier_id and p.customer_id=l.customer_id and not coalesce(p.customer_active,false)))::bigint,'Deterministically scoped load names an inactive customer.','Stop and resolve recipient eligibility.' union all
 select 'LOAD_BOTH_RECIPIENTS','carrier_party','load_both_recipient_types','BLOCKER',(select count(*) from public.loads where broker_id is not null and customer_id is not null)::bigint,'Load has both broker and customer recipient.','Resolve legal recipient before issuance.' union all
 select 'LOAD_NO_RECIPIENT','carrier_party','load_no_recipient','WARNING',(select count(*) from public.loads where broker_id is null and customer_id is null)::bigint,'Load has no broker or customer recipient.','Review and assign only with evidence.' union all
 select 'FACTOR_COMPANY_TOTAL','factoring','factoring_company_total','INFO',(select count(*) from fc)::bigint,'Factoring company count.','Review inventory.' union all
 select 'FACTOR_POLICY_UNCONFIGURED','factoring','active_carriers_unconfigured','WARNING',(select count(*) from public.carriers c where c.is_active and to_jsonb(c)->>'factoring_mode'='unconfigured')::bigint,'Active carriers with unconfigured factoring policy.','Choose direct or factored before issuance.' union all
 select 'FACTOR_POLICY_DIRECT','factoring','active_carriers_direct','INFO',(select count(*) from public.carriers c where c.is_active and to_jsonb(c)->>'factoring_mode'='direct')::bigint,'Active direct-policy carriers.','Review policy inventory.' union all
 select 'FACTOR_POLICY_FACTORED','factoring','active_carriers_factored','INFO',(select count(*) from public.carriers c where c.is_active and to_jsonb(c)->>'factoring_mode'='factored')::bigint,'Active factored-policy carriers.','Review readiness.' union all
 select 'FACTOR_POLICY_INACTIVE','factoring','inactive_carriers_by_policy','INFO',(select count(*) from public.carriers c where not c.is_active and nullif(to_jsonb(c)->>'factoring_mode','') is not null)::bigint,'Inactive carriers retain historical policy.','Exclude from new issuance.' union all
 select 'FACTOR_POLICY_UNCONFIGURED_REL','factoring','unconfigured_carrier_with_relationship','WARNING',(select count(*) from public.carriers c where c.is_active and to_jsonb(c)->>'factoring_mode'='unconfigured' and exists(select 1 from factor_rel r where r.carrier_id=c.id))::bigint,'Unconfigured carrier has factoring relationship data.','Resolve policy before issuance.' union all
 select 'FACTOR_POLICY_DIRECT_REL','factoring','direct_carrier_with_default_relationship','BLOCKER',(select count(*) from public.carriers c where c.is_active and to_jsonb(c)->>'factoring_mode'='direct' and exists(select 1 from factor_rel r where r.carrier_id=c.id and coalesce((r.j->>'is_active')::boolean,false) and coalesce((r.j->>'is_default')::boolean,false)))::bigint,'Direct carrier has an active default factoring relationship.','Resolve policy/default disagreement.' union all
 select 'FACTOR_POLICY_FACTORED_NO_REL','factoring','factored_carrier_without_relationship','WARNING',(select count(*) from public.carriers c where c.is_active and to_jsonb(c)->>'factoring_mode'='factored' and not exists(select 1 from factor_rel r where r.carrier_id=c.id))::bigint,'Factored carrier has no relationship.','Configure relationship before issuance.' union all
 select 'FACTOR_POLICY_FACTORED_NO_DEFAULT','factoring','factored_carrier_without_default','WARNING',(select count(*) from public.carriers c where c.is_active and to_jsonb(c)->>'factoring_mode'='factored' and exists(select 1 from factor_rel r where r.carrier_id=c.id) and not exists(select 1 from factor_rel r where r.carrier_id=c.id and coalesce((r.j->>'is_default')::boolean,false) and coalesce((r.j->>'is_active')::boolean,false)))::bigint,'Factored carrier lacks an active default.','Configure one valid default.' union all
 select 'FACTOR_POLICY_INACTIVE_REL','factoring','inactive_historical_relationships','INFO',(select count(*) from factor_rel r where not coalesce((r.j->>'is_active')::boolean,false))::bigint,'Inactive historical relationships remain visible.','Do not use for new issuance.' union all
 select 'FACTOR_POLICY_FACTORED_READY','factoring','factored_carrier_with_usable_default','INFO',(select count(*) from public.carriers c where c.is_active and to_jsonb(c)->>'factoring_mode'='factored' and exists(select 1 from factor_rel r where r.carrier_id=c.id and coalesce((r.j->>'is_default')::boolean,false) and coalesce((r.j->>'is_active')::boolean,false) and r.company_active and nullif(r.j->>'effective_from','')::date<=current_date and (nullif(r.j->>'effective_to','') is null or (r.j->>'effective_to')::date>=current_date)))::bigint,'Factored carriers with an effective active default.','Review remaining readiness dependencies.' union all
 select 'FACTOR_POLICY_DISTRIBUTION_BAD','factoring','factoring_policy_count_disagreement','BLOCKER',(select ((select installed from fam where migration='0136') and count(*) filter(where is_active) <> count(*) filter(where is_active and to_jsonb(c)->>'factoring_mode' in ('unconfigured','direct','factored')))::int from public.carriers c)::bigint,'Active carrier policy counts do not reconcile.','Investigate policy state.' union all
 select 'FACTOR_REL_ASSIGNED','factoring','factoring_relationships_with_carrier','INFO',(select count(*) from factor_rel where carrier_id is not null)::bigint,'Relationships carrying a carrier ID.','Review mapping provenance.' union all
 select 'FACTOR_REL_UNASSIGNED','factoring','factoring_relationships_without_carrier','WARNING',(select count(*) from factor_rel where carrier_id is null)::bigint,'Relationships still lacking carrier ownership.','Review 0137 unresolved report; never guess.' union all
 select 'FACTOR_REL_CROSS_ORG','factoring','cross_organization_factor_relationship','BLOCKER',(select count(*) from factor_rel where carrier_id is not null and carrier_org is distinct from (j->>'organization_id')::uuid or company_id is not null and company_org is distinct from j->>'organization_id')::bigint,'Carrier or factoring company tenant differs.','Stop and repair tenant boundary.' union all
 select 'FACTOR_COMPANY_INACTIVE','factoring','inactive_factoring_company','WARNING',(select count(*) from factor_rel where not company_active)::bigint,'Relationships under inactive factoring companies.','Review default eligibility.' union all
 select 'FACTOR_DEFAULT_INACTIVE','factoring','inactive_default_relationship','BLOCKER',(select count(*) from factor_rel where coalesce((j->>'is_default')::boolean,false) and not coalesce((j->>'is_active')::boolean,false))::bigint,'Default relationship is inactive.','Resolve default designation.' union all
 select 'FACTOR_DEFAULT_FUTURE','factoring','future_effective_default','WARNING',(select count(*) from factor_rel where coalesce((j->>'is_default')::boolean,false) and nullif(j->>'effective_from','')::date>current_date)::bigint,'Default not yet effective.','Wait for effective date or configure a current default.' union all
 select 'FACTOR_DEFAULT_EXPIRED','factoring','expired_default','WARNING',(select count(*) from factor_rel where coalesce((j->>'is_default')::boolean,false) and nullif(j->>'effective_to','')::date<current_date)::bigint,'Default expired.','Configure an effective default.' union all
 select 'FACTOR_DEFAULT_MULTI','factoring','multiple_carrier_defaults','BLOCKER',(select count(*) from (select carrier_id from factor_rel where carrier_id is not null and coalesce((j->>'is_default')::boolean,false) group by carrier_id having count(*)>1) q)::bigint,'Multiple defaults for a carrier.','Resolve competing defaults.' union all
 select 'FACTOR_DEFAULT_COMPANY_CARRIER_DUP','factoring','duplicate_carrier_company_relationship','BLOCKER',(select count(*) from (select carrier_id,company_id from factor_rel where carrier_id is not null group by carrier_id,company_id having count(*)>1) q)::bigint,'Duplicate carrier/company relationship rows.','Review and consolidate configuration.' union all
 select 'FACTOR_DEFAULT_SUBMISSION_MISSING','factoring','default_submission_configuration_missing','WARNING',(select count(*) from factor_rel where coalesce((j->>'is_default')::boolean,false) and (nullif(j->>'submission_method','') is null or j->>'submission_method'='secure_email' and nullif(j->>'submission_destination_email','') is null or j->>'submission_method'='portal_manual' and nullif(j->>'submission_portal_url','') is null))::bigint,'Default lacks required submission configuration.','Complete the submission channel before issuance.' union all
 select 'FACTOR_REMIT_MISSING','factoring','factoring_remittance_missing','WARNING',(select count(*) from factor_rel where coalesce((j->>'is_default')::boolean,false) and nullif(btrim(coalesce(j->>'remittance_instructions','')),'') is null)::bigint,'Default lacks remittance instructions.','Configure approved remittance display text.' union all
 select 'FACTOR_NOA_UNAPPROVED','factoring','factoring_noa_unapproved','WARNING',(select count(*) from factor_rel where coalesce((j->>'is_default')::boolean,false) and not coalesce((j->>'noa_approved')::boolean,false))::bigint,'Default NOA is not approved.','Complete owner/admin NOA approval.' union all
 select 'FACTOR_NOA_METADATA','factoring','factoring_noa_metadata_missing','WARNING',(select count(*) from factor_rel where coalesce((j->>'noa_approved')::boolean,false) and (nullif(j->>'noa_approved_by','') is null or nullif(j->>'noa_approved_at','') is null or nullif(j->>'noa_reference','') is null or nullif(j->>'noa_effective_date','') is null))::bigint,'Approved NOA lacks required metadata.','Review approval and reference evidence.' union all
 select 'FACTOR_NOA_APPROVER_MISSING','factoring','approved_noa_approver_missing','BLOCKER',(select count(*) from factor_rel where coalesce((j->>'noa_approved')::boolean,false) and nullif(j->>'noa_approved_by','') is null)::bigint,'Approved NOA lacks approver identity.','Repeat approval through the authorized RPC.' union all
 select 'FACTOR_NOA_APPROVED_AT_MISSING','factoring','approved_noa_timestamp_missing','BLOCKER',(select count(*) from factor_rel where coalesce((j->>'noa_approved')::boolean,false) and nullif(j->>'noa_approved_at','') is null)::bigint,'Approved NOA lacks approval timestamp.','Repeat approval through the authorized RPC.' union all
 select 'FACTOR_NOA_EFFECTIVE_MISSING','factoring','approved_noa_effective_date_missing','BLOCKER',(select count(*) from factor_rel where coalesce((j->>'noa_approved')::boolean,false) and nullif(j->>'noa_effective_date','') is null)::bigint,'Approved NOA lacks effective date.','Configure an approved effective date.' union all
 select 'FACTOR_NOA_REFERENCE_MISSING','factoring','approved_noa_reference_missing','WARNING',(select count(*) from factor_rel where coalesce((j->>'noa_approved')::boolean,false) and nullif(j->>'noa_reference','') is null)::bigint,'Approved NOA lacks a reference label.','Add a non-sensitive reference.' union all
 select 'FACTOR_NOA_DATE_WINDOW','factoring','noa_date_outside_relationship_window','BLOCKER',(select count(*) from factor_rel where nullif(j->>'noa_effective_date','') is not null and (nullif(j->>'noa_effective_date','')::date<nullif(j->>'effective_from','')::date or nullif(j->>'effective_to','') is not null and (j->>'noa_effective_date')::date>(j->>'effective_to')::date))::bigint,'NOA effective date falls outside relationship dates.','Correct the relationship or approval window.' union all
 select 'FACTOR_NOA_DOCUMENT_DANGLING','factoring','noa_document_reference_dangling','BLOCKER',(select count(*) from factor_rel r where nullif(r.j->>'noa_document_id','') is not null and not exists(select 1 from docs d where d.j->>'id'=r.j->>'noa_document_id'))::bigint,'NOA document reference has no matching document row.','Stop and restore referential integrity.' union all
 select 'FACTOR_NOA_DOCUMENT_ORG_MISMATCH','factoring','noa_document_organization_mismatch','BLOCKER',(select count(*) from factor_rel r join docs d on d.j->>'id'=r.j->>'noa_document_id' where d.j->>'organization_id' is distinct from r.j->>'organization_id')::bigint,'NOA document and relationship organizations differ.','Stop and repair the cross-tenant reference.' union all
 select 'FACTOR_NOA_DOCUMENT','factoring','factoring_noa_document_unverified','WARNING',(select count(*) from factor_rel r join docs d on d.j->>'id'=r.j->>'noa_document_id' where d.j->>'organization_id'=r.j->>'organization_id' and not coalesce((d.j->>'is_verified')::boolean,false))::bigint,'Existing same-organization NOA document is not verified.','Complete document verification before readiness.' union all
 select 'FACTOR_NOA_DOCUMENT_METADATA','factoring','verified_noa_document_metadata_missing','BLOCKER',(select count(*) from factor_rel r join docs d on d.j->>'id'=r.j->>'noa_document_id' where coalesce((d.j->>'is_verified')::boolean,false) and (nullif(d.j->>'verified_by','') is null or nullif(d.j->>'verified_at','') is null))::bigint,'Verified NOA document lacks verification identity or time.','Repeat verification through the approved path.' union all
 select 'FACTOR_NOA_DOCUMENT_IDENTITY','factoring','noa_document_carrier_or_type_invalid','BLOCKER',(select count(*) from factor_rel r join docs d on d.j->>'id'=r.j->>'noa_document_id' where d.j->>'entity_type'<>'carrier' or d.j->>'entity_id' is distinct from r.j->>'carrier_id' or d.j->>'document_type' not in ('notice_of_assignment','factoring_notice'))::bigint,'NOA document is not an allowed carrier document for this relationship.','Select a verified NOA document belonging to the relationship carrier.' union all
 select 'FACTOR_NOA_VERIFIER_ORG','factoring','noa_document_verifier_wrong_organization','BLOCKER',(select count(*) from factor_rel r join docs d on d.j->>'id'=r.j->>'noa_document_id' left join public.profiles p on p.id=nullif(d.j->>'verified_by','')::uuid where nullif(d.j->>'verified_by','') is not null and p.organization_id is distinct from nullif(r.j->>'organization_id','')::uuid)::bigint,'NOA document verifier belongs to another organization or is absent.','Repeat verification using an authorized same-organization profile.' union all
 select 'FACTOR_INTEGRATION_TOTAL','factoring','factoring_integration_total','INFO',(select count(*) from cfi)::bigint,'Carrier factoring integration count.','Review lifecycle inventory.' union all
 select 'FACTOR_INTEGRATION_CROSS_ORG','factoring','factoring_integration_cross_organization','BLOCKER',(select count(*) from factor_integ where integration_carrier_org is not null and integration_carrier_org is distinct from j->>'organization_id' or relationship is not null and relationship->>'organization_id' is distinct from j->>'organization_id' or integration_company_org is not null and integration_company_org is distinct from j->>'organization_id' or relationship_company_org is not null and relationship_company_org is distinct from j->>'organization_id')::bigint,'Integration references an entity in another organization.','Investigate cross-tenant reference corruption; do not automatically reassign data.' union all
 select 'FACTOR_INTEGRATION_CARRIER_MISMATCH','factoring','factoring_integration_carrier_mismatch','BLOCKER',(select count(*) from factor_integ where relationship is not null and j->>'carrier_id' is distinct from relationship->>'carrier_id' and j->>'factoring_company_id' is not distinct from relationship->>'factoring_company_id')::bigint,'Integration carrier differs from its relationship carrier.','Verify the relationship intended carrier; do not guess or repoint historical data.' union all
 select 'FACTOR_INTEGRATION_RELATIONSHIP_MISMATCH','factoring','factoring_integration_relationship_mismatch','BLOCKER',(select count(*) from factor_integ where relationship is null or j->>'carrier_id' is distinct from relationship->>'carrier_id' and j->>'factoring_company_id' is distinct from relationship->>'factoring_company_id')::bigint,'Integration relationship does not match its carrier and factor identity.','Verify the integration and relationship linkage; create a replacement configuration if required.' union all
 select 'FACTOR_INTEGRATION_COMPANY_MISMATCH','factoring','factoring_integration_company_mismatch','BLOCKER',(select count(*) from factor_integ where relationship is not null and j->>'carrier_id' is not distinct from relationship->>'carrier_id' and j->>'factoring_company_id' is distinct from relationship->>'factoring_company_id')::bigint,'Integration factoring company differs from its relationship company.','Verify factor-company linkage; never silently switch factoring companies.' union all
 select 'FACTOR_INTEGRATION_READY_BAD','factoring','ready_integration_invalid','BLOCKER',(select count(*) from factor_integ where j->>'configuration_status'='ready' and (not coalesce((j->>'is_active')::boolean,false) or nullif(j->>'approved_by','') is null or nullif(j->>'approved_at','') is null or nullif(j->>'effective_to','') is not null))::bigint,'Ready integration violates active, approval, or finite-expiry rules.','Stop and review lifecycle.' union all
 select 'FACTOR_INTEGRATION_NONREADY_ACTIVE','factoring','nonready_integration_active','BLOCKER',(select count(*) from factor_integ where j->>'configuration_status'<>'ready' and coalesce((j->>'is_active')::boolean,false))::bigint,'Non-ready integration is active.','Deactivate until verified and ready.' union all
 select 'FACTOR_INTEGRATION_STATE_DRAFT','factoring','integration_state_draft','INFO',(select count(*) from factor_integ where j->>'configuration_status'='draft')::bigint,'Draft integration count.','Review lifecycle inventory.' union all
 select 'FACTOR_INTEGRATION_STATE_PENDING','factoring','integration_state_pending_verification','INFO',(select count(*) from factor_integ where j->>'configuration_status'='pending_verification')::bigint,'Pending-verification integration count.','Review lifecycle inventory.' union all
 select 'FACTOR_INTEGRATION_STATE_READY','factoring','integration_state_ready','INFO',(select count(*) from factor_integ where j->>'configuration_status'='ready')::bigint,'Ready integration count.','Review lifecycle inventory.' union all
 select 'FACTOR_INTEGRATION_STATE_SUSPENDED','factoring','integration_state_suspended','INFO',(select count(*) from factor_integ where j->>'configuration_status'='suspended')::bigint,'Suspended integration count.','Review lifecycle inventory.' union all
 select 'FACTOR_INTEGRATION_STATE_FAILED','factoring','integration_state_failed','INFO',(select count(*) from factor_integ where j->>'configuration_status'='failed')::bigint,'Failed integration count.','Review lifecycle inventory.' union all
 select 'FACTOR_INTEGRATION_STATE_REVOKED','factoring','integration_state_revoked','INFO',(select count(*) from factor_integ where j->>'configuration_status'='revoked')::bigint,'Revoked integration count.','Review lifecycle inventory.' union all
 select 'FACTOR_INTEGRATION_MULTI_ACTIVE','factoring','multiple_active_integrations','BLOCKER',(select count(*) from (select relationship_id from factor_integ where coalesce((j->>'is_active')::boolean,false) group by relationship_id having count(*)>1) q)::bigint,'Relationship has multiple active integrations.','Retain one supported active endpoint.' union all
 select 'FACTOR_INTEGRATION_READY_NONDEFAULT','factoring','ready_integration_nondefault_relationship','BLOCKER',(select count(*) from factor_integ where j->>'configuration_status'='ready' and not coalesce((relationship->>'is_default')::boolean,false))::bigint,'Ready integration belongs to a nondefault relationship.','Resolve default before activation.' union all
 select 'FACTOR_INTEGRATION_READY_DEPENDENCY','factoring','ready_integration_invalid_dependency','BLOCKER',(select count(*) from factor_integ i left join public.carriers c on c.id=nullif(i.j->>'carrier_id','')::uuid left join fc f on f.j->>'id'=i.j->>'factoring_company_id' where i.j->>'configuration_status'='ready' and (not coalesce((i.relationship->>'is_active')::boolean,false) or not coalesce((f.j->>'is_active')::boolean,false) or to_jsonb(c)->>'factoring_mode' is distinct from 'factored'))::bigint,'Ready integration has inactive relationship/company or non-factored carrier policy.','Stop and restore valid dependencies.' union all
 select 'FACTOR_INTEGRATION_DATE_BAD','factoring','integration_effective_dates_invalid','BLOCKER',(select count(*) from factor_integ where nullif(j->>'effective_to','') is not null and nullif(j->>'effective_from','')::date>nullif(j->>'effective_to','')::date)::bigint,'Integration effective dates are invalid.','Repair lifecycle dates.' union all
 select 'FACTOR_INTEGRATION_FUTURE','factoring','integration_not_yet_effective','WARNING',(select count(*) from factor_integ where nullif(j->>'effective_from','')::date>current_date)::bigint,'Integration is not yet effective.','Wait or configure the correct effective date.' union all
 select 'FACTOR_INTEGRATION_FINITE','factoring','ready_integration_finite_expiry','BLOCKER',(select count(*) from factor_integ where j->>'configuration_status'='ready' and nullif(j->>'effective_to','') is not null)::bigint,'Ready integration has finite expiry without a lifecycle scheduler.','Use a non-expiring integration or add approved lifecycle automation.' union all
 select 'FACTOR_INTEGRATION_PROVIDER_MISSING','factoring','api_integration_provider_missing','WARNING',(select count(*) from factor_integ where j->>'submission_method'='api' and nullif(j->>'provider','') is null)::bigint,'API integration lacks its provider classification.','Select the supported provider before readiness.' union all
 select 'FACTOR_INTEGRATION_SECRET_REFERENCE_MISSING','factoring','api_integration_secret_reference_missing','WARNING',(select count(*) from factor_integ where j->>'submission_method'='api' and nullif(j->>'secret_reference','') is null)::bigint,'API integration lacks an opaque credential reference.','Store only an approved vault or secret-store pointer.' union all
 select 'FACTOR_INTEGRATION_EXTERNAL_ACCOUNT_MISSING','factoring','api_integration_external_account_missing','WARNING',(select count(*) from factor_integ where j->>'submission_method'='api' and nullif(btrim(coalesce(j->>'external_account_identifier','')),'') is null)::bigint,'API integration lacks its external-account identifier.','Configure the non-secret account identifier before readiness.' union all
 select 'FACTOR_INTEGRATION_DESTINATION_MISSING','factoring','non_api_integration_destination_missing','WARNING',(select count(*) from factor_integ where j->>'submission_method' in ('secure_email','portal_manual') and nullif(btrim(coalesce(j->>'submission_destination','')),'') is null)::bigint,'Email or portal integration lacks its required destination.','Configure the approved email address or portal instructions.' union all
 select 'FACTOR_INTEGRATION_DESTINATION_INVALID','factoring','secure_email_integration_destination_invalid','WARNING',(select count(*) from factor_integ where j->>'submission_method'='secure_email' and nullif(j->>'submission_destination','') is not null and j->>'submission_destination' !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$')::bigint,'Secure-email integration destination is malformed.','Configure a valid approved email address.' union all
 select 'FACTOR_INTEGRATION_APPROVER_MISSING','factoring','ready_integration_approver_missing','BLOCKER',(select count(*) from factor_integ where j->>'configuration_status'='ready' and nullif(j->>'approved_by','') is null)::bigint,'Ready integration lacks approver identity.','Repeat activation through the authorized lifecycle RPC.' union all
 select 'FACTOR_INTEGRATION_APPROVED_AT_MISSING','factoring','ready_integration_approval_timestamp_missing','BLOCKER',(select count(*) from factor_integ where j->>'configuration_status'='ready' and nullif(j->>'approved_at','') is null)::bigint,'Ready integration lacks its approval timestamp.','Repeat activation through the authorized lifecycle RPC.' union all
 select 'FACTOR_INTEGRATION_READY_NOA_UNAPPROVED','factoring','ready_integration_noa_unapproved','BLOCKER',(select count(*) from factor_integ where j->>'configuration_status'='ready' and relationship is not null and (not coalesce((relationship->>'noa_approved')::boolean,false) or nullif(relationship->>'noa_approved_by','') is null or nullif(relationship->>'noa_approved_at','') is null or nullif(btrim(coalesce(relationship->>'noa_reference','')),'') is null or nullif(relationship->>'noa_effective_date','') is null))::bigint,'Ready integration depends on an unapproved or incomplete NOA.','Deactivate the integration and complete NOA approval through the authorized path.' union all
 select 'FACTOR_INTEGRATION_READY_NOA_DOCUMENT','factoring','ready_integration_noa_document_unverified','BLOCKER',(select count(*) from factor_integ i join docs d on d.j->>'id'=i.relationship->>'noa_document_id' where i.j->>'configuration_status'='ready' and not coalesce((d.j->>'is_verified')::boolean,false))::bigint,'Ready integration references an unverified NOA document.','Deactivate the integration and complete document verification.' union all
 select 'FACTOR_INTEGRATION_API_FIELDS','factoring','api_integration_configuration_missing','WARNING',(select count(*) from factor_integ where j->>'submission_method'='api' and (nullif(j->>'provider','') is null or nullif(j->>'secret_reference','') is null or nullif(j->>'external_account_identifier','') is null))::bigint,'API integration lacks provider, opaque reference, or external account identifier.','Complete API configuration without storing raw secrets.' union all
 select 'FACTOR_API_MISSING','factoring','api_integration_missing','WARNING',(select count(*) from factor_rel r where r.j->>'submission_method'='api' and not exists(select 1 from factor_integ i where i.relationship_id=nullif(r.j->>'id','')::uuid))::bigint,'API relationship lacks carrier-specific integration.','Create and verify integration before activation.' union all
 select 'FACTOR_API_NOT_READY','factoring','api_integration_not_ready','WARNING',(select count(*) from factor_rel r where r.j->>'submission_method'='api' and exists(select 1 from factor_integ i where i.relationship_id=nullif(r.j->>'id','')::uuid and (i.j->>'configuration_status'<>'ready' or not coalesce((i.j->>'is_active')::boolean,false))))::bigint,'API integration exists but is not ready.','Complete lifecycle verification.' union all
 select 'FACTOR_SECRET_REF_BAD','factoring','invalid_opaque_secret_reference','BLOCKER',(select count(*) from cfi where nullif(j->>'secret_reference','') is not null and j->>'secret_reference' !~ '^[a-z][a-z0-9+.-]*://[A-Za-z0-9_.~-]{1,200}$')::bigint,'Opaque secret reference has invalid shape; value suppressed.','Move secret to approved vault and store only its pointer.' union all
 select 'FACTOR_CREDENTIAL_CONFIG','factoring','credential_shaped_nonsecret_configuration','BLOCKER',(select count(*) from factor_rel where coalesce(j->>'submission_notes','') ~* '(sk_(live|test|restricted)_|rk_(live|test)_|whsec_|AKIA[0-9A-Z]{12,}|eyJ[A-Za-z0-9_-]+\.eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+|BEGIN([[:space:]]+(RSA|EC))?[[:space:]]+PRIVATE[[:space:]]+KEY|Bearer[[:space:]]+[A-Za-z0-9._-]+|[a-z]+://[^[:space:]]+:[^[:space:]@]+@|api[_-]?key[[:space:]]*[:=]|(client[_-]?secret|access[_-]?token|refresh[_-]?token|secret)[[:space:]]*[:=]|[[:cntrl:]])' or coalesce(j->>'remittance_instructions','') ~* '(sk_(live|test|restricted)_|rk_(live|test)_|whsec_|AKIA[0-9A-Z]{12,}|eyJ[A-Za-z0-9_-]+\.eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+|BEGIN([[:space:]]+(RSA|EC))?[[:space:]]+PRIVATE[[:space:]]+KEY|Bearer[[:space:]]+[A-Za-z0-9._-]+|[a-z]+://[^[:space:]]+:[^[:space:]@]+@|api[_-]?key[[:space:]]*[:=]|(client[_-]?secret|access[_-]?token|refresh[_-]?token|secret)[[:space:]]*[:=]|[[:cntrl:]])')::bigint,'Credential-shaped material in ordinary configuration; values suppressed.','Remove exposed material and rotate credentials.' union all
 select 'LEGACY_INVOICE_TOTAL','legacy_invoices','legacy_invoice_total','INFO',(select count(*) from legacy_invoice_class)::bigint,'Legacy invoice rows remain in public.invoices.','Inventory only; never auto-convert.' union all
 select 'LEGACY_STATUS_DRAFT','legacy_invoices','legacy_status_draft','INFO',(select count(*) from legacy_invoice_class where status='draft')::bigint,'Draft legacy invoice count.','Review historical inventory.' union all
 select 'LEGACY_STATUS_SENT','legacy_invoices','legacy_status_sent_or_viewed','INFO',(select count(*) from legacy_invoice_class where status in ('sent','viewed'))::bigint,'Sent or viewed legacy invoice count.','Review issued historical documents.' union all
 select 'LEGACY_STATUS_PARTIAL','legacy_invoices','legacy_status_partially_paid','BLOCKER',(select count(*) from legacy_invoice_class where status='partially_paid' or amount_paid>0 and amount_paid<total_amount)::bigint,'Partially paid legacy invoices exist.','Preserve payment history; do not convert automatically.' union all
 select 'LEGACY_STATUS_PAID','legacy_invoices','legacy_status_paid','BLOCKER',(select count(*) from legacy_invoice_class where status='paid')::bigint,'Paid legacy invoices exist.','Preserve settled history; do not convert automatically.' union all
 select 'LEGACY_STATUS_OVERDUE','legacy_invoices','legacy_status_overdue','INFO',(select count(*) from legacy_invoice_class where status='overdue')::bigint,'Overdue legacy invoice count.','Review receivables without converting documents.' union all
 select 'LEGACY_STATUS_VOID','legacy_invoices','legacy_status_void','INFO',(select count(*) from legacy_invoice_class where status='void')::bigint,'Voided legacy invoice count.','Retain immutable historical status.' union all
 select 'LEGACY_AMOUNT_PAID','legacy_invoices','legacy_amount_paid_positive','BLOCKER',(select count(*) from legacy_invoice_class where amount_paid>0)::bigint,'Legacy invoices contain recorded payment value.','Preserve payment history; do not auto-convert.' union all
 select 'LEGACY_PAYMENT_POSTED','legacy_invoices','legacy_posted_payment_rows','BLOCKER',(select count(distinct j->>'invoice_id') from legacy_payments where coalesce(j->>'status','posted')='posted')::bigint,'Legacy invoices have posted payment rows.','Preserve payment ledger and reconcile manually.' union all
 select 'LEGACY_PAYMENT_VOIDED','legacy_invoices','legacy_voided_payment_history','INFO',(select count(distinct j->>'invoice_id') from legacy_payments where j->>'status'='voided')::bigint,'Legacy invoices have voided payment history.','Retain reversal history.' union all
 select 'LEGACY_FACTOR_ACTIVITY','legacy_invoices','legacy_factoring_activity','BLOCKER',(select count(distinct j->>'invoice_id') from fi)::bigint,'Legacy invoices have factoring records.','Preserve factoring history; do not auto-convert.' union all
 select 'LEGACY_FACTOR_NONTERMINAL','legacy_invoices','legacy_nonterminal_factoring_activity','BLOCKER',(select count(distinct j->>'invoice_id') from fi where j->>'status' not in ('rejected','cancelled','closed'))::bigint,'Legacy invoices have nonterminal factoring activity.','Resolve externally governed lifecycle before any reissue.' union all
 select 'LEGACY_PAYMENT_AND_FACTOR','legacy_invoices','legacy_payment_and_factoring_activity','BLOCKER',(select count(*) from legacy_invoice_class i where exists(select 1 from legacy_payments p where p.j->>'invoice_id'=i.id::text) and exists(select 1 from fi f where f.j->>'invoice_id'=i.id::text))::bigint,'Legacy invoices have both payment and factoring history.','Stop automatic handling and reconcile both histories.' union all
 select 'LEGACY_FINANCIAL_METADATA_MISSING','legacy_invoices','legacy_required_financial_metadata_missing','WARNING',(select count(*) from legacy_invoice_class where invoice_json->>'total_amount' is null or invoice_json->>'due_date' is null or invoice_json->>'currency' is null)::bigint,'Legacy model lacks one or more modern total, due-date, or currency fields.','Review before any manual reissue.' union all
 select 'LEGACY_STATUS_AMOUNT_INCONSISTENT','legacy_invoices','legacy_status_amount_payment_inconsistent','BLOCKER',(select count(*) from legacy_invoice_class i where status='paid' and amount_paid<total_amount or status='partially_paid' and not (amount_paid>0 and amount_paid<total_amount) or amount_paid>total_amount or exists(select 1 from legacy_payments p where p.j->>'invoice_id'=i.id::text and coalesce(p.j->>'status','posted')='posted') and amount_paid=0)::bigint,'Legacy status, amount, or payment rows disagree.','Reconcile authoritative payment history before review.' union all
 select 'LEGACY_CLASSIFIER_DEFINITION_DEFECT','legacy_invoices','legacy_classifier_definition_contract','BLOCKER',(select case
   when to_regclass('public.carrier_invoices') is null then 0
   when (select count(*) from pg_proc p where p.pronamespace='public'::regnamespace and p.proname='classify_legacy_invoice_for_carrier_migration') <> 1 then 1
   when to_regprocedure('public.classify_legacy_invoice_for_carrier_migration(uuid)') is null then 1
   when (select p.prosrc from pg_proc p where p.oid=to_regprocedure('public.classify_legacy_invoice_for_carrier_migration(uuid)')) ilike '%carrier_resolution = ''conflicting''%' then 1
   when (select p.prosrc from pg_proc p where p.oid=to_regprocedure('public.classify_legacy_invoice_for_carrier_migration(uuid)')) ilike '%unresolved_carrier_records%' then 1
   when (select p.prosrc from pg_proc p where p.oid=to_regprocedure('public.classify_legacy_invoice_for_carrier_migration(uuid)')) not ilike '%financial_dispatch_id%' then 1
   when (select p.prosrc from pg_proc p where p.oid=to_regprocedure('public.classify_legacy_invoice_for_carrier_migration(uuid)')) not ilike '%array_agg(distinct d.carrier_id)%' then 1
   when (select p.prosrc from pg_proc p where p.oid=to_regprocedure('public.classify_legacy_invoice_for_carrier_migration(uuid)')) not ilike '%status <> ''cancelled''%' then 1
   else 0 end)::bigint,'The installed legacy classifier must be the one exact UUID overload and must use the corrected live controller/dispatch evidence contract. The vulnerable impossible carrier_resolution literal, diagnostic-log authority, missing/extra overloads, or an unrecognized definition are release blockers; no function body is output.','Apply the reviewed 0147 classifier correction before production traffic.' union all
 select 'LEGACY_CLASS_SAFE','legacy_invoices','classification_safely_identifiable_legacy','INFO',(select count(*) from legacy_invoice_class where classification='safely_identifiable_legacy')::bigint,'Legacy invoices have deterministic recipient and carrier evidence.','Keep legacy; manual review and reissue remain required.' union all
 select 'LEGACY_CLASS_MISSING_RECIPIENT','legacy_invoices','classification_missing_recipient','WARNING',(select count(*) from legacy_invoice_class where classification='missing_recipient')::bigint,'Legacy invoices lack a recipient.','Review without guessing.' union all
 select 'LEGACY_CLASS_VOID','legacy_invoices','classification_voided_cancelled','INFO',(select count(*) from legacy_invoice_class where classification='voided_cancelled')::bigint,'Classifier excludes void legacy invoices first.','Retain historical record.' union all
 select 'LEGACY_CLASS_PAID','legacy_invoices','classification_paid_or_partially_paid','BLOCKER',(select count(*) from legacy_invoice_class where classification='paid_or_partially_paid')::bigint,'Classifier excludes paid history before factoring or identity checks.','Preserve historical payment state.' union all
 select 'LEGACY_CLASS_NO_CARRIER','legacy_invoices','classification_missing_carrier_evidence','WARNING',(select count(*) from legacy_invoice_class where classification='missing_carrier_evidence')::bigint,'Legacy invoices lack deterministic load carrier evidence.','Never guess a carrier.' union all
 select 'LEGACY_CLASS_CARRIER_CONFLICT','legacy_invoices','classification_conflicting_carrier_evidence','BLOCKER',(select count(*) from legacy_invoice_class where classification='conflicting_carrier_evidence')::bigint,'Legacy load carrier evidence is conflicting. Phase 3C.2 disclosure: pre-0147 this can only be nonzero via a constraint-bypass corruption (the installed classifier''s carrier_resolution=''conflicting'' branch is otherwise unreachable -- release BLOCKER #1); post-0147 the corrected classifier derives this LIVE from public.dispatches, so a nonzero count can ALSO mean a genuine, currently-unresolved carrier disagreement among real legacy loads -- expected, reviewable data, not necessarily corruption. A human must distinguish the two before treating a post-0147 nonzero count as a stop condition; this finding''s BLOCKER severity is retained unchanged from its original definition specifically so the permanent corruption fixture''s own before/after (1 at exactly the 0146 boundary, 0 at exactly the 0147 boundary) remains a stable, unambiguous proof that the defect itself is fixed.','Pre-0147: stop, this is release BLOCKER #1. Post-0147: review the specific legacy invoice(s) -- resolve genuine carrier ambiguity manually; escalate only if evidence looks corrupted rather than genuinely ambiguous.' union all
 select 'LEGACY_CLASS_RECIPIENT_CONFLICT','legacy_invoices','classification_conflicting_recipient_evidence','BLOCKER',(select count(*) from legacy_invoice_class where classification='conflicting_recipient_evidence')::bigint,'Legacy invoice has both recipient types.','Resolve legal recipient manually.' union all
 select 'LEGACY_CLASS_FACTORING','legacy_invoices','classification_existing_factoring_activity','BLOCKER',(select count(*) from legacy_invoice_class where classification='existing_factoring_activity')::bigint,'Classifier excludes any existing factoring record.','Preserve factoring lifecycle.' union all
 select 'LEGACY_REVIEW_TOTAL','legacy_invoices','legacy_review_row_total','INFO',(select count(*) from legacy_review)::bigint,'Legacy migration review row count.','Review explicit human workflow inventory.' union all
 select 'LEGACY_REVIEW_UNREVIEWED','legacy_invoices','legacy_review_unreviewed','INFO',(select count(*) from legacy_review where not coalesce((j->>'reviewed')::boolean,false))::bigint,'Unreviewed legacy classifications remain.','Complete only through authorized RPC.' union all
 select 'LEGACY_REVIEW_ORPHAN','legacy_invoices','legacy_review_invoice_missing','BLOCKER',(select count(*) from legacy_review r where not exists(select 1 from legacy_invoice_class i where i.id::text=r.j->>'legacy_invoice_id'))::bigint,'Review row has no legacy invoice.','Restore referential integrity.' union all
 select 'LEGACY_REVIEW_ORG_MISMATCH','legacy_invoices','legacy_review_organization_mismatch','BLOCKER',(select count(*) from legacy_review r join legacy_invoice_class i on i.id::text=r.j->>'legacy_invoice_id' where i.organization_id::text is distinct from r.j->>'organization_id')::bigint,'Review row and invoice organizations differ.','Investigate cross-tenant corruption.' union all
 select 'LEGACY_REVIEW_CLASS_MISMATCH','legacy_invoices','legacy_review_classification_stale','WARNING',(select count(*) from legacy_review r join legacy_invoice_class i on i.id::text=r.j->>'legacy_invoice_id' where r.j->>'classification' is distinct from i.classification)::bigint,'Stored review classification differs from current read-only classification.','Rescan only through explicit authorized workflow.' union all
 select 'LEGACY_REVIEW_METADATA_BAD','legacy_invoices','legacy_review_metadata_invalid','BLOCKER',(select count(*) from legacy_review where coalesce((j->>'reviewed')::boolean,false) <> (nullif(j->>'reviewed_by','') is not null and nullif(j->>'reviewed_at','') is not null and nullif(btrim(coalesce(j->>'resolution','')),'') is not null))::bigint,'Review state and server-derived metadata disagree.','Repair integrity without forging reviewer identity.' union all
 select 'LEGACY_REVIEW_GRANTS_BAD','legacy_invoices','legacy_review_unexpected_client_writes','BLOCKER',(select (to_regclass('public.legacy_invoice_carrier_migration_review') is not null and (has_table_privilege('authenticated','public.legacy_invoice_carrier_migration_review','INSERT') or has_table_privilege('authenticated','public.legacy_invoice_carrier_migration_review','UPDATE') or has_table_privilege('authenticated','public.legacy_invoice_carrier_migration_review','DELETE')))::int)::bigint,'Legacy review table has unexpected client write grants.','Revoke direct writes; retain guarded RPC only.' union all
 select 'LEGACY_NO_AUTO_CONVERSION','legacy_invoices','legacy_invoices_remain_separate','INFO',(select count(*) from legacy_invoice_class)::bigint,'Legacy invoices remain in public.invoices and are never carrier invoices automatically.','Use explicit review and legally valid reissue only.' union all
 -- Phase 3C.0E carrier-invoice/snapshot/billing/payment findings (manifest
 -- rows 81-96). Counts only -- no invoice number, carrier/broker/customer
 -- identity, payment reference, idempotency key, or snapshot content is
 -- ever selected or printed.
 select 'CINV_FAMILY_PARTIAL','carrier_invoice','carrier_invoice_family_partial_installation','BLOCKER',(select count(*) from fam where migration in ('0142','0143','0144','0145','0146') and split)::bigint,'A 0142-0146 sub-migration has only one of its two landmark objects installed.','Stop; compare with its preflight/post-apply verifier.' union all
 select 'CINV_TOTAL','carrier_invoice','carrier_invoice_total','INFO',(select count(*) from civ)::bigint,'Carrier-invoice row count; no invoice numbers, identities, or amounts selected.','Review inventory.' union all
 select 'CINV_FREIGHT_TOTAL','carrier_invoice','carrier_freight_invoice_total','INFO',(select count(*) from civ where j->>'invoice_document_type'='carrier_freight_invoice')::bigint,'Carrier freight-invoice count.','Review inventory.' union all
 select 'CINV_DISPATCH_TOTAL','carrier_invoice','dispatch_service_invoice_total','INFO',(select count(*) from civ where j->>'invoice_document_type'='dispatch_service_invoice')::bigint,'Dispatch-service invoice count.','Review inventory.' union all
 select 'CINV_STATUS_DRAFT','carrier_invoice','issuance_status_draft','INFO',(select count(*) from civ where j->>'issuance_status'='draft')::bigint,'Draft invoice count.','Review inventory.' union all
 select 'CINV_STATUS_READY','carrier_invoice','issuance_status_ready_for_issue','INFO',(select count(*) from civ where j->>'issuance_status'='ready_for_issue')::bigint,'Ready-for-issue invoice count.','Review inventory.' union all
 select 'CINV_STATUS_ISSUED','carrier_invoice','issuance_status_issued','INFO',(select count(*) from civ where j->>'issuance_status'='issued')::bigint,'Issued invoice count.','Review inventory.' union all
 select 'CINV_STATUS_VOIDED','carrier_invoice','issuance_status_voided','INFO',(select count(*) from civ where j->>'issuance_status'='voided')::bigint,'Voided invoice count.','Review inventory.' union all
 select 'CINV_ISSUED_TOTAL','carrier_invoice','issued_invoice_total','INFO',(select count(*) from civ where j->>'issuance_status' in ('issued','voided'))::bigint,'Invoices that have ever been issued (issued or later voided).','Review inventory.' union all
 select 'CINV_PAY_UNPAID','carrier_invoice','payment_status_unpaid','INFO',(select count(*) from civ where j->>'payment_status'='unpaid')::bigint,'Unpaid invoice count.','Review inventory.' union all
 select 'CINV_PAY_PARTIAL','carrier_invoice','payment_status_partially_paid','INFO',(select count(*) from civ where j->>'payment_status'='partially_paid')::bigint,'Partially paid invoice count.','Review inventory.' union all
 select 'CINV_PAY_PAID','carrier_invoice','payment_status_paid','INFO',(select count(*) from civ where j->>'payment_status'='paid')::bigint,'Paid invoice count.','Review inventory.' union all
 select 'CINV_DRAFT_PAID_AMOUNT','carrier_invoice','draft_or_ready_nonzero_amount_paid','BLOCKER',(select count(*) from civ where j->>'issuance_status' in ('draft','ready_for_issue') and coalesce((j->>'amount_paid')::numeric,0)<>0)::bigint,'Draft/ready invoice carries nonzero amount_paid.','Structural contradiction; stop and investigate a bypassed constraint.' union all
 select 'CINV_ISSUED_NO_NUMBER','carrier_invoice','issued_missing_invoice_number','BLOCKER',(select count(*) from civ where j->>'issuance_status' in ('issued','voided') and nullif(j->>'invoice_number','') is null)::bigint,'Issued or voided invoice lacks an invoice number.','Structural contradiction; stop.' union all
 select 'CINV_VOIDED_NO_REASON','carrier_invoice','voided_missing_reason','BLOCKER',(select count(*) from civ where j->>'issuance_status'='voided' and nullif(btrim(coalesce(j->>'void_reason','')),'') is null)::bigint,'Voided invoice lacks a void reason.','Structural contradiction; stop.' union all
 select 'CINV_OVERPAID','carrier_invoice','amount_paid_exceeds_total','BLOCKER',(select count(*) from civ where coalesce((j->>'amount_paid')::numeric,0)>coalesce((j->>'total_amount')::numeric,0))::bigint,'Invoice amount_paid exceeds total_amount.','Structural contradiction; stop.' union all
 select 'CINV_PAY_STATUS_INCONSISTENT','carrier_invoice','payment_status_amount_inconsistent','BLOCKER',(select count(*) from civ where (j->>'payment_status'='unpaid' and coalesce((j->>'amount_paid')::numeric,0)<>0) or (j->>'payment_status'='partially_paid' and not (coalesce((j->>'amount_paid')::numeric,0)>0 and coalesce((j->>'amount_paid')::numeric,0)<coalesce((j->>'total_amount')::numeric,0))) or (j->>'payment_status'='paid' and coalesce((j->>'amount_paid')::numeric,0)<>coalesce((j->>'total_amount')::numeric,0)))::bigint,'Invoice payment_status disagrees with amount_paid/total_amount.','Structural contradiction; stop.' union all
 select 'CINV_SNAP_TOTAL','carrier_invoice','issuance_snapshot_total','INFO',(select count(*) from civs_ids)::bigint,'Issuance snapshot row count; payload never selected.','Review inventory.' union all
 select 'CINV_SNAP_V2_TOTAL','carrier_invoice','snapshot_schema_version_2_total','INFO',(select count(*) from civs_problem where j->>'schema_version_raw'='2')::bigint,'Snapshot count at schema_version 2, the only supported canonical version.','Review inventory.' union all
 select 'CINV_SNAP_V1_TOTAL','carrier_invoice','snapshot_schema_version_1_total','INFO',(select count(*) from civs_problem where j->>'schema_version_raw'='1')::bigint,'Snapshot count at the superseded schema_version 1 shape; none should exist after 0146.','Investigate if nonzero.' union all
 select 'CINV_SNAP_FREIGHT_TOTAL','carrier_invoice','snapshot_freight_total','INFO',(select count(*) from civs_problem where j->>'invoice_document_type'='carrier_freight_invoice')::bigint,'Snapshot count for carrier_freight_invoice.','Review inventory.' union all
 select 'CINV_SNAP_DISPATCH_TOTAL','carrier_invoice','snapshot_dispatch_total','INFO',(select count(*) from civs_problem where j->>'invoice_document_type'='dispatch_service_invoice')::bigint,'Snapshot count for dispatch_service_invoice.','Review inventory.' union all
 select 'CINV_SNAP_MISSING','carrier_invoice','issued_invoice_missing_snapshot','BLOCKER',(select count(*) from civ where j->>'issuance_status' in ('issued','voided') and not exists(select 1 from civs_ids s where s.invoice_id=j->>'id'))::bigint,'Issued or voided invoice has no issuance snapshot.','Structural contradiction; stop.' union all
 select 'CINV_SNAP_UNEXPECTED','carrier_invoice','draft_invoice_has_snapshot','BLOCKER',(select count(*) from civ where j->>'issuance_status' in ('draft','ready_for_issue') and exists(select 1 from civs_ids s where s.invoice_id=j->>'id'))::bigint,'Draft or ready-for-issue invoice already has an issuance snapshot.','Structural contradiction; stop.' union all
 select 'CINV_SNAP_DUP','carrier_invoice','duplicate_snapshot_per_invoice','BLOCKER',(select count(*) from (select invoice_id from civs_ids group by invoice_id having count(*)>1) q)::bigint,'More than one issuance snapshot exists for a single invoice.','Structural contradiction; stop.' union all
 select 'CINV_SNAP_VERSION_BAD','carrier_invoice','snapshot_version_missing_malformed_or_unknown','BLOCKER',(select count(*) from civs_problem where j->>'problem_code' like 'VERSION_%')::bigint,'Issuance snapshot has a missing, null, non-numeric, or unsupported schema_version. Content never selected.','Stop; investigate independently of any client-facing message.' union all
 select 'CINV_SNAP_INTEGRITY_BAD','carrier_invoice','snapshot_internally_inconsistent','BLOCKER',(select count(*) from civs_problem where j->>'problem_code' is not null and j->>'problem_code' not like 'VERSION_%')::bigint,'Issuance snapshot fails the installed version-aware consistency validator (identity, currency, total, recipient, or factoring shape). Content never selected.','Stop; investigate independently of any client-facing message.' union all
 select 'CIVP_TOTAL','carrier_invoice','payment_total','INFO',(select count(*) from civp)::bigint,'Carrier-invoice payment row count; no references or amounts selected.','Review inventory.' union all
 select 'CIVP_POSTED','carrier_invoice','payment_posted_total','INFO',(select count(*) from civp where j->>'status'='posted')::bigint,'Posted payment count.','Review inventory.' union all
 select 'CIVP_VOIDED','carrier_invoice','payment_voided_total','INFO',(select count(*) from civp where j->>'status'='voided')::bigint,'Voided payment count.','Review inventory.' union all
 select 'CIVP_NEGATIVE_AMOUNT','carrier_invoice','payment_amount_nonpositive','BLOCKER',(select count(*) from civp where coalesce((j->>'amount')::numeric,0)<=0)::bigint,'Payment amount is zero or negative.','Structural contradiction; stop.' union all
 select 'CIVP_VOID_NO_REASON','carrier_invoice','voided_payment_missing_reason','BLOCKER',(select count(*) from civp where j->>'status'='voided' and nullif(btrim(coalesce(j->>'void_reason','')),'') is null)::bigint,'Voided payment lacks a reason.','Structural contradiction; stop.' union all
 select 'CIVP_CURRENCY_MISMATCH','carrier_invoice','payment_currency_mismatches_invoice','BLOCKER',(select count(*) from civp p join civ i on i.j->>'id'=p.j->>'carrier_invoice_id' where p.j->>'currency' is distinct from i.j->>'currency')::bigint,'Payment currency differs from its invoice currency.','Structural contradiction; stop.' union all
 select 'CIVP_AGAINST_UNISSUED','carrier_invoice','payment_against_unissued_invoice','BLOCKER',(select count(*) from civp p join civ i on i.j->>'id'=p.j->>'carrier_invoice_id' where i.j->>'issuance_status' in ('draft','ready_for_issue'))::bigint,'Payment recorded against a draft or ready-for-issue invoice.','Structural contradiction; stop.' union all
 select 'CIVP_ROLLUP_BAD','carrier_invoice','invoice_amount_paid_disagrees_with_payments','BLOCKER',(select count(*) from civ i where i.j->>'issuance_status' in ('issued','voided') and coalesce((select sum((p.j->>'amount')::numeric) from civp p where p.j->>'carrier_invoice_id'=i.j->>'id' and p.j->>'status'='posted'),0) is distinct from coalesce((i.j->>'amount_paid')::numeric,0))::bigint,'Invoice amount_paid disagrees with the sum of its posted (nonvoided) payments.','Structural contradiction; stop.' union all
 -- Phase 3C.0E.3 Section C/D/E: payment-row and void defense-in-depth,
 -- and rollup-vs-payment-status cross-checks, beyond what 0146's own
 -- record_/void_carrier_invoice_payment() RPCs already guarantee.
 select 'CIVP_ORG_MISMATCH','carrier_invoice','payment_organization_disagrees_with_invoice','BLOCKER',(select count(*) from civp p join civ i on i.j->>'id'=p.j->>'carrier_invoice_id' where p.j->>'organization_id' is distinct from i.j->>'organization_id')::bigint,'Payment organization disagrees with its invoice''s organization.','Structural contradiction; stop.' union all
 select 'CIVP_PAYER_MISMATCH','carrier_invoice','payment_payer_disagrees_with_invoice_identity','BLOCKER',(select count(*) from civp p join civ i on i.j->>'id'=p.j->>'carrier_invoice_id' where (i.j->>'invoice_document_type'='dispatch_service_invoice' and (p.j->>'payer_type'<>'carrier' or p.j->>'payer_carrier_id' is distinct from i.j->>'carrier_id')) or (i.j->>'invoice_document_type'='carrier_freight_invoice' and p.j->>'payer_type' is distinct from i.j->>'recipient_type'))::bigint,'Payment payer identity disagrees with the invoice''s own recipient/carrier identity -- never client-supplied by the real RPC, defense-in-depth only.','Structural contradiction; stop.' union all
 select 'CIVP_VOID_NO_VOIDED_AT','carrier_invoice','voided_payment_missing_voided_at','BLOCKER',(select count(*) from civp where j->>'status'='voided' and nullif(j->>'voided_at','') is null)::bigint,'Voided payment lacks voided_at.','Structural contradiction; stop.' union all
 select 'CIVP_VOID_NO_VOIDED_BY','carrier_invoice','voided_payment_missing_voided_by','BLOCKER',(select count(*) from civp where j->>'status'='voided' and nullif(j->>'voided_by','') is null)::bigint,'Voided payment lacks voided_by.','Structural contradiction; stop.' union all
 select 'CIVP_POSTED_AFTER_VOID','carrier_invoice','payment_recorded_after_invoice_voided','BLOCKER',(select count(*) from civp p join civ i on i.j->>'id'=p.j->>'carrier_invoice_id' where i.j->>'issuance_status'='voided' and p.j->>'status'='posted' and nullif(p.j->>'created_at','') is not null and nullif(i.j->>'voided_at','') is not null and (p.j->>'created_at')::timestamptz>(i.j->>'voided_at')::timestamptz)::bigint,'A posted payment was created strictly after its invoice was voided -- the RPC refuses new payments on a voided invoice, so this can only happen via a direct bypass.','Structural contradiction; stop.' union all
 select 'CIVP_STATUS_ROLLUP_BAD','carrier_invoice','invoice_payment_status_disagrees_with_calculated_status','BLOCKER',(select count(*) from civ i where i.j->>'issuance_status' in ('issued','voided') and i.j->>'payment_status' is distinct from (case when coalesce((i.j->>'amount_paid')::numeric,0)=0 then 'unpaid' when (i.j->>'amount_paid')::numeric>=(i.j->>'total_amount')::numeric then 'paid' else 'partially_paid' end))::bigint,'Invoice payment_status disagrees with the status record_/void_carrier_invoice_payment() would have derived from amount_paid/total_amount.','Structural contradiction; stop.' union all
 select 'CIVP_FACTORED_PAYMENT','carrier_invoice','factored_invoice_has_ordinary_payment','BLOCKER',(select count(*) from civp p join civs_problem sp on sp.j->>'invoice_id'=p.j->>'carrier_invoice_id' where (sp.j->>'is_factored')::boolean and p.j->>'status'='posted')::bigint,'A factored carrier freight invoice has an ordinary carrier_invoice_payments row. Factoring funding is never an ordinary payment.','Stop; this is always a release blocker. Route factored receipts through a funding workflow, never record_carrier_invoice_payment().' union all
 select 'CDSA_TOTAL','carrier_invoice','dispatch_service_agreement_total','INFO',(select count(*) from cdsa)::bigint,'Dispatch-service agreement count.','Review inventory.' union all
 select 'CDSAV_TOTAL','carrier_invoice','dispatch_service_agreement_version_total','INFO',(select count(*) from cdsav)::bigint,'Dispatch-service agreement version count.','Review inventory.' union all
 select 'CDSAV_APPROVED','carrier_invoice','dispatch_service_agreement_version_approved','INFO',(select count(*) from cdsav where j->>'status'='approved')::bigint,'Approved version count.','Review inventory.' union all
 select 'CDSAV_APPROVAL_FIELDS_BAD','carrier_invoice','dispatch_service_version_approval_fields_invalid','BLOCKER',(select count(*) from cdsav where (j->>'status'='draft' and (nullif(j->>'approved_by','') is not null or nullif(j->>'approved_at','') is not null)) or (j->>'status' in ('approved','superseded') and (nullif(j->>'approved_by','') is null or nullif(j->>'approved_at','') is null)))::bigint,'Agreement version approval fields disagree with its status.','Structural contradiction; stop.' union all
 select 'CDSAV_NEGATIVE_FEE','carrier_invoice','dispatch_service_negative_fee_configuration','BLOCKER',(select count(*) from cdsav where coalesce((j->>'percentage_rate')::numeric,0)<0 or coalesce((j->>'flat_fee_per_load')::numeric,0)<0)::bigint,'Agreement version has a negative fee configuration.','Structural contradiction; stop.' union all
 select 'CDSBL_TOTAL','carrier_invoice','dispatch_service_billing_line_total','INFO',(select count(*) from cdsbl)::bigint,'Dispatch-service billing-ledger row count.','Review inventory.' union all
 select 'CDSBL_DUP_LOAD','carrier_invoice','dispatch_service_load_billed_twice','BLOCKER',(select count(*) from (select j->>'load_id' lid from cdsbl group by j->>'load_id' having count(*)>1) q)::bigint,'A load has more than one dispatch-service billing line.','Structural contradiction; stop.' union all
 select 'CDSBL_MISSING_VERSION','carrier_invoice','dispatch_service_billing_line_missing_version','BLOCKER',(select count(*) from cdsbl b where not exists(select 1 from cdsav v where v.j->>'id'=b.j->>'agreement_version_id'))::bigint,'Billing line references a missing agreement version.','Structural contradiction; stop.' union all
 select 'CDSBL_WRONG_DOCTYPE','carrier_invoice','dispatch_fee_billed_against_freight_invoice','BLOCKER',(select count(*) from cdsbl b join civ i on i.j->>'id'=b.j->>'invoice_id' where i.j->>'invoice_document_type' is distinct from 'dispatch_service_invoice')::bigint,'A dispatch-service billing line references an invoice that is not a dispatch_service_invoice.','Stop; this is always a release blocker. The dispatch organization must invoice its fee separately, never deduct it from the carrier freight invoice.' union all
 select 'CIVLI_TOTAL','carrier_invoice','lifecycle_idempotency_total','INFO',(select count(*) from civli)::bigint,'Carrier-invoice lifecycle idempotency row count.','Review inventory.' union all
 -- Phase 3C.0E.3 Section F: idempotency-row defense-in-depth (structural
 -- shape only -- the RPCs'' own replay/collision/fingerprint behavior is
 -- proven directly by TEST_0146 Section B7/B10 and TEST_CONCURRENCY_0146
 -- scenarios 4-6, cited in the runbook, not reimplemented here).
 select 'CIVLI_ORPHAN_INVOICE','carrier_invoice','idempotency_row_invoice_missing','BLOCKER',(select count(*) from civli l where not exists(select 1 from civ i where i.j->>'id'=l.j->>'invoice_id'))::bigint,'A lifecycle idempotency row references an invoice that no longer exists.','Structural contradiction; stop.' union all
 select 'CIVLI_ORG_MISMATCH','carrier_invoice','idempotency_row_wrong_organization','BLOCKER',(select count(*) from civli l join civ i on i.j->>'id'=l.j->>'invoice_id' where l.j->>'organization_id' is distinct from i.j->>'organization_id')::bigint,'A lifecycle idempotency row''s organization disagrees with its own invoice.','Structural contradiction; stop.' union all
 select 'CIVLI_UNKNOWN_OPERATION','carrier_invoice','idempotency_row_unknown_operation','WARNING',(select count(*) from civli where j->>'operation' not in ('update_draft','issue_carrier_invoice','record_carrier_invoice_payment','void_carrier_invoice_payment'))::bigint,'A lifecycle idempotency row carries an operation value outside the currently-documented set.','Review; confirm this is a newer, intentionally added operation.' union all
 select 'CDSAI_TOTAL','carrier_invoice','agreement_idempotency_total','INFO',(select count(*) from cdsai)::bigint,'Dispatch-service agreement idempotency row count.','Review inventory.' union all
 select 'CINV_PRE0146_SNAPSHOT','carrier_invoice','snapshot_exists_before_0146','BLOCKER',((select count(*) from civs_ids)>0 and not (select installed from fam where migration='0146'))::int::bigint,'An issuance snapshot exists while 0146 is not fully installed; 0146 requires zero pre-existing snapshots.','Stop; 0146 cannot be safely applied. Investigate before proceeding.' union all
 select 'CINV_PRE0146_PAYMENT','carrier_invoice','payment_exists_before_0146_complete','BLOCKER',((select count(*) from civp)>0 and not (select installed from fam where migration='0146'))::int::bigint,'A carrier_invoice_payments row exists while 0146 is not fully installed.','Stop; investigate partial installation with financial data present.' union all
 -- Phase 3C.0E.1: exact invoice-state matrix (mission Section B), beyond
 -- the representative set from 3C.0E.
 select 'CINV_DRAFT_STATUS_BAD','carrier_invoice','draft_or_ready_payment_status_not_unpaid','BLOCKER',(select count(*) from civ where j->>'issuance_status' in ('draft','ready_for_issue') and j->>'payment_status'<>'unpaid')::bigint,'Draft/ready invoice carries a non-unpaid payment_status.','Structural contradiction; stop.' union all
 select 'CINV_ISSUED_NO_ISSUED_AT','carrier_invoice','issued_missing_issued_at','BLOCKER',(select count(*) from civ where j->>'issuance_status' in ('issued','voided') and nullif(j->>'issued_at','') is null)::bigint,'Issued or voided invoice lacks issued_at.','Structural contradiction; stop.' union all
 select 'CINV_ISSUED_NO_ISSUED_BY','carrier_invoice','issued_missing_issued_by','BLOCKER',(select count(*) from civ where j->>'issuance_status' in ('issued','voided') and nullif(j->>'issued_by','') is null)::bigint,'Issued or voided invoice lacks issued_by. Not required by the installed CHECK (issued_by may become null later via ON DELETE SET NULL); flagged here as an audit-level completeness signal at issuance time.','Review; confirm this is a post-issuance profile deletion, not a bypassed issuance path.' union all
 select 'CINV_VOIDED_NO_VOIDED_AT','carrier_invoice','voided_missing_voided_at','BLOCKER',(select count(*) from civ where j->>'issuance_status'='voided' and nullif(j->>'voided_at','') is null)::bigint,'Voided invoice lacks voided_at.','Structural contradiction; stop.' union all
 select 'CINV_VOIDED_NO_VOIDED_BY','carrier_invoice','voided_missing_voided_by','BLOCKER',(select count(*) from civ where j->>'issuance_status'='voided' and nullif(j->>'voided_by','') is null)::bigint,'Voided invoice lacks voided_by. Not required by the installed CHECK; flagged as an audit-level completeness signal.','Review the void authorization path.' union all
 select 'CINV_NEGATIVE_PAID','carrier_invoice','amount_paid_negative','BLOCKER',(select count(*) from civ where coalesce((j->>'amount_paid')::numeric,0)<0)::bigint,'Invoice has negative amount_paid.','Structural contradiction; stop.' union all
 select 'CINV_RECIPIENT_SHAPE_BAD','carrier_invoice','recipient_shape_invalid','BLOCKER',(select count(*) from civ where (j->>'invoice_document_type'='carrier_freight_invoice' and not ((j->>'recipient_type'='broker' and nullif(j->>'recipient_broker_id','') is not null and nullif(j->>'recipient_customer_id','') is null) or (j->>'recipient_type'='customer' and nullif(j->>'recipient_customer_id','') is not null and nullif(j->>'recipient_broker_id','') is null))) or (j->>'invoice_document_type'='dispatch_service_invoice' and (nullif(j->>'recipient_type','') is not null or nullif(j->>'recipient_broker_id','') is not null or nullif(j->>'recipient_customer_id','') is not null)))::bigint,'Invoice document-type/recipient shape invalid (relational carrier_invoices row, never the snapshot).','Structural contradiction; stop.' union all
 select 'CINV_CURRENCY_BAD','carrier_invoice','currency_missing_or_invalid','BLOCKER',(select count(*) from civ where nullif(j->>'currency','') is null or j->>'currency' !~ '^[A-Z]{3}$')::bigint,'Invoice currency missing or malformed.','Structural contradiction; stop.' union all
 select 'CINV_BALANCE_BAD','carrier_invoice','balance_due_arithmetic_mismatch','BLOCKER',(select count(*) from civ where (j->>'balance_due')::numeric is distinct from (coalesce((j->>'total_amount')::numeric,0)-coalesce((j->>'amount_paid')::numeric,0)))::bigint,'balance_due does not equal total_amount minus amount_paid. balance_due is a GENERATED STORED column (0142) -- Postgres computes and enforces this identity structurally; this is defense-in-depth, not a reachable production state.','Structurally prevented by the generated column; investigate corruption tooling if ever nonzero.' union all
 select 'CINV_CROSS_ORG','carrier_invoice','cross_organization_invoice_source','BLOCKER',(select count(*) from civ i join public.carriers c on c.id=nullif(i.j->>'carrier_id','')::uuid where c.organization_id is distinct from nullif(i.j->>'organization_id','')::uuid)::bigint,'Invoice carrier belongs to a different organization than the invoice itself.','Structural contradiction; stop and repair tenant boundary.' union all
 select 'CINV_RECIPIENT_ORG_BAD','carrier_invoice','recipient_party_dangling_or_cross_organization','BLOCKER',(select count(*) from civ i where (nullif(i.j->>'recipient_broker_id','') is not null and not exists(select 1 from public.brokers b where b.id=(i.j->>'recipient_broker_id')::uuid and b.organization_id=nullif(i.j->>'organization_id','')::uuid)) or (nullif(i.j->>'recipient_customer_id','') is not null and not exists(select 1 from public.customers c2 where c2.id=(i.j->>'recipient_customer_id')::uuid and c2.organization_id=nullif(i.j->>'organization_id','')::uuid)))::bigint,'Invoice recipient_broker_id/recipient_customer_id does not resolve to a same-organization broker/customer (dangling reference, e.g. a carrier ID stored in this field, or a cross-organization party).','Structural contradiction; stop and repair the recipient reference.' union all
 -- Phase 3C.0E.1: snapshot supplementary checks (mission Section C),
 -- deliberately NOT part of the carrier_invoice_payment_snapshot_problem
 -- equivalence proof above -- the installed function does not check
 -- invoice_number/issued_at/issued_by/dispatch_service/source_loads
 -- shape, so claiming equivalence for these would misrepresent that
 -- function's actual documented scope. Snapshot content never selected.
 select 'CINV_SNAP_FORBIDDEN_KEY','carrier_invoice','snapshot_forbidden_key_present','BLOCKER',(select count(*) from civs_problem where (j->>'has_forbidden_key')::boolean)::bigint,'Issuance snapshot contains a credential-shaped key at some depth (top-level, nested object, or nested array). Content never selected; structurally blocked by civs_no_forbidden_keys (0142) for any normal insert.','Stop; this indicates the immutable-snapshot CHECK was bypassed.' union all
 select 'CINV_SNAP_NUMBER_MISMATCH','carrier_invoice','snapshot_invoice_number_mismatch','BLOCKER',(select count(*) from civs_problem where (j->>'number_mismatch')::boolean)::bigint,'Snapshot invoice_number differs from the relational invoice_number.','Structural contradiction; stop.' union all
 select 'CINV_SNAP_ISSUED_AT_MISMATCH','carrier_invoice','snapshot_issued_at_mismatch','BLOCKER',(select count(*) from civs_problem where (j->>'issued_at_mismatch')::boolean)::bigint,'Snapshot issued_at differs from the relational issued_at.','Structural contradiction; stop.' union all
 select 'CINV_SNAP_ISSUED_BY_MISMATCH','carrier_invoice','snapshot_issued_by_mismatch','BLOCKER',(select count(*) from civs_problem where (j->>'issued_by_mismatch')::boolean)::bigint,'Snapshot issued_by differs from the relational issued_by.','Structural contradiction; stop.' union all
 select 'CINV_SNAP_DISPATCH_SHAPE_BAD','carrier_invoice','snapshot_dispatch_service_shape_invalid','BLOCKER',(select count(*) from civs_problem where (j->>'dispatch_service_should_be_null_bad')::boolean or (j->>'dispatch_service_missing_bad')::boolean)::bigint,'A carrier_freight_invoice snapshot has a non-null dispatch_service object, or a dispatch_service_invoice snapshot is missing its required dispatch_service object.','Structural contradiction; stop.' union all
 select 'CINV_SNAP_DISPATCH_ISSUER_ORG_BAD','carrier_invoice','snapshot_dispatch_issuer_organization_mismatch','BLOCKER',(select count(*) from civs_problem where (j->>'dispatch_issuer_org_mismatch')::boolean)::bigint,'A dispatch_service_invoice snapshot issuer.organization_id differs from the invoice''s own organization_id -- the dispatch organization, not the carrier, must be the issuer of record.','Structural contradiction; stop.' union all
 select 'CINV_SNAP_LOADS_SHAPE','carrier_invoice','snapshot_source_loads_shape_invalid','BLOCKER',(select count(*) from civs_problem where (j->>'loads_shape_bad')::boolean)::bigint,'Snapshot source_loads is not a JSON array. Shape only -- reconciling snapshot source_loads/line_items against the relational carrier_invoice_loads/carrier_invoice_line_items tables is out of this phase''s explicit scope.','Review; full source-load reconciliation is deferred to a future phase.' union all
 select 'CINV_SNAP_LINE_ITEMS_SHAPE','carrier_invoice','snapshot_line_items_shape_invalid','BLOCKER',(select count(*) from civs_problem where (j->>'line_items_shape_bad')::boolean)::bigint,'Snapshot line_items is not a JSON array. Shape only -- full reconciliation against carrier_invoice_line_items is out of this phase''s explicit scope.','Review; full line-item reconciliation is deferred to a future phase.' union all
 select 'CINV_SNAP_ROUTE_SHAPE_BAD','carrier_invoice','snapshot_route_origin_destination_shape_invalid','BLOCKER',(select count(*) from civs_problem where (j->>'route_shape_bad')::boolean)::bigint,'A freight snapshot''s source_loads element lacks an origin or destination object. Shape only -- no facility name, city, state, or address is ever read by this check.','Structural contradiction; stop.' union all
 -- Phase 3C.0E.1 Section E: the immutability trigger and the absence of
 -- any client write grant are the two structural halves of "no role,
 -- including service_role, can bypass immutability" (0142's own header).
 select 'CINV_SNAP_TRIGGER_MISSING','carrier_invoice','snapshot_immutability_trigger_missing','BLOCKER',(select case when to_regclass('public.carrier_invoice_issuance_snapshots') is null then 0 else (not exists(select 1 from pg_trigger t where t.tgrelid=to_regclass('public.carrier_invoice_issuance_snapshots') and t.tgname='a0142_guard_snapshot_immutable' and not t.tgisinternal))::int end)::bigint,'The a0142_guard_snapshot_immutable BEFORE UPDATE OR DELETE trigger is missing from carrier_invoice_issuance_snapshots.','Stop; immutability is no longer structurally enforced for any role, including service_role.' union all
 select 'CINV_SNAP_GRANTS_BAD','carrier_invoice','snapshot_unexpected_client_write_grant','BLOCKER',(select case when to_regclass('public.carrier_invoice_issuance_snapshots') is null then 0 else (has_table_privilege('authenticated','public.carrier_invoice_issuance_snapshots','INSERT') or has_table_privilege('authenticated','public.carrier_invoice_issuance_snapshots','UPDATE') or has_table_privilege('authenticated','public.carrier_invoice_issuance_snapshots','DELETE') or has_table_privilege('anon','public.carrier_invoice_issuance_snapshots','INSERT') or has_table_privilege('anon','public.carrier_invoice_issuance_snapshots','UPDATE') or has_table_privilege('anon','public.carrier_invoice_issuance_snapshots','DELETE') or has_table_privilege('service_role','public.carrier_invoice_issuance_snapshots','INSERT') or has_table_privilege('service_role','public.carrier_invoice_issuance_snapshots','UPDATE') or has_table_privilege('service_role','public.carrier_invoice_issuance_snapshots','DELETE'))::int end)::bigint,'A client-facing role (authenticated/anon/service_role) has direct INSERT/UPDATE/DELETE on carrier_invoice_issuance_snapshots.','Stop; revoke the unexpected grant. No role should be able to insert/update/delete this table directly -- only a SECURITY DEFINER issuance RPC may.' union all
 -- ======================= Phase 3C.0E.2 ===================================
 -- Numbering (Section B/C): format {prefix}-{year}-{5-digit-sequence}
 -- (0142/0144); freight scoped per carrier, dispatch-service per
 -- organization; counter table keyed (document_type, issuer_id, year).
 -- Never outputs an actual invoice number.
 select 'CINV_NUMBER_FORMAT_BAD','carrier_invoice','invoice_number_format_invalid','BLOCKER',(select count(*) from civ_numbering where not format_ok)::bigint,'Invoice number does not match {prefix}-{year}-{5-digit-sequence}. Value never selected.','Structural contradiction; stop.' union all
 select 'CINV_NUMBER_YEAR_MISMATCH','carrier_invoice','invoice_number_year_disagrees_with_issued_at','BLOCKER',(select count(*) from civ_numbering where format_ok and num_year is distinct from to_char(issued_at_text::timestamptz,'YYYY'))::bigint,'The year embedded in the invoice number disagrees with issued_at.','Structural contradiction; stop.' union all
 select 'CINV_DRAFT_HAS_NUMBER','carrier_invoice','draft_or_ready_holds_final_number','BLOCKER',(select count(*) from civ where j->>'issuance_status' in ('draft','ready_for_issue') and nullif(j->>'invoice_number','') is not null)::bigint,'Draft or ready-for-issue invoice already carries a final invoice number.','Structural contradiction; stop.' union all
 select 'CINV_NUMBER_DUP_SCOPE','carrier_invoice','duplicate_number_within_issuer_scope','BLOCKER',(select count(*) from (select issuer_id,doctype,j->>'invoice_number' num from civ_numbering n join civ on civ.j->>'id'=n.invoice_id group by issuer_id,doctype,j->>'invoice_number' having count(*)>1) q)::bigint,'Duplicate invoice number within its own issuer scope (carrier for freight, organization for dispatch-service).','Structural contradiction; stop.' union all
 select 'CINV_NUMBER_COUNTER_MISSING','carrier_invoice','issued_number_without_matching_counter','BLOCKER',(select count(*) from civ_numbering n where not exists(select 1 from civnc c where c.j->>'invoice_document_type'=n.doctype and c.j->>'issuer_id'=n.issuer_id and c.j->>'year'=n.num_year))::bigint,'An issued invoice number exists with no matching (document_type, issuer, year) counter row.','Structural contradiction; stop.' union all
 select 'CINV_NUMBER_COUNTER_BEHIND','carrier_invoice','counter_behind_max_issued_sequence','BLOCKER',(select count(*) from (select c.j->>'invoice_document_type' dt,c.j->>'issuer_id' iid,c.j->>'year' yr,(c.j->>'last_number')::int last_number, max(n.num_seq) max_seq from civnc c left join civ_numbering n on n.doctype=c.j->>'invoice_document_type' and n.issuer_id=c.j->>'issuer_id' and n.num_year=c.j->>'year' group by c.j->>'invoice_document_type',c.j->>'issuer_id',c.j->>'year',c.j->>'last_number') q where max_seq is not null and max_seq>last_number)::bigint,'The private counter is behind the highest sequence number actually issued for its own (document_type, issuer, year) -- a future allocation could collide.','Stop; investigate a bypassed counter write.' union all
 select 'CINV_NUMBER_COUNTER_ORPHAN','carrier_invoice','counter_issuer_does_not_resolve','WARNING',(select count(*) from civnc c where (c.j->>'invoice_document_type'='carrier_freight_invoice' and not exists(select 1 from public.carriers x where x.id=nullif(c.j->>'issuer_id','')::uuid)) or (c.j->>'invoice_document_type'='dispatch_service_invoice' and not exists(select 1 from public.organizations x where x.id=nullif(c.j->>'issuer_id','')::uuid)))::bigint,'A number-counter row''s issuer_id does not resolve to any carrier/organization. The counter mechanism has no FK by design (0142); a dangling issuer is a hygiene warning, not itself proof of a wrong allocation.','Review; confirm the referenced carrier/organization was not deleted while invoices exist.' union all
 select 'CINV_NUMBER_PREFIX_MISMATCH','carrier_invoice','invoice_number_prefix_disagrees_with_configured_source','BLOCKER',(select count(*) from civ_numbering n join civ i on i.j->>'id'=n.invoice_id left join public.carriers c on c.id=nullif(n.carrier_id,'')::uuid left join public.platform_settings p on true where n.format_ok and regexp_replace(i.j->>'invoice_number','-[0-9]{4}-[0-9]{5}$','') is distinct from (case when n.doctype='carrier_freight_invoice' then to_jsonb(c)->>'invoice_code' else coalesce(to_jsonb(p)->>'dispatch_invoice_prefix','DISP') end))::bigint,'The invoice number''s prefix does not match the carrier''s own invoice_code (freight) or the configured dispatch_invoice_prefix (dispatch-service).','Structural contradiction; stop.' union all
 -- Line items (Section D): totals recalculated from carrier_invoice_line_items
 -- only (0142's own recalculate_carrier_invoice_totals() trigger); line_type
 -- must match the parent invoice's document type (0144's guard trigger).
 select 'CIVIL_TOTAL','carrier_invoice','line_item_total','INFO',(select count(*) from civil)::bigint,'Carrier-invoice line-item row count; no descriptions or amounts selected.','Review inventory.' union all
 select 'CIVIL_ISSUED_NO_LINES','carrier_invoice','issued_invoice_without_line_items','BLOCKER',(select count(*) from civ i where i.j->>'issuance_status' in ('issued','voided') and not exists(select 1 from civil li where li.j->>'invoice_id'=i.j->>'id'))::bigint,'Issued or voided invoice has no line items.','Structural contradiction; stop.' union all
 select 'CIVIL_SUBTOTAL_MISMATCH','carrier_invoice','invoice_subtotal_disagrees_with_line_sum','BLOCKER',(select count(*) from civ i where coalesce((select sum((li.j->>'line_total')::numeric) from civil li where li.j->>'invoice_id'=i.j->>'id'),0) is distinct from coalesce((i.j->>'subtotal_amount')::numeric,0))::bigint,'Invoice subtotal_amount disagrees with the sum of its line items'' line_total.','Structural contradiction; stop.' union all
 select 'CIVIL_TOTAL_FORMULA_MISMATCH','carrier_invoice','invoice_total_formula_mismatch','BLOCKER',(select count(*) from civ where (j->>'total_amount')::numeric is distinct from (coalesce((j->>'subtotal_amount')::numeric,0)+coalesce((j->>'tax_amount')::numeric,0)+coalesce((j->>'adjustments_amount')::numeric,0)))::bigint,'Invoice total_amount does not equal subtotal + tax + adjustments.','Structural contradiction; stop.' union all
 select 'CIVIL_WRONG_LINE_TYPE','carrier_invoice','line_item_type_disagrees_with_document_type','BLOCKER',(select count(*) from civil li join civ i on i.j->>'id'=li.j->>'invoice_id' where (i.j->>'invoice_document_type'='carrier_freight_invoice' and li.j->>'line_type'<>'freight_charge') or (i.j->>'invoice_document_type'='dispatch_service_invoice' and li.j->>'line_type'<>'dispatch_service_fee'))::bigint,'Line-item line_type disagrees with its invoice''s document type.','Structural contradiction; stop.' union all
 select 'CIVIL_WRONG_ORG','carrier_invoice','line_item_organization_disagrees_with_invoice','BLOCKER',(select count(*) from civil li join civ i on i.j->>'id'=li.j->>'invoice_id' where li.j->>'organization_id' is distinct from i.j->>'organization_id')::bigint,'Line item organization_id disagrees with its invoice''s organization.','Structural contradiction; stop.' union all
 -- Source loads (Section E): carrier_invoice_loads is the anti-double-billing
 -- join for freight invoices; a load''s own carrier (when resolved) must
 -- match the freight invoice''s carrier (0142's guard trigger).
 select 'CIVL_TOTAL','carrier_invoice','invoice_load_link_total','INFO',(select count(*) from civl)::bigint,'Carrier-invoice/load link row count.','Review inventory.' union all
 select 'CIVL_MISSING_FOR_ISSUED','carrier_invoice','issued_freight_invoice_missing_source_load','BLOCKER',(select count(*) from civ i where i.j->>'invoice_document_type'='carrier_freight_invoice' and i.j->>'issuance_status' in ('issued','voided') and not exists(select 1 from civl l where l.j->>'invoice_id'=i.j->>'id'))::bigint,'Issued or voided freight invoice has no linked source load.','Structural contradiction; stop.' union all
 select 'CIVL_ORG_BAD','carrier_invoice','invoice_load_link_wrong_organization','BLOCKER',(select count(*) from civl l join civ i on i.j->>'id'=l.j->>'invoice_id' where l.j->>'organization_id' is distinct from i.j->>'organization_id')::bigint,'Invoice/load link organization disagrees with its invoice.','Structural contradiction; stop.' union all
 select 'CIVL_CARRIER_BAD','carrier_invoice','source_load_wrong_carrier','BLOCKER',(select count(*) from civl l join civ i on i.j->>'id'=l.j->>'invoice_id' join public.loads ld on ld.id=nullif(l.j->>'load_id','')::uuid where i.j->>'invoice_document_type'='carrier_freight_invoice' and nullif(to_jsonb(ld)->>'carrier_id','') is not null and to_jsonb(ld)->>'carrier_id' is distinct from i.j->>'carrier_id')::bigint,'A freight invoice''s source load belongs to a different carrier.','Structural contradiction; stop.' union all
 select 'CIVL_DUP_ACROSS_FREIGHT_INVOICES','carrier_invoice','source_load_billed_on_two_freight_invoices','BLOCKER',(select count(*) from (select l.j->>'load_id' lid from civl l join civ i on i.j->>'id'=l.j->>'invoice_id' where i.j->>'invoice_document_type'='carrier_freight_invoice' group by l.j->>'load_id' having count(distinct l.j->>'invoice_id')>1) q)::bigint,'A single load is attached to more than one carrier freight invoice.','Structural contradiction; stop and resolve which invoice legally covers this load.' union all
 -- Agreement/version (Section G): a version''s carrier/organization must
 -- match its own agreement container; overlapping approved versions for
 -- the same carrier are prevented by cdsav_no_overlap_when_approved (0145),
 -- a real GiST exclusion constraint -- reimplemented here as defense-in-depth.
 select 'CDSAV_AGREEMENT_MISMATCH','carrier_invoice','version_agreement_carrier_or_org_mismatch','BLOCKER',(select count(*) from cdsav v join cdsa a on a.j->>'id'=v.j->>'agreement_id' where v.j->>'carrier_id' is distinct from a.j->>'carrier_id' or v.j->>'organization_id' is distinct from a.j->>'organization_id')::bigint,'Agreement version carrier/organization disagrees with its own agreement container.','Structural contradiction; stop.' union all
 select 'CDSAV_OVERLAP_BAD','carrier_invoice','overlapping_approved_versions_same_carrier','BLOCKER',(select count(*) from cdsav a join cdsav b on a.j->>'carrier_id'=b.j->>'carrier_id' and a.j->>'id'<b.j->>'id' where a.j->>'status'='approved' and b.j->>'status'='approved' and daterange((a.j->>'effective_from')::date,coalesce((a.j->>'effective_to')::date,'infinity'::date),'[]') && daterange((b.j->>'effective_from')::date,coalesce((b.j->>'effective_to')::date,'infinity'::date),'[]'))::bigint,'Two approved agreement versions for the same carrier have overlapping effective date ranges.','Structural contradiction; stop -- cdsav_no_overlap_when_approved (0145) should make this impossible.' union all
 -- Fee calculation (Section H): recompute from the immutable dispatch_service
 -- billing-ledger row itself (authoritative_freight_amount/fee_method/rate
 -- are already the LOCKED values 0145/0146 used at issuance -- never a
 -- mutable load or agreement-version re-read), clamped by min/max exactly
 -- as the installed calculation does.
 select 'CDSBL_PERCENTAGE_FEE_MISMATCH','carrier_invoice','percentage_fee_recalculation_mismatch','BLOCKER',(select count(*) from cdsbl b join cdsav v on v.j->>'id'=b.j->>'agreement_version_id',
   lateral (select (b.j->>'authoritative_freight_amount')::numeric*(v.j->>'percentage_rate')::numeric/100.0 as raw) r,
   lateral (select greatest(r.raw, coalesce((v.j->>'minimum_fee')::numeric,0)) as min_clamped) mc,
   lateral (select case when (v.j->>'maximum_fee') is not null then least(mc.min_clamped,(v.j->>'maximum_fee')::numeric) else mc.min_clamped end as final_fee) fc
  where b.j->>'fee_method'='percentage_of_freight' and round(fc.final_fee,2) is distinct from (b.j->>'calculated_fee')::numeric)::bigint,'Percentage-method billing line calculated_fee disagrees with authoritative_freight_amount * percentage_rate (min/max clamped).','Structural contradiction; stop.' union all
 select 'CDSBL_FLAT_FEE_MISMATCH','carrier_invoice','flat_fee_recalculation_mismatch','BLOCKER',(select count(*) from cdsbl b join cdsav v on v.j->>'id'=b.j->>'agreement_version_id',
   lateral (select greatest((v.j->>'flat_fee_per_load')::numeric, coalesce((v.j->>'minimum_fee')::numeric,0)) as min_clamped) mc,
   lateral (select case when (v.j->>'maximum_fee') is not null then least(mc.min_clamped,(v.j->>'maximum_fee')::numeric) else mc.min_clamped end as final_fee) fc
  where b.j->>'fee_method'='flat_per_load' and round(fc.final_fee,2) is distinct from (b.j->>'calculated_fee')::numeric)::bigint,'Flat-method billing line calculated_fee disagrees with flat_fee_per_load (min/max clamped).','Structural contradiction; stop.' union all
 select 'CDSBL_CURRENCY_MISMATCH','carrier_invoice','billing_line_currency_disagrees_with_version','BLOCKER',(select count(*) from cdsbl b join cdsav v on v.j->>'id'=b.j->>'agreement_version_id' where b.j->>'currency' is distinct from v.j->>'currency')::bigint,'Billing line currency disagrees with its agreement version currency.','Structural contradiction; stop.' union all
 -- Billing ledger (Section I): organization/carrier identity defense in
 -- depth beyond the FK/trigger layer; unique(load_id) already makes
 -- cross-version/cross-agreement duplicate billing of the SAME load
 -- structurally impossible (CDSBL_DUP_LOAD, Phase 3C.0E, already covers
 -- every duplicate-billing angle since the index has no version/agreement
 -- scope at all).
 select 'CDSBL_ORG_MISMATCH','carrier_invoice','billing_line_wrong_organization','BLOCKER',(select count(*) from cdsbl b join civ i on i.j->>'id'=b.j->>'invoice_id' where b.j->>'organization_id' is distinct from i.j->>'organization_id')::bigint,'Billing line organization disagrees with its dispatch-service invoice.','Structural contradiction; stop.' union all
 select 'CDSBL_CARRIER_MISMATCH','carrier_invoice','billing_line_wrong_carrier','BLOCKER',(select count(*) from cdsbl b join civ i on i.j->>'id'=b.j->>'invoice_id' where b.j->>'carrier_id' is distinct from i.j->>'carrier_id')::bigint,'Billing line carrier disagrees with its dispatch-service invoice carrier.','Structural contradiction; stop.' union all
 select 'CDSBL_VERSION_AGREEMENT_MISMATCH','carrier_invoice','billing_line_version_agreement_mismatch','BLOCKER',(select count(*) from cdsbl b join cdsav v on v.j->>'id'=b.j->>'agreement_version_id' where v.j->>'carrier_id' is distinct from b.j->>'carrier_id')::bigint,'Billing line agreement version belongs to a different carrier than the billing line itself.','Structural contradiction; stop.' union all
 -- ======================= Phase 3C.0E.3 Section H/I =========================
 -- Financial-object RLS/grants and internal-function EXECUTE privileges,
 -- scoped strictly to the objects introduced by 0142-0146 (general
 -- platform-wide security remains for a later phase). Every check below
 -- guards table/function existence via to_regclass/to_regprocedure so it
 -- stays valid at every pre-0142/0144/0145/0146 boundary.
 select 'FIN_RLS_MISSING','carrier_invoice','financial_table_missing_rls','BLOCKER',(select count(*) from (values
   ('carrier_invoices'),('carrier_invoice_line_items'),('carrier_invoice_loads'),('carrier_invoice_issuance_snapshots'),
   ('carrier_invoice_number_counters'),('carrier_invoice_lifecycle_idempotency'),('carrier_invoice_payments'),
   ('carrier_dispatch_service_agreements'),('carrier_dispatch_service_agreement_versions'),('carrier_dispatch_service_billing_lines'),
   ('carrier_dispatch_service_agreement_idempotency')
 ) t(tbl) where to_regclass('public.'||t.tbl) is not null and not exists(select 1 from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relname=t.tbl and c.relrowsecurity))::bigint,'A financial object (0142-0146) exists without row level security enabled.','Stop; enable RLS via the owning migration.' union all
 select 'FIN_GRANTS_ANON','carrier_invoice','financial_table_anon_grant','BLOCKER',(select count(*) from (values
   ('carrier_invoices'),('carrier_invoice_line_items'),('carrier_invoice_loads'),('carrier_invoice_issuance_snapshots'),
   ('carrier_invoice_number_counters'),('carrier_invoice_lifecycle_idempotency'),('carrier_invoice_payments'),
   ('carrier_dispatch_service_agreements'),('carrier_dispatch_service_agreement_versions'),('carrier_dispatch_service_billing_lines'),
   ('carrier_dispatch_service_agreement_idempotency')
 ) t(tbl) where to_regclass('public.'||t.tbl) is not null and (has_table_privilege('anon','public.'||t.tbl,'SELECT') or has_table_privilege('anon','public.'||t.tbl,'INSERT') or has_table_privilege('anon','public.'||t.tbl,'UPDATE') or has_table_privilege('anon','public.'||t.tbl,'DELETE')))::bigint,'A financial object grants anon any table privilege at all.','Stop; revoke. Anonymous must have zero access to any financial object.' union all
 select 'FIN_GRANTS_AUTH_WRITE','carrier_invoice','financial_table_authenticated_direct_write','BLOCKER',(select count(*) from (values
   ('carrier_invoices'),('carrier_invoice_line_items'),('carrier_invoice_loads'),('carrier_invoice_issuance_snapshots'),
   ('carrier_invoice_number_counters'),('carrier_invoice_lifecycle_idempotency'),('carrier_invoice_payments'),
   ('carrier_dispatch_service_agreements'),('carrier_dispatch_service_agreement_versions'),('carrier_dispatch_service_billing_lines'),
   ('carrier_dispatch_service_agreement_idempotency')
 ) t(tbl) where to_regclass('public.'||t.tbl) is not null and t.tbl not in ('carrier_invoice_line_items','carrier_invoice_loads') and (has_table_privilege('authenticated','public.'||t.tbl,'INSERT') or has_table_privilege('authenticated','public.'||t.tbl,'UPDATE') or has_table_privilege('authenticated','public.'||t.tbl,'DELETE')))::bigint,'A financial object grants authenticated a direct INSERT/UPDATE/DELETE outside the documented exceptions (carrier_invoice_line_items/carrier_invoice_loads, which are dispatcher/accountant-writable pre-issuance by design, 0142).','Stop; revoke and route through the owning guarded RPC.' union all
 -- Phase 3C.0 final review (Section D): FIN_GRANTS_AUTH_WRITE above
 -- deliberately counts TABLES (any of INSERT/UPDATE/DELETE), which is
 -- sufficient to detect the gap but insufficient to prove each of the two
 -- distinct carrier_invoices privileges independently, as the corrective-
 -- migration backlog requires (0147 needs its own postcondition per
 -- privilege, not one combined, unverifiable correction). These two
 -- findings isolate carrier_invoices' own INSERT and DELETE grants as
 -- separately countable, separately named BLOCKERs.
 select 'FIN_CARRIER_INVOICES_AUTH_INSERT','carrier_invoice','carrier_invoices_authenticated_direct_insert','BLOCKER',(select case when to_regclass('public.carrier_invoices') is null then 0 else has_table_privilege('authenticated','public.carrier_invoices','INSERT')::int end)::bigint,'carrier_invoices grants authenticated a direct INSERT -- an owner/admin/accountant (and a dispatcher, while issuance_status=draft) can forge an invoice row (any issuance_status, any invoice_number, no snapshot) entirely outside issue_carrier_invoice().','Stop; revoke insert on public.carrier_invoices from authenticated. This is release BLOCKER #2, distinct from BLOCKER #3 (DELETE).' union all
 select 'FIN_CARRIER_INVOICES_AUTH_DELETE','carrier_invoice','carrier_invoices_authenticated_direct_delete','BLOCKER',(select case when to_regclass('public.carrier_invoices') is null then 0 else has_table_privilege('authenticated','public.carrier_invoices','DELETE')::int end)::bigint,'carrier_invoices grants authenticated a direct DELETE. Confirmed exact live scope (Phase 3C.0 final review): a0142''s own guard_carrier_invoice_delete() trigger rejects deleting an ISSUED or VOIDED invoice ("void it instead") -- only a DRAFT or READY_FOR_ISSUE invoice can actually be removed this way. An owner/admin/accountant can still destroy real, unissued work-in-progress with no audit trail and no confirmation step; the table-level grant remains unconditional and unrevoked regardless of the trigger''s own narrower protection.','Stop; revoke delete on public.carrier_invoices from authenticated. This is release BLOCKER #3, distinct from BLOCKER #2 (INSERT) -- write 0147''s postcondition against the real draft/ready_for_issue-only exploit window, not against issued invoices (which are already trigger-protected).' union all
 select 'FIN_FUNC_ANON_EXECUTE','carrier_invoice','financial_function_anon_or_public_execute','BLOCKER',(select count(*) filter(where bad) from (values
   ('public.issue_carrier_invoice(uuid,timestamptz,text,text)'),
   ('public.record_carrier_invoice_payment(uuid,numeric,date,text,text,timestamptz,text,text)'),
   ('public.void_carrier_invoice_payment(uuid,timestamptz,text,text)'),
   ('public.update_carrier_invoice_draft(uuid,jsonb,timestamptz,text,text)')
 ) t(sig), lateral (select to_regprocedure(t.sig) is not null and has_function_privilege('anon',to_regprocedure(t.sig),'EXECUTE') as bad) x)::bigint,'A client-facing carrier-invoice RPC is executable by anon (or PUBLIC, which anon would inherit).','Stop; revoke. Only authenticated may call these RPCs.' union all
 select 'FIN_FUNC_INTERNAL_CLIENT_EXECUTE','carrier_invoice','financial_internal_helper_client_executable','BLOCKER',(select count(*) filter(where bad) from (values
   ('public._generate_carrier_invoice_number_internal(public.invoice_document_type,uuid,text)'),
   ('public._generate_carrier_invoice_payment_number_internal()'),
   ('public.carrier_invoice_payment_snapshot_problem(uuid)'),
   ('public._carrier_invoice_payment_external_reference_problem(text)'),
   ('public.compute_financial_request_fingerprint(jsonb)'),
   ('public._issue_dispatch_service_invoice_internal(uuid,public.carrier_invoices,uuid,uuid,text,text,text,integer,text)')
 ) t(sig), lateral (select to_regprocedure(t.sig) is not null and (has_function_privilege('authenticated',to_regprocedure(t.sig),'EXECUTE') or has_function_privilege('anon',to_regprocedure(t.sig),'EXECUTE')) as bad) x)::bigint,'An internal, mechanism-only financial helper (numbering/snapshot-validation/fingerprint/dispatch-service-issuance) is directly executable by authenticated or anon. These are reachable only from a trusted SECURITY DEFINER caller that has already verified authorization. (jsonb_contains_forbidden_key is a pure, argument-only jsonb utility with no table access and is deliberately excluded from this check -- its exposure carries no security consequence.)','Stop; revoke direct EXECUTE. Internal helpers are never called directly by a client role.' union all
 -- Manifest rows 103/104: financial-object-scoped lifecycle-guard-trigger
 -- and uniqueness/backstop-constraint existence (defense-in-depth
 -- structural presence, complementing the corruption fixtures elsewhere
 -- in this file that each require bypassing one of these exact objects).
 select 'FIN_GUARD_TRIGGER_MISSING','carrier_invoice','financial_lifecycle_guard_trigger_missing','WARNING',(select count(*) filter(where missing) from (values
   ('carrier_invoice_line_items','a0142_guard_line_item_mutability'),('carrier_invoice_loads','a0142_guard_load_mutability'),
   ('carrier_invoice_loads','a0142_guard_load_consistency'),('carrier_invoices','a0142_guard_org_consistency'),
   ('carrier_invoice_payments','a0146_guard_payment_lifecycle'),('carrier_invoice_payments','a0146_guard_payment_currency'),
   ('carrier_dispatch_service_agreement_versions','a0145_guard_agreement_version_lifecycle')
 ) t(tbl,trg), lateral (select to_regclass('public.'||t.tbl) is not null and not exists(select 1 from pg_trigger tg where tg.tgrelid=to_regclass('public.'||t.tbl) and tg.tgname=t.trg and not tg.tgisinternal) as missing) x)::bigint,'A documented lifecycle/consistency guard trigger is missing from a financial object.','Stop; restore via the owning migration.' union all
 select 'FIN_BACKSTOP_CONSTRAINT_MISSING','carrier_invoice','financial_backstop_constraint_missing','WARNING',(select count(*) filter(where missing) from (values
   ('carrier_invoice_issuance_snapshots','carrier_invoice_issuance_snapshots_invoice_id_key'),
   ('carrier_invoice_loads','civl_invoice_load_uq'),
   ('carrier_dispatch_service_billing_lines','carrier_dispatch_service_billing_lines_load_id_key'),
   ('carrier_invoice_payments','civp_payer_shape'),('carrier_invoice_payments','civp_void_fields_iff_voided'),
   ('carrier_invoices','cinv_freight_number_unique'),('carrier_invoices','cinv_dispatch_number_unique'),
   ('carrier_invoice_lifecycle_idempotency','civ_idempotency_unique')
 ) t(tbl,con), lateral (select to_regclass('public.'||t.tbl) is not null and not exists(select 1 from pg_constraint c where c.conrelid=to_regclass('public.'||t.tbl) and c.conname=t.con) and not exists(select 1 from pg_class ix join pg_index i on i.indexrelid=ix.oid where ix.relname=t.con and i.indrelid=to_regclass('public.'||t.tbl)) as missing) x)::bigint,'A documented uniqueness/backstop constraint or index is missing from a financial object.','Stop; restore via the owning migration.' union all
 -- ======================= Phase 3C.0F.1 =====================================
 -- Platform-wide table/column privileges, RLS enablement, and default
 -- privileges for every object INTRODUCED by migrations 0130-0146 (26
 -- tables total: the 11 financial objects already covered by FIN_* above,
 -- plus 15 non-financial objects from 0130/0131/0132/0133/0134/0135/0137/
 -- 0139/0141/0145). Function EXECUTE/search_path/security-definer auditing
 -- beyond the already-known draft-RPC gap remains out of scope for Phase
 -- 3C.0F.2. Every check guards existence via to_regclass so it stays valid
 -- at every pre-0130 boundary fixture.
 select 'PLAT_RLS_MISSING','platform','platform_table_missing_rls','BLOCKER',(select count(*) from (values
   ('carrier_remittance_profiles'),('unresolved_carrier_records'),('financial_idempotency_keys'),
   ('carrier_brokers'),('carrier_customers'),('trailer_ownership_scope_audit'),
   ('carrier_backfill_0133_provenance'),('dispatch_status_transitions'),('dispatch_resource_reassignments'),
   ('carrier_backfill_0137_provenance'),('carrier_factoring_integrations'),('factoring_policy_idempotency'),
   ('factoring_integration_lifecycle_idempotency'),('carrier_dispatch_service_agreement_idempotency'),
   ('carrier_dispatch_service_agreements'),('carrier_dispatch_service_agreement_versions'),
   ('carrier_dispatch_service_billing_lines'),('carrier_invoice_payments'),
   ('carrier_invoices'),('carrier_invoice_line_items'),('carrier_invoice_loads'),
   ('carrier_invoice_number_counters'),('carrier_invoice_lifecycle_idempotency'),
   ('carrier_invoice_issuance_snapshots'),('legacy_invoice_carrier_migration_review'),
   ('legacy_invoice_review_idempotency')
 ) t(tbl) where to_regclass('public.'||t.tbl) is not null and not exists(select 1 from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relname=t.tbl and c.relrowsecurity))::bigint,'A table introduced by migrations 0130-0146 exists without row level security enabled.','Stop; enable RLS via the owning migration.' union all
 select 'PLAT_GRANTS_ANON','platform','platform_table_anon_grant','BLOCKER',(select count(*) from (values
   ('carrier_remittance_profiles'),('unresolved_carrier_records'),('financial_idempotency_keys'),
   ('carrier_brokers'),('carrier_customers'),('trailer_ownership_scope_audit'),
   ('carrier_backfill_0133_provenance'),('dispatch_status_transitions'),('dispatch_resource_reassignments'),
   ('carrier_backfill_0137_provenance'),('carrier_factoring_integrations'),('factoring_policy_idempotency'),
   ('factoring_integration_lifecycle_idempotency'),('carrier_dispatch_service_agreement_idempotency'),
   ('carrier_dispatch_service_agreements'),('carrier_dispatch_service_agreement_versions'),
   ('carrier_dispatch_service_billing_lines'),('carrier_invoice_payments'),
   ('carrier_invoices'),('carrier_invoice_line_items'),('carrier_invoice_loads'),
   ('carrier_invoice_number_counters'),('carrier_invoice_lifecycle_idempotency'),
   ('carrier_invoice_issuance_snapshots'),('legacy_invoice_carrier_migration_review'),
   ('legacy_invoice_review_idempotency')
 ) t(tbl) where to_regclass('public.'||t.tbl) is not null and (has_table_privilege('anon','public.'||t.tbl,'SELECT') or has_table_privilege('anon','public.'||t.tbl,'INSERT') or has_table_privilege('anon','public.'||t.tbl,'UPDATE') or has_table_privilege('anon','public.'||t.tbl,'DELETE')))::bigint,'A table introduced by 0130-0146 grants anon any table privilege at all.','Stop; revoke. This product has no unauthenticated read/write surface (0010).' union all
 -- Reviewed allowlist of every (table, write-op) pair authenticated is
 -- currently, deliberately granted on a 0130-0146 object -- carrier_invoices
 -- INSERT/DELETE is the already-recorded FIN_GRANTS_AUTH_WRITE BLOCKER
 -- (tracked there, not re-counted here); line_items/loads are trigger-
 -- guarded (a0142_guard_line_item_mutability/a0142_guard_load_mutability);
 -- carrier_brokers/carrier_customers/carrier_remittance_profiles/
 -- unresolved_carrier_records are RLS-policy-guarded per their owning
 -- migration. carrier_invoice_loads UPDATE is a harmless dead grant --
 -- 0142 never creates a carrier_invoice_loads_update policy (only
 -- select/insert/delete), so RLS structurally denies every row to
 -- authenticated regardless of the table-level grant (confirmed
 -- behaviorally: a same-org owner's UPDATE affects 0 rows). Anything
 -- outside this allowlist is a new, unreviewed grant.
 select 'PLAT_WRITE_GRANT_UNDOCUMENTED','platform','platform_table_write_grant_undocumented','BLOCKER',(select count(*) from (
   select t.tbl, op.op from (values
     ('carrier_remittance_profiles'),('unresolved_carrier_records'),('financial_idempotency_keys'),
     ('carrier_brokers'),('carrier_customers'),('trailer_ownership_scope_audit'),
     ('carrier_backfill_0133_provenance'),('dispatch_status_transitions'),('dispatch_resource_reassignments'),
     ('carrier_backfill_0137_provenance'),('carrier_factoring_integrations'),('factoring_policy_idempotency'),
     ('factoring_integration_lifecycle_idempotency'),('carrier_dispatch_service_agreement_idempotency'),
     ('carrier_dispatch_service_agreements'),('carrier_dispatch_service_agreement_versions'),
     ('carrier_dispatch_service_billing_lines'),('carrier_invoice_payments'),
     ('carrier_invoices'),('carrier_invoice_line_items'),('carrier_invoice_loads'),
     ('carrier_invoice_number_counters'),('carrier_invoice_lifecycle_idempotency'),
     ('carrier_invoice_issuance_snapshots'),('legacy_invoice_carrier_migration_review'),
     ('legacy_invoice_review_idempotency')
   ) t(tbl)
   cross join (values ('INSERT'),('UPDATE'),('DELETE')) op(op)
   where to_regclass('public.'||t.tbl) is not null
     and has_table_privilege('authenticated','public.'||t.tbl,op.op)
     and (t.tbl,op.op) not in (
       ('carrier_invoices','INSERT'),('carrier_invoices','DELETE'),
       ('carrier_invoice_line_items','INSERT'),('carrier_invoice_line_items','UPDATE'),('carrier_invoice_line_items','DELETE'),
       ('carrier_invoice_loads','INSERT'),('carrier_invoice_loads','DELETE'),('carrier_invoice_loads','UPDATE'),
       ('carrier_brokers','INSERT'),('carrier_brokers','UPDATE'),
       ('carrier_customers','INSERT'),('carrier_customers','UPDATE'),
       ('carrier_remittance_profiles','INSERT'),('carrier_remittance_profiles','UPDATE'),
       ('unresolved_carrier_records','UPDATE')
     )
 ) x)::bigint,'A table introduced by 0130-0146 grants authenticated a direct table-level write privilege outside the fully-reviewed allowlist documented in this finding.','Stop; either the grant is a new gap (revoke it) or it is intentional and this allowlist/its policy audit needs updating.' union all
 -- loads/dispatches/trailers are PRE-EXISTING tables (0004/0132's own base)
 -- -- their 0132 guard triggers must only be expected once 0132 itself has
 -- landed, unlike every other row here whose table is CREATED by the same
 -- migration that adds its trigger. trailer_ownership_scope_audit (0132's
 -- own new table) is this file's existing 0132 landmark (see SCHEMA_0132).
 select 'PLAT_GUARD_TRIGGER_MISSING','platform','platform_guard_trigger_missing','WARNING',(select count(*) filter(where missing) from (values
   ('carrier_remittance_profiles','carrier_remittance_profiles_guard_org',true),
   ('carrier_brokers','carrier_brokers_guard_org',true),('carrier_customers','carrier_customers_guard_org',true),
   ('loads','loads_guard_carrier_change',false),('dispatches','dispatches_guard_carrier_scope',false),
   ('trailers','trailers_guard_ownership_scope_change',false),
   ('carrier_factoring_integrations','carrier_factoring_integrations_guard_org',true),
   ('carrier_factoring_integrations','a0141_lifecycle_transition',true),
   ('carrier_dispatch_service_agreement_versions','a0145_guard_agreement_version_lifecycle',true)
 ) t(tbl,trg,own_table_is_landmark), lateral (select
     (t.own_table_is_landmark and to_regclass('public.'||t.tbl) is not null
        or not t.own_table_is_landmark and to_regclass('public.trailer_ownership_scope_audit') is not null)
     and not exists(select 1 from pg_trigger tg where tg.tgrelid=to_regclass('public.'||t.tbl) and tg.tgname=t.trg and not tg.tgisinternal) as missing) x)::bigint,'A documented non-financial lifecycle/org-consistency guard trigger introduced by 0130-0146 is missing.','Stop; restore via the owning migration.' union all
 select 'PLAT_BACKSTOP_CONSTRAINT_MISSING','platform','platform_backstop_constraint_missing','WARNING',(select count(*) filter(where missing) from (values
   ('carrier_brokers','carrier_brokers_carrier_broker_uq'),('carrier_customers','carrier_customers_carrier_customer_uq'),
   ('financial_idempotency_keys','financial_idempotency_keys_org_scope_key_uq'),
   ('carrier_dispatch_service_agreements','cdsa_org_carrier_agreement_number_unique'),
   ('carrier_dispatch_service_agreement_versions','cdsav_agreement_version_number_unique'),
   ('carrier_dispatch_service_agreement_versions','cdsav_no_overlap_when_approved'),
   ('carrier_dispatch_service_agreement_idempotency','cdsai_idempotency_unique')
 ) t(tbl,con), lateral (select to_regclass('public.'||t.tbl) is not null and not exists(select 1 from pg_constraint c where c.conrelid=to_regclass('public.'||t.tbl) and c.conname=t.con) as missing) x)::bigint,'A documented non-financial uniqueness/exclusion backstop constraint introduced by 0130-0146 is missing.','Stop; restore via the owning migration.' union all
 -- Section G: sequences. 0146 is the only migration in 0130-0146 that
 -- creates a real sequence (payment numbering); every other identifier in
 -- this range is a UUID primary key. Neither anon nor authenticated should
 -- ever hold a privilege on it -- numbering is allocated exclusively inside
 -- the SECURITY DEFINER RPC that owns it, never by a direct client nextval.
 select 'PLAT_SEQUENCE_GRANTS','platform','platform_sequence_unexpected_grant','BLOCKER',(select count(*) from (values
   ('carrier_invoice_payment_number_seq')
 ) t(seq) where to_regclass('public.'||t.seq) is not null and (has_sequence_privilege('anon','public.'||t.seq,'USAGE') or has_sequence_privilege('anon','public.'||t.seq,'SELECT') or has_sequence_privilege('anon','public.'||t.seq,'UPDATE') or has_sequence_privilege('authenticated','public.'||t.seq,'USAGE') or has_sequence_privilege('authenticated','public.'||t.seq,'SELECT') or has_sequence_privilege('authenticated','public.'||t.seq,'UPDATE')))::bigint,'A sequence introduced by 0130-0146 grants anon or authenticated a direct privilege; numbering must only ever be allocated inside its owning SECURITY DEFINER RPC.','Stop; revoke. A client must never call nextval()/setval() directly.' union all
 -- Section F: default privileges. 0010 grants authenticated blanket CRUD on
 -- every EXISTING table plus `alter default privileges ... on tables` for
 -- every FUTURE one -- scoped to relation objtype 'r' only, deliberately
 -- never covering sequences or functions (pg_default_acl below is the
 -- static half of this proof; TEST_PRODUCTION_PREFLIGHT_0130_0147_READONLY.sh
 -- separately creates and drops real disposable objects to confirm this
 -- behaviorally rather than by catalog inspection alone).
 select 'PLAT_DEFAULT_PRIVILEGE_DRIFT','platform','platform_default_privilege_drift','WARNING',(select count(*) from (
   select 1 where not exists (
     select 1 from pg_default_acl da join pg_namespace n on n.oid=da.defaclnamespace
     where n.nspname='public' and da.defaclobjtype='r'
       and 'authenticated=arwd/postgres' = any(string_to_array(array_to_string(da.defaclacl,','),','))
   )
   union all
   select 1 from pg_default_acl da join pg_namespace n on n.oid=da.defaclnamespace
   where n.nspname='public' and da.defaclobjtype in ('S','f')
 ) x)::bigint,'The public schema''s default-privilege configuration no longer matches 0010''s documented intent (authenticated CRUD on future tables only; nothing default-granted for future sequences or functions).','Stop; identify what changed the default-privilege configuration outside the reviewed migrations.' union all
 -- ======================= Phase 3C.0F.2 =====================================
 -- Platform-wide function security for every function introduced or
 -- materially replaced by migrations 0130-0146 (75 distinct names; 50
 -- non-trigger signatures, 25 trigger functions). Every check guards
 -- existence via to_regprocedure/to_regclass so it stays valid at every
 -- pre-0130 boundary fixture. Signatures are derived from the real
 -- installed catalog (pg_get_function_identity_arguments), never assumed.
 --
 -- Category 1: 31 client-facing RPCs. Correct target state: authenticated
 -- EXECUTE granted, anon/PUBLIC EXECUTE absent.
 select 'FUNC_CLIENT_RPC_ANON_EXECUTE','function','client_rpc_anon_or_public_execute_summary','INFO',(select count(*) filter(where bad) from (values
   ('public.activate_carrier_factoring_integration(uuid,text,timestamptz,text)'),
   ('public.activate_carrier_party(uuid,uuid,uuid,jsonb)'),
   ('public.approve_carrier_dispatch_service_agreement_version(uuid,timestamptz,text,text,uuid)'),
   ('public.approve_factoring_relationship_noa(uuid,text,date,text,uuid)'),
   ('public.approve_trailer_ownership_scope(uuid,trailer_ownership_scope,text,uuid)'),
   ('public.carrier_ids_authorized_for_current_user()'),
   ('public.carrier_ids_selectable_for_new_records()'),
   ('public.classify_carrier_factoring_readiness(uuid,uuid,uuid)'),
   ('public.configure_carrier_factoring_integration(uuid,text,text,integration_provider,text,text,timestamptz,text)'),
   ('public.create_carrier_dispatch_service_agreement(uuid,text,text,text)'),
   ('public.create_carrier_dispatch_service_agreement_version(uuid,dispatch_service_fee_method,numeric,numeric,numeric,numeric,text,integer,date,date,text,text)'),
   ('public.deactivate_carrier_dispatch_service_agreement(uuid,timestamptz,text,text)'),
   ('public.deactivate_carrier_dispatch_service_agreement_version(uuid,timestamptz,text,text)'),
   ('public.deactivate_carrier_factoring_integration(uuid,text,timestamptz,text)'),
   ('public.deactivate_factoring_relationship(uuid,text,timestamptz,text,boolean)'),
   ('public.fail_carrier_factoring_integration(uuid,text,timestamptz,text)'),
   ('public.get_carrier_factoring_integration_status(uuid)'),
   ('public.issue_carrier_invoice(uuid,timestamptz,text,text)'),
   ('public.reassign_dispatch_resources(uuid,uuid,uuid,uuid,text,text,timestamptz)'),
   ('public.record_carrier_invoice_payment(uuid,numeric,date,text,text,timestamptz,text,text)'),
   ('public.record_unresolved_carrier_record(uuid,text,uuid,text,jsonb)'),
   ('public.review_legacy_invoice_carrier_migration(uuid,text,text,timestamptz,text)'),
   ('public.revoke_carrier_factoring_integration(uuid,text,timestamptz,text)'),
   ('public.rotate_carrier_factoring_integration(uuid,text,text,integration_provider,text,text,timestamptz,text)'),
   ('public.scan_legacy_invoices_for_carrier_migration()'),
   ('public.set_carrier_factoring_policy(uuid,carrier_factoring_mode,text,timestamptz,text)'),
   ('public.set_default_factoring_relationship(uuid)'),
   ('public.transition_dispatch_status(uuid,dispatch_status,text,text)'),
   ('public.update_carrier_invoice_draft(uuid,jsonb,timestamptz,text,text)'),
   ('public.verify_carrier_factoring_integration(uuid,text,timestamptz,text)'),
   ('public.void_carrier_invoice_payment(uuid,timestamptz,text,text)')
 ) t(sig), lateral (select to_regprocedure(t.sig) is not null and (has_function_privilege('anon',to_regprocedure(t.sig),'EXECUTE') or has_function_privilege('public',to_regprocedure(t.sig)::regproc,'EXECUTE')) as bad) x)::bigint,'A client-facing RPC introduced by 0130-0146 is executable by anon or PUBLIC. Three pre-0147 exposures are each enforced by a separate BLOCKER finding below; this row is informational inventory only and cannot substitute for an individual finding.','Stop; revoke. Only authenticated may call these RPCs.' union all
 -- The 3 currently-known, permanently-documented anon/PUBLIC-execute gaps
 -- (missing the sibling "revoke all ... from public, anon" that every
 -- OTHER client RPC in this range received alongside its own grant).
 -- update_carrier_invoice_draft is the original Phase 3C.0E.3 finding;
 -- scan_legacy_invoices_for_carrier_migration and review_legacy_invoice_
 -- carrier_migration are NEWLY discovered siblings in this phase (0142
 -- grants execute to authenticated for both but never adds the matching
 -- revoke, exactly like update_carrier_invoice_draft; classify_legacy_
 -- invoice_for_carrier_migration, by contrast, correctly receives
 -- "revoke all ... from public, anon, authenticated" two lines after its
 -- own creation in the same migration -- proving the gap is a real
 -- inconsistency, not a deliberate design choice).
 select 'FUNC_UPDATE_DRAFT_PUBLIC_EXECUTE','function','update_carrier_invoice_draft_public_or_anon_execute','BLOCKER',(select case
   when to_regclass('public.carrier_invoices') is null then 0
   when (select count(*) from pg_proc p where p.pronamespace='public'::regnamespace and p.proname='update_carrier_invoice_draft') <> 1 then 1
   when to_regprocedure('public.update_carrier_invoice_draft(uuid,jsonb,timestamptz,text,text)') is null then 1
   when not has_function_privilege('authenticated','public.update_carrier_invoice_draft(uuid,jsonb,timestamptz,text,text)','EXECUTE') then 1
   when has_function_privilege('anon','public.update_carrier_invoice_draft(uuid,jsonb,timestamptz,text,text)','EXECUTE')
     or has_function_privilege('public',to_regprocedure('public.update_carrier_invoice_draft(uuid,jsonb,timestamptz,text,text)')::regproc,'EXECUTE') then 1
   else 0 end)::bigint,'The exact update_carrier_invoice_draft signature must be the sole overload and authenticated-only. Missing, overloaded, PUBLIC/anon-executable, or authenticated-inaccessible shapes fail closed.','Stop; restore the exact signature and revoke PUBLIC/anon while retaining authenticated EXECUTE.' union all
 select 'FUNC_LEGACY_REVIEW_PUBLIC_EXECUTE','function','review_legacy_invoice_carrier_migration_public_or_anon_execute','BLOCKER',(select case
   when to_regclass('public.carrier_invoices') is null then 0
   when (select count(*) from pg_proc p where p.pronamespace='public'::regnamespace and p.proname='review_legacy_invoice_carrier_migration') <> 1 then 1
   when to_regprocedure('public.review_legacy_invoice_carrier_migration(uuid,text,text,timestamptz,text)') is null then 1
   when not has_function_privilege('authenticated','public.review_legacy_invoice_carrier_migration(uuid,text,text,timestamptz,text)','EXECUTE') then 1
   when has_function_privilege('anon','public.review_legacy_invoice_carrier_migration(uuid,text,text,timestamptz,text)','EXECUTE')
     or has_function_privilege('public',to_regprocedure('public.review_legacy_invoice_carrier_migration(uuid,text,text,timestamptz,text)')::regproc,'EXECUTE') then 1
   else 0 end)::bigint,'The exact legacy-review signature must be the sole overload and authenticated-only. Missing, overloaded, PUBLIC/anon-executable, or authenticated-inaccessible shapes fail closed.','Stop; restore the exact signature and revoke PUBLIC/anon while retaining authenticated EXECUTE.' union all
 select 'FUNC_LEGACY_SCAN_PUBLIC_EXECUTE','function','scan_legacy_invoices_for_carrier_migration_public_or_anon_execute','BLOCKER',(select case
   when to_regclass('public.carrier_invoices') is null then 0
   when (select count(*) from pg_proc p where p.pronamespace='public'::regnamespace and p.proname='scan_legacy_invoices_for_carrier_migration') <> 1 then 1
   when to_regprocedure('public.scan_legacy_invoices_for_carrier_migration()') is null then 1
   when not has_function_privilege('authenticated','public.scan_legacy_invoices_for_carrier_migration()','EXECUTE') then 1
   when has_function_privilege('anon','public.scan_legacy_invoices_for_carrier_migration()','EXECUTE')
     or has_function_privilege('public',to_regprocedure('public.scan_legacy_invoices_for_carrier_migration()')::regproc,'EXECUTE') then 1
   else 0 end)::bigint,'The exact legacy-scan signature must be the sole overload and authenticated-only. Missing, overloaded, PUBLIC/anon-executable, or authenticated-inaccessible shapes fail closed.','Stop; restore the exact signature and revoke PUBLIC/anon while retaining authenticated EXECUTE.' union all
 --
 -- Category 2: 15 internal helpers (never called directly by any client
 -- role; reachable only from a trusted SECURITY DEFINER caller that has
 -- already verified authorization). Correct target state: zero EXECUTE
 -- for anon, authenticated, and PUBLIC.
 select 'FUNC_INTERNAL_HELPER_CLIENT_EXECUTE','function','internal_helper_client_executable','BLOCKER',(select count(*) filter(where bad) from (values
   ('public._carrier_dispatch_service_agreement_effective_dates_lock_key(uuid,uuid)'),
   ('public._carrier_invoice_payment_external_reference_problem(text)'),
   ('public._generate_carrier_invoice_number_internal(invoice_document_type,uuid,text)'),
   ('public._generate_carrier_invoice_payment_number_internal()'),
   ('public._issue_dispatch_service_invoice_internal(uuid,carrier_invoices,uuid,uuid,text,text,text,integer,text)'),
   ('public.carrier_invoice_factoring_readiness_problem(uuid)'),
   ('public.carrier_invoice_issuance_problem(uuid)'),
   ('public.carrier_invoice_payment_snapshot_problem(uuid)'),
   ('public.carrier_invoice_recipient_problem(uuid)'),
   ('public.classify_legacy_invoice_for_carrier_migration(uuid)'),
   ('public.compute_financial_request_fingerprint(jsonb)'),
   ('public.factoring_integration_lifecycle_precheck(text,timestamptz,text)'),
   ('public.factoring_integration_lifecycle_problem(uuid)'),
   ('public.factoring_relationship_lifecycle_problem(uuid)'),
   ('public.transition_carrier_factoring_integration_lifecycle(text,uuid,text,timestamptz,text)')
 ) t(sig), lateral (select to_regprocedure(t.sig) is not null and (has_function_privilege('authenticated',to_regprocedure(t.sig),'EXECUTE') or has_function_privilege('anon',to_regprocedure(t.sig),'EXECUTE')) as bad) x)::bigint,'An internal, mechanism-only helper introduced by 0130-0146 is directly executable by authenticated or anon. (jsonb_contains_forbidden_key/dispatch_status_sequence_rank/is_valid_dispatch_status_transition are pure, argument-only, no-table-access utilities deliberately excluded -- their exposure carries no security consequence, same rationale as Phase 3C.0E.3''s original exclusion.)','Stop; revoke direct EXECUTE. Internal helpers are never called directly by a client role.' union all
 --
 -- NEWLY DISCOVERED defect: a null-identity (anon, or an authenticated
 -- session with no profile row) caller of scan_legacy_invoices_for_
 -- carrier_migration() does not receive the intended 42501 FORBIDDEN
 -- exception. Root cause: `if not public.has_role(...) then raise
 -- exception ... end if;` is the function's FIRST check, with no prior
 -- `auth.uid() is null` / `current_org_id() is null` guard -- and
 -- has_role() returns SQL NULL (not false) for a null identity (its own
 -- body is `select current_role() = any(p_roles)`, and `NULL = any(...)`
 -- is NULL). PL/pgSQL's `IF NOT (NULL) THEN` does not enter the THEN
 -- branch (NULL is not TRUE), so the RAISE EXCEPTION is silently skipped
 -- and execution falls through to the function's own org-scoped loop,
 -- which then matches zero rows (current_org_id() is also NULL) and
 -- returns 0 -- a misleading "nothing to process" success instead of a
 -- clear FORBIDDEN error. No real data is read or written (confirmed:
 -- the org-scoped SELECT structurally cannot match any row when
 -- organization_id must equal NULL), but the intended fail-closed error
 -- contract is violated. review_legacy_invoice_carrier_migration and
 -- update_carrier_invoice_draft do NOT share this defect -- both check
 -- `current_org_id() IS NULL` (a proper ternary-safe test) BEFORE ever
 -- reaching a has_role() call.
 select 'FUNC_NULL_IDENTITY_AUTH_BYPASS','function','null_identity_has_role_first_check_bypass','BLOCKER',(select count(*) filter(where to_regprocedure(sig) is not null
     and (select prosrc from pg_proc where oid=to_regprocedure(sig)) ilike '%if not public.has_role%'
     and (select prosrc from pg_proc where oid=to_regprocedure(sig)) not ilike '%auth.uid() is null%') from (values
   ('public.scan_legacy_invoices_for_carrier_migration()')
 ) t(sig))::bigint,'A null-identity caller (anon, or authenticated with no profile row) of this function silently bypasses its intended owner/admin-only FORBIDDEN check because has_role() returns NULL (not false) and PL/pgSQL treats `IF NOT NULL` as not-true. Structural source-pattern detection (bare `if not public.has_role` with no preceding `auth.uid() is null` guard) rather than a behavioral call, since this audit never invokes a mutating/mutation-capable function -- see TEST_PRODUCTION_PREFLIGHT_0130_0147_READONLY.sh for the disposable-harness behavioral proof of the same defect/correction. Permanently asserted at 1 against the real, unmodified 0142 installed function; 0 once 0147''s explicit auth.uid()/current_org_id() null checks and IS NOT TRUE role test are installed.','Stop; rewrite as `if auth.uid() is null or not coalesce(public.has_role(...), false) then raise exception` (or add an explicit auth.uid()/current_org_id() IS NULL guard before the role check), matching the pattern every other RPC in this range already uses correctly.' union all
 --
 -- Phase 3C.2: the two 0147 guarded draft RPCs replacing the direct
 -- INSERT/DELETE grants (BLOCKERs #2/#3). Absent pre-0147 (both counts
 -- read 0, vacuously healthy, via the same to_regprocedure-is-null guard
 -- every optional-object finding in this file already uses); present and
 -- authenticated-only, never PUBLIC/anon, post-0147.
 select 'RPC_0147_CREATE_DRAFT_ACL','function','create_carrier_invoice_draft_acl','BLOCKER',(select case when to_regprocedure('public.create_carrier_invoice_draft(public.invoice_document_type,uuid,public.invoice_recipient_type,uuid,uuid,text,integer,date,text,text,text)') is null then 0
     when has_function_privilege('anon','public.create_carrier_invoice_draft(public.invoice_document_type,uuid,public.invoice_recipient_type,uuid,uuid,text,integer,date,text,text,text)','EXECUTE')
       or has_function_privilege('public',to_regprocedure('public.create_carrier_invoice_draft(public.invoice_document_type,uuid,public.invoice_recipient_type,uuid,uuid,text,integer,date,text,text,text)')::regproc,'EXECUTE')
       or not has_function_privilege('authenticated','public.create_carrier_invoice_draft(public.invoice_document_type,uuid,public.invoice_recipient_type,uuid,uuid,text,integer,date,text,text,text)','EXECUTE')
     then 1 else 0 end)::bigint,'create_carrier_invoice_draft(...) (0147), the sole guarded path to create a carrier_invoices row, must be authenticated-only: PUBLIC/anon must never execute it, and authenticated must be able to.','Stop; revoke all on the function from public, anon; grant execute to authenticated only.' union all
 select 'RPC_0147_DELETE_DRAFT_ACL','function','delete_carrier_invoice_draft_acl','BLOCKER',(select case when to_regprocedure('public.delete_carrier_invoice_draft(uuid,timestamptz,text,text)') is null then 0
     when has_function_privilege('anon','public.delete_carrier_invoice_draft(uuid,timestamptz,text,text)','EXECUTE')
       or has_function_privilege('public',to_regprocedure('public.delete_carrier_invoice_draft(uuid,timestamptz,text,text)')::regproc,'EXECUTE')
       or not has_function_privilege('authenticated','public.delete_carrier_invoice_draft(uuid,timestamptz,text,text)','EXECUTE')
     then 1 else 0 end)::bigint,'delete_carrier_invoice_draft(...) (0147), the sole guarded path to delete a carrier_invoices row, must be authenticated-only: PUBLIC/anon must never execute it, and authenticated must be able to.','Stop; revoke all on the function from public, anon; grant execute to authenticated only.' union all
 select 'IDEMPOTENCY_0147_CREATE_OBJECT','function','carrier_invoice_draft_create_idempotency_posture','BLOCKER',(select case when to_regclass('public.carrier_invoice_draft_create_idempotency') is null then 0
     when has_table_privilege('authenticated','public.carrier_invoice_draft_create_idempotency','INSERT')
       or has_table_privilege('authenticated','public.carrier_invoice_draft_create_idempotency','UPDATE')
       or has_table_privilege('authenticated','public.carrier_invoice_draft_create_idempotency','DELETE')
       or exists(select 1 from information_schema.role_table_grants where grantee='anon' and table_name='carrier_invoice_draft_create_idempotency')
       or not exists(select 1 from pg_constraint c join pg_class t on t.oid=c.conrelid where t.relname='carrier_invoice_draft_create_idempotency' and c.contype='u' and pg_get_constraintdef(c.oid) ilike '%organization_id%' and pg_get_constraintdef(c.oid) ilike '%idempotency_key%')
     then 1 else 0 end)::bigint,'carrier_invoice_draft_create_idempotency (0147) must have zero client INSERT/UPDATE/DELETE (writable only via the owning SECURITY DEFINER RPC), zero anon grant of any kind, and a UNIQUE constraint scoped to (organization_id, idempotency_key) so no cross-organization or cross-key collision is structurally possible.','Stop; revoke direct client mutation privileges and/or restore the organization-scoped unique constraint via the owning migration.' union all
 select 'IDEMPOTENCY_0147_DELETE_OBJECT','function','carrier_invoice_draft_delete_idempotency_posture','BLOCKER',(select case when to_regclass('public.carrier_invoice_draft_delete_idempotency') is null then 0
     when has_table_privilege('authenticated','public.carrier_invoice_draft_delete_idempotency','INSERT')
       or has_table_privilege('authenticated','public.carrier_invoice_draft_delete_idempotency','UPDATE')
       or has_table_privilege('authenticated','public.carrier_invoice_draft_delete_idempotency','DELETE')
       or exists(select 1 from information_schema.role_table_grants where grantee='anon' and table_name='carrier_invoice_draft_delete_idempotency')
       or not exists(select 1 from pg_constraint c join pg_class t on t.oid=c.conrelid where t.relname='carrier_invoice_draft_delete_idempotency' and c.contype='u' and pg_get_constraintdef(c.oid) ilike '%organization_id%' and pg_get_constraintdef(c.oid) ilike '%idempotency_key%')
     then 1 else 0 end)::bigint,'carrier_invoice_draft_delete_idempotency (0147) must have zero client INSERT/UPDATE/DELETE (writable only via the owning SECURITY DEFINER RPC), zero anon grant of any kind, and a UNIQUE constraint scoped to (organization_id, idempotency_key) so no cross-organization or cross-key collision is structurally possible.','Stop; revoke direct client mutation privileges and/or restore the organization-scoped unique constraint via the owning migration.' union all
 --
 -- Category 3: SECURITY DEFINER hygiene, all 75 functions. search_path
 -- pinning and function ownership are the two structural preconditions
 -- for every other SECURITY DEFINER guarantee in this file to mean
 -- anything at all.
 select 'FUNC_SECDEF_MISSING_SEARCH_PATH','function','security_definer_missing_search_path','BLOCKER',(select count(*) from (
   select p.oid from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='public' and p.prosecdef
     and p.proname = any(string_to_array('_carrier_dispatch_service_agreement_effective_dates_lock_key,_generate_carrier_invoice_number_internal,_generate_carrier_invoice_payment_number_internal,_issue_dispatch_service_invoice_internal,activate_carrier_factoring_integration,approve_carrier_dispatch_service_agreement_version,carrier_invoice_factoring_readiness_problem,carrier_invoice_issuance_problem,carrier_invoice_recipient_problem,classify_legacy_invoice_for_carrier_migration,configure_carrier_factoring_integration,create_carrier_dispatch_service_agreement,create_carrier_dispatch_service_agreement_version,deactivate_carrier_dispatch_service_agreement,deactivate_carrier_dispatch_service_agreement_version,deactivate_carrier_factoring_integration,deactivate_factoring_relationship,factoring_integration_lifecycle_problem,factoring_relationship_lifecycle_problem,fail_carrier_factoring_integration,get_carrier_factoring_integration_status,guard_carrier_dispatch_service_agreement_version_lifecycle,guard_carrier_invoice_delete,guard_carrier_invoice_issuance_snapshot_immutable,guard_carrier_invoice_lifecycle_transition,guard_carrier_invoice_line_item_mutability,guard_carrier_invoice_load_consistency,guard_carrier_invoice_load_mutability,guard_carrier_invoice_org_consistency,guard_carrier_invoice_payment_currency,guard_carrier_invoice_payment_lifecycle,guard_carrier_party_org,guard_carrier_remittance_profile_org,guard_dispatch_carrier_scope,guard_factoring_integration_lifecycle_transition,guard_factoring_lifecycle_dependencies,guard_load_carrier_change,guard_load_stops_parent_lock,guard_trailer_ownership_scope_change,issue_carrier_invoice,activate_carrier_party,record_carrier_invoice_payment,record_unresolved_carrier_record,recalculate_carrier_invoice_totals,reassign_dispatch_resources,review_legacy_invoice_carrier_migration,revoke_carrier_factoring_integration,rotate_carrier_factoring_integration,scan_legacy_invoices_for_carrier_migration,set_carrier_factoring_policy,set_default_factoring_relationship,trailers_derive_ownership_scope,transition_carrier_factoring_integration_lifecycle,transition_dispatch_status,update_carrier_invoice_draft,verify_carrier_factoring_integration,void_carrier_invoice_payment,approve_factoring_relationship_noa,approve_trailer_ownership_scope,carrier_ids_authorized_for_current_user,carrier_ids_selectable_for_new_records,classify_carrier_factoring_readiness',','))
     and not exists (select 1 from unnest(coalesce(p.proconfig,'{}')) c where c like 'search_path=%')
 ) x)::bigint,'A SECURITY DEFINER function introduced or replaced by 0130-0146 has no pinned search_path -- the single structural precondition search_path-shadowing defenses (Section F) depend on.','Stop; add SET search_path = pg_catalog, public (or the function''s documented equivalent) to its definition.' union all
 select 'FUNC_SECDEF_UNEXPECTED_OWNER','function','security_definer_unexpected_owner','BLOCKER',(select count(*) from (
   select p.oid from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='public' and p.prosecdef
     and p.proname = any(string_to_array('_carrier_dispatch_service_agreement_effective_dates_lock_key,_generate_carrier_invoice_number_internal,_generate_carrier_invoice_payment_number_internal,_issue_dispatch_service_invoice_internal,activate_carrier_factoring_integration,approve_carrier_dispatch_service_agreement_version,carrier_invoice_factoring_readiness_problem,carrier_invoice_issuance_problem,carrier_invoice_recipient_problem,classify_legacy_invoice_for_carrier_migration,configure_carrier_factoring_integration,create_carrier_dispatch_service_agreement,create_carrier_dispatch_service_agreement_version,deactivate_carrier_dispatch_service_agreement,deactivate_carrier_dispatch_service_agreement_version,deactivate_carrier_factoring_integration,deactivate_factoring_relationship,factoring_integration_lifecycle_problem,factoring_relationship_lifecycle_problem,fail_carrier_factoring_integration,get_carrier_factoring_integration_status,guard_carrier_dispatch_service_agreement_version_lifecycle,guard_carrier_invoice_delete,guard_carrier_invoice_issuance_snapshot_immutable,guard_carrier_invoice_lifecycle_transition,guard_carrier_invoice_line_item_mutability,guard_carrier_invoice_load_consistency,guard_carrier_invoice_load_mutability,guard_carrier_invoice_org_consistency,guard_carrier_invoice_payment_currency,guard_carrier_invoice_payment_lifecycle,guard_carrier_party_org,guard_carrier_remittance_profile_org,guard_dispatch_carrier_scope,guard_factoring_integration_lifecycle_transition,guard_factoring_lifecycle_dependencies,guard_load_carrier_change,guard_load_stops_parent_lock,guard_trailer_ownership_scope_change,issue_carrier_invoice,activate_carrier_party,record_carrier_invoice_payment,record_unresolved_carrier_record,recalculate_carrier_invoice_totals,reassign_dispatch_resources,review_legacy_invoice_carrier_migration,revoke_carrier_factoring_integration,rotate_carrier_factoring_integration,scan_legacy_invoices_for_carrier_migration,set_carrier_factoring_policy,set_default_factoring_relationship,trailers_derive_ownership_scope,transition_carrier_factoring_integration_lifecycle,transition_dispatch_status,update_carrier_invoice_draft,verify_carrier_factoring_integration,void_carrier_invoice_payment,approve_factoring_relationship_noa,approve_trailer_ownership_scope,carrier_ids_authorized_for_current_user,carrier_ids_selectable_for_new_records,classify_carrier_factoring_readiness',','))
     and p.proowner <> (select proowner from pg_proc where proname='current_org_id' and pronamespace='public'::regnamespace limit 1)
 ) x)::bigint,'A SECURITY DEFINER function introduced by 0130-0146 is owned by a different role than the platform''s baseline SECURITY DEFINER owner (current_org_id(), pre-existing since 0001, is the reference).','Stop; a mismatched owner changes whose privileges the function runs with.' union all
 -- Category 4: informational-only raw grant facts, immediately qualified
 -- by a behavioral non-exploitability proof (never reported as a
 -- BLOCKER/WARNING without exploitability, per this phase''s own mission
 -- instruction).
 select 'FUNC_TRIGGER_UNREVOKED_EXECUTE','function','trigger_function_execute_not_revoked','INFO',(select count(*) from (values
   ('guard_carrier_dispatch_service_agreement_version_lifecycle'),('guard_carrier_factoring_integration_org'),
   ('guard_carrier_invoice_delete'),('guard_carrier_invoice_issuance_snapshot_immutable'),
   ('guard_carrier_invoice_lifecycle_transition'),('guard_carrier_invoice_line_item_mutability'),
   ('guard_carrier_invoice_load_consistency'),('guard_carrier_invoice_load_mutability'),
   ('guard_carrier_invoice_org_consistency'),('guard_carrier_invoice_payment_currency'),
   ('guard_carrier_invoice_payment_lifecycle'),('guard_carrier_party_direct_billing_exception'),
   ('guard_carrier_party_org'),('guard_carrier_remittance_profile_org'),('guard_dispatch_carrier_scope'),
   ('guard_factoring_company_deactivation'),('guard_factoring_integration_lifecycle_transition'),
   ('guard_factoring_lifecycle_dependencies'),('guard_factoring_relationship_org'),
   ('guard_factoring_relationship_protected_fields'),('guard_load_carrier_change'),
   ('guard_load_stops_parent_lock'),('guard_trailer_ownership_scope_change'),
   ('recalculate_carrier_invoice_totals'),('trailers_derive_ownership_scope')
 ) t(fn), lateral (select p.oid from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname=t.fn and p.prorettype='trigger'::regtype limit 1) f
 where has_function_privilege('authenticated',f.oid,'EXECUTE') or has_function_privilege('anon',f.oid,'EXECUTE'))::bigint,
 'A trigger-only function retains its PostgreSQL-default PUBLIC EXECUTE grant. NOT exploitable: PostgreSQL itself refuses to invoke any RETURNS TRIGGER function via a direct call ("trigger functions can only be called as triggers"), regardless of any EXECUTE grant -- confirmed by direct test (platform_trigger_function_direct_call_rejected). Reported for completeness/hygiene only.',
 'Optional hygiene: revoke all on function ... from public, anon for consistency with the rest of this range, though no functional change results.' union all
 -- submit_invoice_to_factor (0140) is SECURITY INVOKER (not DEFINER) and
 -- shows anon/authenticated/PUBLIC EXECUTE all true -- structurally
 -- different from every other finding in this section: an INVOKER
 -- function carries none of its own elevated privilege, so granting it
 -- to anon confers nothing beyond what anon''s own (zero) table grants
 -- already allow. 0140''s own installed body unconditionally returns
 -- {success:false, code:CARRIER_INVOICE_SNAPSHOT_REQUIRED} for every
 -- legacy invoice today (no factored_invoices/factoring_events row is
 -- ever created), confirmed behaviorally (platform_submit_invoice_to_factor_anon_safe).
 select 'FUNC_INVOKER_ANON_EXECUTE_INFO','function','security_invoker_anon_execute_no_elevation','INFO',(select count(*) from (
   select 1 where to_regprocedure('public.submit_invoice_to_factor(uuid,uuid)') is not null
     and has_function_privilege('anon',to_regprocedure('public.submit_invoice_to_factor(uuid,uuid)'),'EXECUTE')
 ) x)::bigint,'submit_invoice_to_factor is SECURITY INVOKER and anon-executable; since it runs with the caller''s own (zero) privileges rather than an elevated owner''s, this confers no capability anon does not already lack via direct table access.','No action required; documented for completeness.' union all
 -- Section I: structured-error non-disclosure. 0142-0146's client RPCs
 -- consistently return a clean {success:false,"code":...,"message":...}
 -- jsonb payload for every ordinary/anticipated error condition (proven
 -- directly: activate_carrier_factoring_integration, create_carrier_
 -- dispatch_service_agreement, issue_carrier_invoice, record_carrier_
 -- invoice_payment, etc. never raise for NOT_FOUND/FORBIDDEN/invalid-input
 -- cases). Five EARLIER RPCs (0130-0135) instead RAISE a raw PL/pgSQL
 -- exception for these same ordinary conditions -- confirmed directly by
 -- calling each with a representative not-found/forbidden/cross-org/
 -- invalid-input case (exact_structured_error_matrix below): the message
 -- text itself never includes a SQLSTATE/constraint/table name, but
 -- PostgreSQL's own CONTEXT necessarily includes the internal function
 -- name and the raising statement's line number for any raised exception
 -- -- information the newer jsonb-return convention never exposes at all,
 -- since it never raises for these cases in the first place.
 select 'FUNC_RAISE_LEAKS_CONTEXT','function','ordinary_error_raises_exception_instead_of_structured_result','WARNING',(select count(*) filter(where uses_raise) from (
   select t.sig, pg_get_functiondef(to_regprocedure(t.sig)) ilike '%raise exception%' as uses_raise
   from (values
     ('public.activate_carrier_party(uuid,uuid,uuid,jsonb)'),
     ('public.approve_trailer_ownership_scope(uuid,trailer_ownership_scope,text,uuid)'),
     ('public.transition_dispatch_status(uuid,dispatch_status,text,text)'),
     ('public.reassign_dispatch_resources(uuid,uuid,uuid,uuid,text,text,timestamptz)'),
     ('public.record_unresolved_carrier_record(uuid,text,uuid,text,jsonb)')
   ) t(sig) where to_regprocedure(t.sig) is not null
 ) x)::bigint,'An RPC introduced by 0130-0135 raises a raw PL/pgSQL exception (leaking internal function name + line number via CONTEXT) for an ordinary, anticipated error condition instead of returning the {success:false,"code":...} structured result every 0138+ RPC in this range consistently uses. Confirmed behaviorally, not merely by text search (a bare "raise exception" search also matches issue_carrier_invoice''s legitimate defensive/should-never-happen assertions, which do not fire for ordinary input -- exact_structured_error_matrix distinguishes the two).','Consider migrating these 5 RPCs to the same structured-jsonb-return convention 0138+ established, for defense-in-depth consistency (the message text alone does not currently leak SQLSTATE/constraint/table names).' union all
 -- ======================= Phase 3C.0F.3 =====================================
 -- Pre-0130 platform table privileges, RLS enablement, and policy/trigger
 -- behavior -- closing manifest rows 97/101/103/104's remaining, non-
 -- 0130-0146 scope. 25 tables spanning identity/tenancy, dispatch
 -- operations, parties, legacy invoicing/AR, and pre-0130 factoring.
 -- Guards existence via to_regclass so this stays valid at every boundary.
 --
 -- MATURITY LANDMARK: every check below additionally gates on migration
 -- 0012's own profiles_protect_privileged_columns trigger. This is not
 -- optional-table-safety (these tables all pre-date and always exist by
 -- 0130) -- it distinguishes a genuinely complete 0001-0129 install from
 -- TEST_SUPPORT_0130_0133_schema.sql's own bare, single-migration-focused
 -- stub (used by this file's own earlier, pre-existing 0130-0133 fixtures
 -- to test THOSE migrations in isolation), which deliberately does not
 -- replay every one of 0010/0012/0071/0125's platform-wide RLS/guard
 -- statements -- only 0130-0133's own direct dependencies. Without this
 -- gate, these checks would misfire against that earlier-stage fixture
 -- (a real regression caught by this file's own history_unknown fixture
 -- during development: it unexpectedly flipped from SCHEMA_STATE_UNKNOWN
 -- to BLOCKED). On a genuinely complete install (real production, or this
 -- phase's own audit_pre0130_full/audit_post0146 templates), the landmark
 -- is always present and every check below evaluates for real.
 select 'PRE0130_RLS_MISSING','platform','pre0130_table_missing_rls','BLOCKER',(select case when not exists(select 1 from pg_trigger where tgname='profiles_protect_privileged_columns' and not tgisinternal) then 0 else (select count(*) from (values
   ('organizations'),('profiles'),('carriers'),('brokers'),('customers'),('drivers'),('trucks'),('trailers'),
   ('loads'),('load_stops'),('dispatches'),('documents'),('invoices'),('invoice_line_items'),('payments'),
   ('settlements'),('settlement_line_items'),('activity_logs'),('integration_settings'),
   ('factoring_companies'),('factoring_relationships'),('factored_invoices'),('factoring_events'),
   ('platform_settings')
 ) t(tbl) where to_regclass('public.'||t.tbl) is not null and not exists(select 1 from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relname=t.tbl and c.relrowsecurity)) end)::bigint,'A pre-0130 platform table exists without row level security enabled.','Stop; enable RLS via the owning migration.' union all
 select 'PRE0130_GRANTS_ANON','platform','pre0130_table_anon_grant','BLOCKER',(select case when not exists(select 1 from pg_trigger where tgname='profiles_protect_privileged_columns' and not tgisinternal) then 0 else (select count(*) from (values
   ('organizations'),('profiles'),('carriers'),('brokers'),('customers'),('drivers'),('trucks'),('trailers'),
   ('loads'),('load_stops'),('dispatches'),('documents'),('invoices'),('invoice_line_items'),('payments'),
   ('settlements'),('settlement_line_items'),('activity_logs'),('integration_settings'),
   ('factoring_companies'),('factoring_relationships'),('factored_invoices'),('factoring_events'),
   ('platform_settings')
 ) t(tbl) where to_regclass('public.'||t.tbl) is not null and (has_table_privilege('anon','public.'||t.tbl,'SELECT') or has_table_privilege('anon','public.'||t.tbl,'INSERT') or has_table_privilege('anon','public.'||t.tbl,'UPDATE') or has_table_privilege('anon','public.'||t.tbl,'DELETE'))) end)::bigint,'A pre-0130 platform table grants anon any table privilege at all.','Stop; revoke. This product has no unauthenticated read/write surface (0010).' union all
 select 'PRE0130_POLICY_MISSING','platform','pre0130_table_zero_policies','BLOCKER',(select case when not exists(select 1 from pg_trigger where tgname='profiles_protect_privileged_columns' and not tgisinternal) then 0 else (select count(*) from (values
   ('organizations'),('profiles'),('carriers'),('brokers'),('customers'),('drivers'),('trucks'),('trailers'),
   ('loads'),('load_stops'),('dispatches'),('documents'),('invoices'),('invoice_line_items'),('payments'),
   ('settlements'),('settlement_line_items'),('activity_logs'),('integration_settings'),
   ('factoring_companies'),('factoring_relationships'),('factored_invoices'),('factoring_events'),
   ('platform_settings')
 ) t(tbl) where to_regclass('public.'||t.tbl) is not null and not exists(select 1 from pg_policies p where p.schemaname='public' and p.tablename=t.tbl)) end)::bigint,'A pre-0130 platform table has RLS enabled but zero policies of any kind -- structurally inaccessible to every non-owner role, likely a functional bug rather than a security gap, but reported here since it would silently break the actor matrix.','Investigate; a table with RLS on and no policies denies all access, including legitimate access.' union all
 select 'PRE0130_MISSING_WITH_CHECK','platform','pre0130_insert_update_missing_with_check','WARNING',(select case when not exists(select 1 from pg_trigger where tgname='profiles_protect_privileged_columns' and not tgisinternal) then 0 else (select count(*) from pg_policies p
   where p.schemaname='public' and p.cmd in ('INSERT','UPDATE') and p.with_check is null
   and p.tablename = any(array['organizations','profiles','carriers','brokers','customers','drivers','trucks','trailers','loads','load_stops','dispatches','documents','invoices','invoice_line_items','payments','settlements','settlement_line_items','activity_logs','integration_settings','factoring_companies','factoring_relationships','factored_invoices','factoring_events','platform_settings'])) end)::bigint,'A pre-0130 table''s INSERT or UPDATE policy has no WITH CHECK clause -- without one, a matching USING clause (or none at all, for INSERT) does not constrain what the new/changed row may contain, potentially allowing an organization-reassignment or scope-widening write.','Stop; add a WITH CHECK clause matching the table''s SELECT/USING organization scope.' union all
 -- profiles_update_self (0010) checks only id = auth.uid(), with no
 -- column restriction -- migration 0012's own header explicitly documents
 -- this as a real privilege-escalation gap it closes: without its guard
 -- trigger, any authenticated user could set their OWN organization_id
 -- and role to anything via a direct UPDATE, instantly gaining
 -- current_org_id()/current_role() of their choosing and, transitively,
 -- RLS access to every table scoped by those two functions -- the single
 -- most severe class of defect possible in this schema. Verified
 -- DIRECTLY: without protect_profile_privileged_columns(), a same-org
 -- viewer's own UPDATE succeeds in moving them into a different
 -- organization as its owner; WITH the trigger (0012, real and applied),
 -- the identical UPDATE is rejected with insufficient_privilege. This
 -- finding permanently asserts the guard exists and is enabled. Gated on
 -- carrier_remittance_profiles (this file''s own established 0130
 -- landmark, see SCHEMA_0130 family detection above) rather than on
 -- profiles_protect_privileged_columns itself, since the latter IS what
 -- this check tests for -- self-gating would make it vacuously healthy.
 -- A bare pre-0130, single-migration-focused fixture (this file''s own
 -- earlier 0130-0133 test suite, which predates this phase and is not
 -- itself a completeness claim about 0001-0129 security) correctly does
 -- not trip this on a system that hasn''t reached 0130 yet.
 select 'PRE0130_PROFILE_PRIVILEGE_GUARD_MISSING','platform','profile_privileged_column_guard_missing','BLOCKER',(select case when to_regclass('public.carrier_remittance_profiles') is null then 0 else (select count(*) from (
   select 1 where to_regclass('public.profiles') is not null and not exists(
     select 1 from pg_trigger tg where tg.tgrelid='public.profiles'::regclass and tg.tgname='profiles_protect_privileged_columns' and not tg.tgisinternal and tg.tgenabled <> 'D'
   )
 ) x) end)::bigint,'The profiles_protect_privileged_columns trigger (migration 0012) is missing or disabled -- profiles_update_self''s own USING/WITH CHECK clause (id = auth.uid() only) provides zero defense against a user changing their OWN organization_id or role without it.','Stop; restore migration 0012''s guard trigger immediately -- this is the single highest-severity possible gap in this schema.' union all
 -- Financial-table SELECT role tier: 0010''s original policy allowed any
 -- org member (including driver/viewer) to SELECT invoices/settlements/
 -- payments/line-item data; migration 0066 (authored "PROPOSED ONLY --
 -- NOT APPLIED" but confirmed genuinely applied -- see below) narrows
 -- this to owner/admin/dispatcher/accountant. Confirmed applied via
 -- downstream evidence: migrations 0067/0068/0069/0070/0071 (also headed
 -- "PROPOSED ONLY") are treated as live, required preconditions by
 -- unambiguously-applied later migrations -- 0129 itself raises a STOP
 -- precondition exception if public.dispatch_financials (0067) is
 -- missing, and 0145 does the same for public.load_financials (0067) --
 -- and TEST_SUPPORT_0130_0133_schema.sql''s own header states its
 -- loads/dispatches shape is "post-0069/0115". The header text on
 -- 0066-0084 reflects their original drafting stage, not final status.
 select 'PRE0130_FINANCIAL_SELECT_ROLE_TOO_BROAD','platform','pre0130_financial_select_includes_driver_viewer','WARNING',(select case when not exists(select 1 from pg_trigger where tgname='profiles_protect_privileged_columns' and not tgisinternal) then 0 else (select count(*) filter(where too_broad) from (
   select t.tbl, exists(
     select 1 from pg_policies p where p.schemaname='public' and p.tablename=t.tbl and p.cmd='SELECT'
     and (p.qual ilike '%driver%' or p.qual not ilike '%has_role%')
   ) as too_broad
   from (values ('invoices'),('settlements'),('invoice_line_items'),('payments'),('settlement_line_items')) t(tbl)
   where to_regclass('public.'||t.tbl) is not null
 ) x) end)::bigint,'A legacy financial table''s SELECT policy does not restrict to owner/admin/dispatcher/accountant (migration 0066), instead permitting any org member including driver/viewer to read invoice/payment/settlement data directly.','Stop; apply migration 0066''s role-tiered SELECT policy.' union all
 -- Backstop CHECK/UNIQUE constraints, representative across organization
 -- identity (slug uniqueness), org-scoped uniqueness (load_number),
 -- default-exclusivity (platform_settings' singleton row), valid-state
 -- enumeration (loads.carrier_resolution), and monetary consistency
 -- (factored_invoices' nonnegative-amount/bounded-percentage family).
 select 'PRE0130_BACKSTOP_CONSTRAINT_MISSING','platform','pre0130_backstop_constraint_missing','WARNING',(select case when to_regclass('public.carrier_remittance_profiles') is null then 0 else (select count(*) filter(where missing) from (values
   ('organizations','organizations_slug_key'),
   ('loads','loads_organization_id_load_number_key'),
   ('loads','loads_carrier_resolution_values'),
   ('platform_settings','platform_settings_singleton'),
   ('factored_invoices','factored_invoices_invoice_face_value_check'),
   ('factored_invoices','factored_invoices_advance_percentage_check'),
   ('factored_invoices','factored_invoices_reserve_amount_check')
 ) t(tbl,con), lateral (select to_regclass('public.'||t.tbl) is not null and not exists(select 1 from pg_constraint c where c.conrelid=to_regclass('public.'||t.tbl) and c.conname=t.con) as missing) x) end)::bigint,'A documented pre-0130 uniqueness/valid-state/monetary-consistency backstop constraint is missing.','Stop; restore via the owning migration.' union all
 -- Row 8: "partial RLS, grants, constraints, functions, triggers, indexes,
 -- or enum state" -- a full case matrix requires INDEX and ENUM checks as
 -- their own distinguishable categories, not folded into the constraint
 -- check above (a UNIQUE constraint's backing index shares its name and is
 -- already covered there; this is a plain, non-constraint-backed index).
 select 'SCHEMA_INDEX_MISSING','schema','partial_installation_index','BLOCKER',(select count(*) from (values
   ('carrier_invoice_loads','idx_carrier_invoice_loads_invoice')
 ) t(tbl,idx) where to_regclass('public.'||t.tbl) is not null and not exists(select 1 from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relname=t.idx and c.relkind='i'))::bigint,'A documented 0130-0146 non-constraint-backed index is missing -- a partial single-migration installation signal distinct from a missing constraint.','Stop; restore via the owning migration.' union all
 select 'SCHEMA_ENUM_INCOMPLETE','schema','partial_installation_enum','BLOCKER',(select case when to_regtype('public.invoice_issuance_status') is null then 0 else (
   4 - (select count(*) from pg_enum e join pg_type t on t.oid=e.enumtypid where t.typname='invoice_issuance_status' and e.enumlabel in ('draft','ready_for_issue','issued','voided'))
 ) end)::bigint,'The invoice_issuance_status enum type exists but is missing one or more of its 4 documented values (draft/ready_for_issue/issued/voided) -- a partial single-migration installation signal.','Stop; restore the missing enum value via the owning migration (enum values cannot be dropped, only added -- this indicates 0142 was interrupted before its own CREATE TYPE completed).'
), findings as (select finding_id,section,check_name,severity,affected_count=0 ok,affected_count,details,remediation from raw),
totals as (select count(*) filter(where severity='BLOCKER' and not ok) blockers,count(*) filter(where severity='WARNING' and not ok) warnings,count(*) filter(where severity='INFO') informational,
 count(*) filter(where finding_id='SCHEMA_HISTORY_SHAPE' and not ok) unknowns from findings)
select finding_id,section,check_name,severity,ok,affected_count,details,remediation,
 null::text decision,null::int blocker_count,null::int warning_count,null::int informational_count,null::text required_next_action,'COMPLETE'::text audit_coverage_status
from findings
union all
select 'FINAL_DECISION','summary','overall_deployment_decision','INFO',blockers=0 and warnings=0,blockers+warnings,
 'Decision from the finding rows above. Audit coverage (manifest rows 1-107) is COMPLETE, but this is independent of deployment readiness -- known, permanently-documented BLOCKER-severity gaps remain unfixed by design in this audit-only phase (see the runbook''s preserved corrective-migration backlog).','Do not approve production while any BLOCKER-severity finding is non-zero, regardless of audit_coverage_status.',
 case when blockers>0 then 'BLOCKED' when unknowns>0 then 'SCHEMA_STATE_UNKNOWN' when warnings>0 then 'READY_WITH_WARNINGS' else 'READY' end,
 blockers::int,warnings::int,informational::int,
 case when blockers>0 then 'Stop and resolve blockers.' when unknowns>0 then 'Stop: identify the unrecognized history schema.' when warnings>0 then 'Review every warning.' else 'Continue package development; production approval prohibited.' end,
 'COMPLETE'
from totals order by finding_id;
rollback;
