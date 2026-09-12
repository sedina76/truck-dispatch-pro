-- ############################################################################
-- ##  MANUAL EMERGENCY ROLLBACK -- 0140_factoring_authorization_and_        ##
-- ##  submission_safety.sql                                                 ##
-- ##                                                                        ##
-- ##  DO NOT RUN unless a decision has been made to reverse 0140.            ##
-- ##  APPLY AS ONE TRANSACTION.                                             ##
-- ##                                                                        ##
-- ##  0140 is purely a POLICY + FUNCTION-BODY change -- no table, column,   ##
-- ##  or index was added. This rollback restores the exact pre-0140 RLS    ##
-- ##  policies (0071's own originals -- FINANCIAL_ROLES for company/       ##
-- ##  relationship create/update/delete), restores submit_invoice_to_       ##
-- ##  factor() to its exact 0075 signature/return type/body/grant/comment, ##
-- ##  and removes the objects 0140 introduced (its two table comments).     ##
-- ##                                                                        ##
-- ##  DATA LOSS: none. No row is deleted or rewritten by this script.       ##
-- ##  Reversing this migration WIDENS authorization back to the pre-3B.1.4  ##
-- ##  state (dispatcher/accountant may again create factoring companies/   ##
-- ##  relationships; submission loses its carrier-scoped safety gate) --   ##
-- ##  confirm that is actually the intended outcome before running this.   ##
-- ##                                                                        ##
-- ##  Phase 3B.1.6 (Section D) EXPLICIT DECISION on                         ##
-- ##  approve_factoring_relationship_noa() -- read this before running:     ##
-- ##                                                                        ##
-- ##  0140's fix to this function (two plain nullable variables replacing  ##
-- ##  an unconditionally-referenced `record` variable) corrects a REAL,    ##
-- ##  REPRODUCED bug in 0139's own version: calling it with                ##
-- ##  p_noa_document_id = null -- a template-only approval, an explicitly  ##
-- ##  DOCUMENTED and SUPPORTED call shape per the function's own           ##
-- ##  validation ("either approved template language or an approved        ##
-- ##  document reference is required") -- raises a genuine Postgres         ##
-- ##  runtime error ("record v_doc is not assigned yet"), reproduced live  ##
-- ##  via this project's own two-session concurrency tests.                ##
-- ##                                                                        ##
-- ##  Restoring 0139's EXACT original body here would deliberately          ##
-- ##  reintroduce that crash into a live environment on a documented,       ##
-- ##  valid input -- this is DEMONSTRABLY UNSAFE, not a judgment call, and  ##
-- ##  the preferred "restore everything exactly" correction is REFUSED     ##
-- ##  for this one function alone. This is a DOCUMENTED, VERIFIED,         ##
-- ##  structural decision -- not a silent partial rollback:                ##
-- ##    (1) this header states the reason in full;                         ##
-- ##    (2) the postcondition block below does not merely assume the       ##
-- ##        fixed version survives -- it INSPECTS pg_proc.prosrc and       ##
-- ##        RAISES if the fix is not present, so this script can never     ##
-- ##        silently leave an unknown or reverted state;                   ##
-- ##    (3) the fix is NOT re-applied by this script either (it is never   ##
-- ##        removed by anything else in this rollback, so there is        ##
-- ##        nothing to "re-apply" -- it simply is never reversed).         ##
-- ##  A persistent hotfix that must survive this migration's own rollback  ##
-- ##  is exactly what this is -- and per this phase's own instruction, a   ##
-- ##  fix of this kind belongs in its own explicitly ordered migration     ##
-- ##  with its own rollback policy, not folded silently into an            ##
-- ##  unrelated one. It was folded into 0140 (rather than a new 0141) only ##
-- ##  because 0140 itself was still uncommitted/unapplied at the time the  ##
-- ##  bug was found (Phase 3B.1.5) -- once 0140 is committed and applied,  ##
-- ##  any FUTURE bug of this kind must get its own migration number, never ##
-- ##  another undocumented ride-along inside an unrelated rollback.        ##
-- ############################################################################

begin;

-- --- Guard 0: this exact 0140 migration was applied -----------------------
do $rb$
begin
  if not exists (
    select 1 from pg_policies where schemaname='public' and tablename='factoring_relationships' and policyname='factoring_relationships_update'
      and qual ilike '%accountant%' and qual not ilike '%dispatcher%'
  ) then
    raise exception 'ROLLBACK 0140: factoring_relationships_update does not look like 0140''s owner/admin/accountant policy -- 0140 does not appear to be applied. STOP.';
  end if;
end
$rb$;

-- --- Guard 1: refuse if a later (invoice-issuance) migration is live -------
-- 0140's own header/body comments name the exact future dependency: a
-- database-issued carrier/financial snapshot marker on invoices (e.g.
-- invoices.carrier_factoring_snapshot_id), which a future invoice-issuance
-- migration would add and which would then REPLACE submit_invoice_to_
-- factor()'s unconditional rejection with a real marker-presence check.
-- If any such column already exists, a later migration has almost
-- certainly built on 0140's jsonb-returning contract, and rolling 0140
-- back underneath it (restoring the old table(...)-returning signature)
-- would silently break that later migration's own callers. Refuse rather
-- than guess.
do $rb$
begin
  if exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'invoices' and column_name like 'carrier_factoring_snapshot%'
  ) then
    raise exception 'ROLLBACK 0140: invoices already carries a carrier/financial snapshot column -- a later (invoice-issuance) migration appears to depend on 0140''s submit_invoice_to_factor() contract. Refusing to roll back 0140 underneath it. STOP -- write a forward migration instead.';
  end if;
  if to_regprocedure('public.submit_invoice_to_factor(uuid,uuid,uuid)') is not null then
    raise exception 'ROLLBACK 0140: an overload of submit_invoice_to_factor with an additional parameter already exists -- a later migration appears to depend on it. Refusing to roll back 0140 underneath it. STOP.';
  end if;
end
$rb$;

-- --- A. restore 0071's original FINANCIAL_ROLES policies -------------------
drop policy if exists factoring_companies_insert on public.factoring_companies;
create policy factoring_companies_insert on public.factoring_companies
  for insert with check (organization_id = public.current_org_id() and public.has_role(array['owner','admin','dispatcher','accountant']::public.org_role[]));

drop policy if exists factoring_companies_update on public.factoring_companies;
create policy factoring_companies_update on public.factoring_companies
  for update using (organization_id = public.current_org_id() and public.has_role(array['owner','admin','dispatcher','accountant']::public.org_role[]))
  with check (organization_id = public.current_org_id());

drop policy if exists factoring_companies_delete on public.factoring_companies;
create policy factoring_companies_delete on public.factoring_companies
  for delete using (organization_id = public.current_org_id() and public.has_role(array['owner','admin','dispatcher','accountant']::public.org_role[]));

drop policy if exists factoring_relationships_insert on public.factoring_relationships;
create policy factoring_relationships_insert on public.factoring_relationships
  for insert with check (organization_id = public.current_org_id() and public.has_role(array['owner','admin','dispatcher','accountant']::public.org_role[]));

drop policy if exists factoring_relationships_update on public.factoring_relationships;
create policy factoring_relationships_update on public.factoring_relationships
  for update using (organization_id = public.current_org_id() and public.has_role(array['owner','admin','dispatcher','accountant']::public.org_role[]))
  with check (organization_id = public.current_org_id());

drop policy if exists factoring_relationships_delete on public.factoring_relationships;
create policy factoring_relationships_delete on public.factoring_relationships
  for delete using (organization_id = public.current_org_id() and public.has_role(array['owner','admin','dispatcher','accountant']::public.org_role[]));

-- 0140 introduced these two table comments -- removing them is "removing
-- only the objects 0140 introduced" for this part of the migration.
comment on table public.factoring_companies is null;
comment on table public.factoring_relationships is null;

-- --- B. approve_factoring_relationship_noa(): DELIBERATELY NOT REVERSED ----
-- See the header above in full. No DDL runs against this function here --
-- this section exists only so the postcondition block below has something
-- explicit to verify (it does not rely on "nothing touched it" being true
-- by default; it actually inspects the live function and raises if the
-- fix is somehow absent).

-- --- C. restore submit_invoice_to_factor() to its exact 0075 body --------
-- Phase 3B.1.5 changed this function's return type (table(...) -> jsonb);
-- Postgres cannot CREATE OR REPLACE across a return-type change, so the
-- jsonb-returning version must be dropped first.
drop function if exists public.submit_invoice_to_factor(uuid, uuid);

create function public.submit_invoice_to_factor(
  p_invoice_id uuid,
  p_relationship_id uuid
)
returns table (factored_invoice_id uuid, status public.factored_invoice_status)
language plpgsql
security invoker
as $$
declare
  v_org_id uuid;
  v_invoice record;
  v_relationship record;
  v_company_active boolean;
  v_existing_active uuid;
  v_face_value numeric(10, 2);
  v_advance_amount numeric(10, 2);
  v_fee_amount numeric(10, 2);
  v_reserve_amount numeric(10, 2);
  v_other_fees numeric(10, 2);
  v_funding_amount numeric(10, 2);
  v_new_id uuid;
begin
  v_org_id := public.current_org_id();
  if v_org_id is null then
    raise exception 'No organization on this account.';
  end if;

  if not public.has_role(array['owner', 'admin', 'dispatcher', 'accountant']::public.org_role[]) then
    raise exception 'You do not have permission to submit invoices for factoring.';
  end if;

  perform pg_advisory_xact_lock(hashtext('factoring_submission:' || p_invoice_id::text));

  select inv.id, inv.organization_id, inv.status, inv.total_amount, inv.amount_paid
    into v_invoice
  from public.invoices inv
  where inv.id = p_invoice_id;

  if v_invoice.id is null or v_invoice.organization_id <> v_org_id then
    raise exception 'Invoice not found.';
  end if;

  if v_invoice.status not in ('sent', 'viewed') or v_invoice.amount_paid <> 0 then
    raise exception 'This invoice is not eligible for factoring.';
  end if;

  select fi.id into v_existing_active
  from public.factored_invoices fi
  where fi.invoice_id = p_invoice_id and fi.status not in ('rejected', 'cancelled')
  limit 1;
  if v_existing_active is not null then
    raise exception 'This invoice has already been submitted to a factor.';
  end if;

  select rel.id, rel.organization_id, rel.factoring_company_id, rel.is_active,
         rel.default_advance_percentage, rel.default_factoring_fee_percentage, rel.default_reserve_percentage,
         rel.fee_timing, rel.other_fee_default, rel.effective_from, rel.effective_to
    into v_relationship
  from public.factoring_relationships rel
  where rel.id = p_relationship_id
  for update;

  if v_relationship.id is null or v_relationship.organization_id <> v_org_id then
    raise exception 'This factoring relationship is not available.';
  end if;
  if not v_relationship.is_active then
    raise exception 'The selected factoring relationship is inactive.';
  end if;
  if v_relationship.effective_from > current_date or (v_relationship.effective_to is not null and v_relationship.effective_to < current_date) then
    raise exception 'The selected factoring relationship is not currently effective.';
  end if;

  select comp.is_active into v_company_active
  from public.factoring_companies comp
  where comp.id = v_relationship.factoring_company_id;
  if not coalesce(v_company_active, false) then
    raise exception 'The selected factoring company is inactive.';
  end if;

  v_face_value := v_invoice.total_amount;
  v_advance_amount := round(v_face_value * v_relationship.default_advance_percentage / 100, 2);
  v_fee_amount := round(v_face_value * v_relationship.default_factoring_fee_percentage / 100, 2);
  v_reserve_amount := round(v_face_value * v_relationship.default_reserve_percentage / 100, 2);
  v_other_fees := coalesce(v_relationship.other_fee_default, 0);
  v_funding_amount := v_advance_amount - v_other_fees - (case when v_relationship.fee_timing = 'deducted_at_funding' then v_fee_amount else 0 end);

  if v_funding_amount < 0 then
    raise exception 'Estimated funding amount for this invoice would be negative under the selected relationship''s terms.';
  end if;

  insert into public.factored_invoices (
    organization_id, invoice_id, factoring_company_id, factoring_relationship_id,
    status, submitted_at, submitted_by,
    invoice_face_value, advance_percentage, expected_advance_amount,
    factoring_fee_percentage, factoring_fee_amount,
    reserve_percentage, reserve_amount,
    other_fees, fee_timing, expected_funding_amount
  ) values (
    v_org_id, p_invoice_id, v_relationship.factoring_company_id, p_relationship_id,
    'submitted', now(), auth.uid(),
    v_face_value, v_relationship.default_advance_percentage, v_advance_amount,
    v_relationship.default_factoring_fee_percentage, v_fee_amount,
    v_relationship.default_reserve_percentage, v_reserve_amount,
    v_other_fees, v_relationship.fee_timing, v_funding_amount
  )
  returning id into v_new_id;

  insert into public.factoring_events (
    organization_id, factored_invoice_id, event_type, from_status, to_status, performed_by
  ) values (
    v_org_id, v_new_id, 'submitted', null, 'submitted', auth.uid()
  );

  return query select v_new_id, 'submitted'::public.factored_invoice_status;
end;
$$;

grant execute on function public.submit_invoice_to_factor(uuid, uuid) to authenticated;
comment on function public.submit_invoice_to_factor(uuid, uuid) is null;

-- --- Guard: postconditions -- prove the 0139 boundary, not just "no error" -
do $rb$
declare
  v_data_type text;
  v_noa_src text;
begin
  -- A. authorization matrix restored to 0071's FINANCIAL_ROLES shape on
  -- BOTH tables, all four operations. An INSERT policy has NO `qual`
  -- (USING) -- only `with_check` is ever populated for INSERT; reading
  -- `qual` for it compares against NULL, which a plpgsql IF silently
  -- treats as false (no exception raised) regardless of the policy's
  -- real content -- so `_insert` is checked via `with_check` below, the
  -- column that actually holds its rule. `_update`/`_delete` correctly
  -- read `qual` (their own USING clause).
  if (select with_check from pg_policies where schemaname='public' and tablename='factoring_companies' and policyname='factoring_companies_insert') not ilike '%dispatcher%'
    or (select qual from pg_policies where schemaname='public' and tablename='factoring_companies' and policyname='factoring_companies_update') not ilike '%dispatcher%'
    or (select qual from pg_policies where schemaname='public' and tablename='factoring_companies' and policyname='factoring_companies_delete') not ilike '%dispatcher%'
  then
    raise exception 'ROLLBACK 0140 postcondition: factoring_companies policies do not look restored to 0071''s FINANCIAL_ROLES shape.';
  end if;
  if (select with_check from pg_policies where schemaname='public' and tablename='factoring_relationships' and policyname='factoring_relationships_insert') not ilike '%dispatcher%'
    or (select qual from pg_policies where schemaname='public' and tablename='factoring_relationships' and policyname='factoring_relationships_update') not ilike '%dispatcher%'
    or (select qual from pg_policies where schemaname='public' and tablename='factoring_relationships' and policyname='factoring_relationships_delete') not ilike '%dispatcher%'
  then
    raise exception 'ROLLBACK 0140 postcondition: factoring_relationships policies do not look restored to 0071''s FINANCIAL_ROLES shape.';
  end if;
  if coalesce(obj_description('public.factoring_companies'::regclass, 'pg_class'), '') <> '' then
    raise exception 'ROLLBACK 0140 postcondition: factoring_companies still carries a table comment 0140 introduced.';
  end if;
  if coalesce(obj_description('public.factoring_relationships'::regclass, 'pg_class'), '') <> '' then
    raise exception 'ROLLBACK 0140 postcondition: factoring_relationships still carries a table comment 0140 introduced.';
  end if;

  -- C. submit_invoice_to_factor genuinely back to its exact 0075 shape:
  -- signature (table return -- reported as 'record' by information_schema
  -- for a RETURNS TABLE function), grant, and a null comment.
  if to_regprocedure('public.submit_invoice_to_factor(uuid,uuid)') is null then
    raise exception 'ROLLBACK 0140 postcondition: submit_invoice_to_factor(uuid,uuid) missing after restore.';
  end if;
  select data_type into v_data_type
  from information_schema.routines
  where routine_schema = 'public' and routine_name = 'submit_invoice_to_factor'
  limit 1;
  if v_data_type is distinct from 'record' then
    raise exception 'ROLLBACK 0140 postcondition: submit_invoice_to_factor does not report as a table(record)-returning function (found %) -- the 0140 jsonb signature may still be live.', v_data_type;
  end if;
  if not has_function_privilege('authenticated', 'public.submit_invoice_to_factor(uuid,uuid)', 'EXECUTE') then
    raise exception 'ROLLBACK 0140 postcondition: authenticated lost EXECUTE on submit_invoice_to_factor.';
  end if;
  if coalesce(obj_description('public.submit_invoice_to_factor(uuid,uuid)'::regprocedure, 'pg_proc'), '') <> '' then
    raise exception 'ROLLBACK 0140 postcondition: submit_invoice_to_factor still carries a comment 0140 introduced.';
  end if;
  if (select prosrc from pg_proc where proname = 'submit_invoice_to_factor' and pronamespace = 'public'::regnamespace) ilike '%CARRIER_INVOICE_SNAPSHOT_REQUIRED%' then
    raise exception 'ROLLBACK 0140 postcondition: submit_invoice_to_factor source still references the 0140 rejection code.';
  end if;

  -- B. approve_factoring_relationship_noa(): explicitly VERIFY the fix
  -- remains in place -- this rollback never silently leaves an unknown
  -- state either way (see header).
  select prosrc into v_noa_src from pg_proc where proname = 'approve_factoring_relationship_noa' and pronamespace = 'public'::regnamespace;
  if v_noa_src is null then
    raise exception 'ROLLBACK 0140 postcondition: approve_factoring_relationship_noa is missing entirely -- STOP, environment is inconsistent.';
  end if;
  if v_noa_src not ilike '%v_doc_snapshot_file_name%' or v_noa_src not ilike '%v_doc_snapshot_file_path%' then
    raise exception 'ROLLBACK 0140 postcondition: approve_factoring_relationship_noa no longer contains the 0140 bug fix (v_doc_snapshot_file_name/path) -- it may have been reverted to 0139''s known-buggy version out of band. STOP and investigate before proceeding; this rollback deliberately never reintroduces that bug.';
  end if;

  raise notice 'ROLLBACK 0140 complete: factoring_companies/factoring_relationships RLS restored to 0071''s original FINANCIAL_ROLES policies (both table comments cleared); submit_invoice_to_factor() restored to its exact 0075 signature/body/grant/comment (no carrier gate, no jsonb). approve_factoring_relationship_noa() DELIBERATELY NOT reversed and verified still fixed -- reverting it would reintroduce a demonstrated crash on a documented, valid input (see this script''s own header).';
end
$rb$;

commit;
