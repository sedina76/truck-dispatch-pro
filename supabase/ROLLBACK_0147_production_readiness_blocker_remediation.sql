-- ============================================================================
-- ROLLBACK_0147_production_readiness_blocker_remediation.sql
--
-- *** CONTROLLED EMERGENCY ROLLBACK ONLY ***
-- Restoring the exact 0146 boundary means DELIBERATELY RE-INTRODUCING all
-- seven release BLOCKERs 0147 remediated: the unreachable classifier
-- branch, direct authenticated INSERT/DELETE on carrier_invoices, PUBLIC/
-- anon EXECUTE on update_carrier_invoice_draft / review_legacy_invoice_
-- carrier_migration / scan_legacy_invoices_for_carrier_migration, and the
-- null-identity fail-open in scan_legacy_invoices_for_carrier_migration.
-- A database this rollback has been run against is, by definition, back in
-- the BLOCKED state the Phase 3C.0 audit package documents and is NOT
-- suitable for production approval until 0147 (or an equivalent fix) is
-- re-applied. Use only for a genuine emergency roll-forward failure at the
-- exact 0146->0147 boundary, never as a routine deployment step.
--
-- Refuses if any row exists in either new idempotency table (proof that
-- create_carrier_invoice_draft()/delete_carrier_invoice_draft() actually
-- created/deleted real data since 0147 applied -- restoring the pre-0147
-- grant model while such state exists would leave real audit/idempotency
-- records behind objects this rollback is about to drop, and the created
-- invoice these RPCs may reference would become orphaned from its own
-- creation record). Refuses if a later migration (0148+) already exists.
-- Disposable-test-cluster use only -- never run against a real database.
-- ============================================================================
begin;

-- ======================= PRECONDITIONS / REFUSAL ============================
do $rb$
declare
  v_create_idem_count integer;
  v_delete_idem_count integer;
  v_later_migration_count integer;
begin
  if to_regprocedure('public.create_carrier_invoice_draft(public.invoice_document_type,uuid,public.invoice_recipient_type,uuid,uuid,text,integer,date,text,text,text)') is null then
    raise exception 'ROLLBACK_0147: create_carrier_invoice_draft(...) does not exist -- 0147 does not appear to be applied. STOP.';
  end if;

  select count(*) into v_create_idem_count from public.carrier_invoice_draft_create_idempotency;
  if v_create_idem_count > 0 then
    raise exception 'ROLLBACK_0147 refused: % row(s) exist in carrier_invoice_draft_create_idempotency -- create_carrier_invoice_draft() has created real carrier_invoices rows since 0147 applied. Dropping this table would destroy that idempotency/audit trail, and restoring the pre-0147 direct-grant model would leave those rows behind a security posture that never accounted for them. Refusing to guess whether that is safe. Resolve manually (e.g. keep 0147 applied) before attempting this rollback again. STOP.', v_create_idem_count;
  end if;

  select count(*) into v_delete_idem_count from public.carrier_invoice_draft_delete_idempotency;
  if v_delete_idem_count > 0 then
    raise exception 'ROLLBACK_0147 refused: % row(s) exist in carrier_invoice_draft_delete_idempotency -- delete_carrier_invoice_draft() has deleted real carrier_invoices rows since 0147 applied. Dropping this table would destroy that audit trail. Refusing to guess whether that is safe. Resolve manually (e.g. keep 0147 applied) before attempting this rollback again. STOP.', v_delete_idem_count;
  end if;

  select count(*) into v_later_migration_count
  from pg_proc
  where pronamespace = 'public'::regnamespace
    and proname ~ '_01(4[8-9]|[5-9][0-9])_';
  if v_later_migration_count > 0 then
    raise exception 'ROLLBACK_0147 refused: % object(s) matching a later migration''s naming convention were found -- a dependent migration may already be applied on top of 0147. Refusing to roll back underneath it. STOP.', v_later_migration_count;
  end if;

  raise notice 'ROLLBACK_0147 preconditions passed. Zero rows in either new idempotency table, no later migration detected. Proceeding to restore the exact 0146 boundary (re-introducing all seven remediated BLOCKERs).';
end
$rb$;

-- ======================= RESTORE PHASE 6 (drop 0147-only objects) ==========
drop function if exists public.delete_carrier_invoice_draft(uuid,timestamptz,text,text);
drop function if exists public.create_carrier_invoice_draft(public.invoice_document_type,uuid,public.invoice_recipient_type,uuid,uuid,text,integer,date,text,text,text);
drop table if exists public.carrier_invoice_draft_delete_idempotency;
drop table if exists public.carrier_invoice_draft_create_idempotency;

-- ======================= RESTORE PHASE 5 (carrier_invoices direct writes) ==
grant insert, delete on public.carrier_invoices to authenticated;

create policy carrier_invoices_insert
  on public.carrier_invoices for insert
  with check (
    organization_id = public.current_org_id()
    and (
      public.has_role(array['owner', 'admin', 'accountant']::public.org_role[])
      or (public.has_role(array['dispatcher']::public.org_role[]) and issuance_status = 'draft')
    )
  );

create policy carrier_invoices_delete
  on public.carrier_invoices for delete
  using (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin', 'accountant']::public.org_role[])
  );

comment on table public.carrier_invoices is
  'Phase 3B.3A foundation (3B.3A.1 correction: issuance/payment state split into two independent columns). NEW, additive invoice-document model, entirely independent of the legacy public.invoices table (single-carrier era). carrier_id is always the carrier-side party (issuer for carrier_freight_invoice, billed recipient for dispatch_service_invoice). No issuance or payment RPC references this table yet (0143+).';

-- ======================= RESTORE PHASE 4 (PUBLIC/anon EXECUTE) =============
grant execute on function public.update_carrier_invoice_draft(uuid,jsonb,timestamptz,text,text) to public;
grant execute on function public.review_legacy_invoice_carrier_migration(uuid,text,text,timestamptz,text) to public;
grant execute on function public.scan_legacy_invoices_for_carrier_migration() to public;

-- ======================= RESTORE PHASE 3 (0142's original scan body) =======
create or replace function public.scan_legacy_invoices_for_carrier_migration()
returns integer
language plpgsql
security definer
set search_path = pg_catalog, public
as $fn$
declare
  v_row record;
  v_classification text;
  v_count integer := 0;
begin
  if not public.has_role(array['owner', 'admin']::public.org_role[]) then
    raise exception 'scan_legacy_invoices_for_carrier_migration: owner or admin only.' using errcode = '42501';
  end if;

  for v_row in select id, organization_id from public.invoices where organization_id = public.current_org_id() loop
    v_classification := public.classify_legacy_invoice_for_carrier_migration(v_row.id);
    insert into public.legacy_invoice_carrier_migration_review (organization_id, legacy_invoice_id, classification)
    values (v_row.organization_id, v_row.id, v_classification)
    on conflict (legacy_invoice_id) do update set classification = excluded.classification, updated_at = now();
    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$fn$;

comment on function public.scan_legacy_invoices_for_carrier_migration() is
  'Owner/admin only, explicitly invoked (never automatic). Classifies every existing public.invoices row in the caller''s organization via classify_legacy_invoice_for_carrier_migration() and upserts the result into legacy_invoice_carrier_migration_review. Writes ONLY that review table -- public.invoices itself is read-only here, never mutated.';

-- ======================= RESTORE PHASE 2 (0142's original classifier) ======
create or replace function public.classify_legacy_invoice_for_carrier_migration(p_invoice_id uuid)
returns text
language plpgsql
stable
security definer
set search_path = pg_catalog, public
as $fn$
declare
  v_inv record;
  v_load record;
  v_factored_count integer;
begin
  select id, organization_id, status, load_id, broker_id, customer_id, amount_paid, total_amount
    into v_inv
  from public.invoices where id = p_invoice_id;
  if v_inv.id is null then
    return 'not_found';
  end if;

  if v_inv.status = 'void' then
    return 'voided_cancelled';
  end if;
  if v_inv.status = 'paid' or (v_inv.amount_paid > 0 and v_inv.amount_paid < v_inv.total_amount) then
    return 'paid_or_partially_paid';
  end if;

  select count(*) into v_factored_count from public.factored_invoices where invoice_id = p_invoice_id;
  if v_factored_count > 0 then
    return 'existing_factoring_activity';
  end if;

  if v_inv.broker_id is not null and v_inv.customer_id is not null then
    return 'conflicting_recipient_evidence';
  end if;
  if v_inv.broker_id is null and v_inv.customer_id is null then
    return 'missing_recipient';
  end if;

  if v_inv.load_id is null then
    -- No load to derive a carrier from at all, and this legacy schema
    -- never stored carrier_id directly on invoices -- there is genuinely
    -- no carrier evidence to look at.
    return 'missing_carrier_evidence';
  end if;

  select carrier_id, carrier_resolution into v_load from public.loads where id = v_inv.load_id;
  if v_load.carrier_id is null then
    return 'missing_carrier_evidence';
  end if;
  if v_load.carrier_resolution = 'conflicting' then
    return 'conflicting_carrier_evidence';
  end if;
  if v_load.carrier_resolution = 'unresolved' then
    return 'missing_carrier_evidence';
  end if;

  return 'safely_identifiable_legacy';
end;
$fn$;

comment on function public.classify_legacy_invoice_for_carrier_migration(uuid) is
  'Read-only. Classifications: not_found, voided_cancelled, paid_or_partially_paid, existing_factoring_activity, conflicting_recipient_evidence, missing_recipient, missing_carrier_evidence, conflicting_carrier_evidence, safely_identifiable_legacy. Never mutates public.invoices. "safely_identifiable_legacy" still means LEGACY -- ineligible for the new factoring workflow until explicitly reviewed and reissued (Section J).';

revoke all on function public.classify_legacy_invoice_for_carrier_migration(uuid) from public, anon, authenticated;

-- ======================= POSTCONDITIONS ====================================
do $rb$
begin
  if to_regprocedure('public.create_carrier_invoice_draft(public.invoice_document_type,uuid,public.invoice_recipient_type,uuid,uuid,text,integer,date,text,text,text)') is not null
     or to_regprocedure('public.delete_carrier_invoice_draft(uuid,timestamptz,text,text)') is not null then
    raise exception 'ROLLBACK_0147 postcondition: a 0147-only RPC still exists.';
  end if;
  if to_regclass('public.carrier_invoice_draft_create_idempotency') is not null
     or to_regclass('public.carrier_invoice_draft_delete_idempotency') is not null then
    raise exception 'ROLLBACK_0147 postcondition: a 0147-only idempotency table still exists.';
  end if;
  if not has_table_privilege('authenticated', 'public.carrier_invoices', 'INSERT')
     or not has_table_privilege('authenticated', 'public.carrier_invoices', 'DELETE') then
    raise exception 'ROLLBACK_0147 postcondition: authenticated does not have the exact 0146 direct INSERT/DELETE grant on carrier_invoices.';
  end if;
  if not exists (select 1 from pg_policies where schemaname='public' and tablename='carrier_invoices' and policyname='carrier_invoices_insert')
     or not exists (select 1 from pg_policies where schemaname='public' and tablename='carrier_invoices' and policyname='carrier_invoices_delete') then
    raise exception 'ROLLBACK_0147 postcondition: carrier_invoices_insert/delete policy was not restored.';
  end if;
  if not has_function_privilege('anon', 'public.update_carrier_invoice_draft(uuid,jsonb,timestamptz,text,text)', 'EXECUTE')
     or not has_function_privilege('anon', 'public.review_legacy_invoice_carrier_migration(uuid,text,text,timestamptz,text)', 'EXECUTE')
     or not has_function_privilege('anon', 'public.scan_legacy_invoices_for_carrier_migration()', 'EXECUTE') then
    raise exception 'ROLLBACK_0147 postcondition: anon EXECUTE was not restored on the exact 0146 boundary for one of the three RPCs.';
  end if;
  if (select prosrc from pg_proc where proname = 'classify_legacy_invoice_for_carrier_migration' and pronamespace = 'public'::regnamespace) not ilike '%carrier_resolution = ''conflicting''%' then
    raise exception 'ROLLBACK_0147 postcondition: classify_legacy_invoice_for_carrier_migration was not restored to its exact 0146 (0142-original) body.';
  end if;
  if (select prosrc from pg_proc where proname = 'scan_legacy_invoices_for_carrier_migration' and pronamespace = 'public'::regnamespace) ilike '%auth.uid() is null%' then
    raise exception 'ROLLBACK_0147 postcondition: scan_legacy_invoices_for_carrier_migration was not restored to its exact 0146 (0142-original) body.';
  end if;
  if (select count(*) from pg_proc where proname = 'classify_legacy_invoice_for_carrier_migration' and pronamespace = 'public'::regnamespace) <> 1
     or (select count(*) from pg_proc where proname = 'scan_legacy_invoices_for_carrier_migration' and pronamespace = 'public'::regnamespace) <> 1 then
    raise exception 'ROLLBACK_0147 postcondition: unexpected overload count after restoration.';
  end if;

  raise notice 'ROLLBACK_0147 complete: exact 0146 boundary restored. WARNING: all seven Phase 3C.0 release BLOCKERs are re-introduced by design -- this database is BLOCKED and unsuitable for production approval until 0147 (or an equivalent fix) is re-applied.';
end
$rb$;

commit;
