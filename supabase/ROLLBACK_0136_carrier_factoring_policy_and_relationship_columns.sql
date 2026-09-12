-- ============================================================================
-- ROLLBACK_0136_carrier_factoring_policy_and_relationship_columns.sql
--
-- Reverses 0136 ONLY: drops the new factoring_relationships columns/
-- constraints/triggers and carriers.factoring_mode, restores
-- guard_factoring_relationship_org() to its 0071 (INSERT-only, no
-- carrier/document/integration checks) form.
--
-- KNOWN, DISCLOSED, PERMANENT LIMITATION: this rollback CANNOT remove the
-- 'factoring_api' value added to the public.integration_provider enum --
-- Postgres has no DROP VALUE for enum types. The orphaned enum value is
-- harmless (no row will reference it once submission_integration_id/
-- submission_method are dropped below) and does not need to be removed
-- for 0136 to be considered fully rolled back; it simply remains available
-- for reuse if 0136 is re-applied later.
--
-- IMPORTANT: only run this if 0136 itself must be reversed. 0137/0138 (if
-- applied) must be rolled back FIRST, in reverse order -- this script
-- assumes neither has been applied (it will fail its own precondition
-- otherwise, since 0137/0138 add their own dependents on these columns).
--
-- STRUCTURE: explicit BEGIN/COMMIT.
-- ============================================================================

begin;

do $mig$
begin
  if not exists (select 1 from information_schema.columns where table_schema='public' and table_name='factoring_relationships' and column_name='carrier_id') then
    raise exception 'ROLLBACK 0136 precondition: factoring_relationships.carrier_id does not exist -- 0136 was never applied, or already rolled back. STOP.';
  end if;
  if to_regprocedure('public.classify_carrier_factoring_readiness(uuid,uuid,uuid)') is not null then
    raise exception 'ROLLBACK 0136 precondition: 0138''s classifier still exists -- roll back 0138 (and 0137, if applied) BEFORE this one. STOP.';
  end if;
end
$mig$;

-- Restore 0071's original guard (INSERT-only, no carrier/document/
-- integration validation) before dropping the columns it now references,
-- so no dangling reference to a soon-to-be-dropped column remains.
create or replace function public.guard_factoring_relationship_org()
returns trigger
language plpgsql
as $$
declare
  v_company_org uuid;
begin
  select organization_id into v_company_org from public.factoring_companies where id = new.factoring_company_id;
  if v_company_org is null or v_company_org <> new.organization_id then
    raise exception 'Factoring relationship must reference a factoring company in the same organization.';
  end if;
  return new;
end;
$$;

drop trigger if exists factoring_relationships_guard_org on public.factoring_relationships;
create trigger factoring_relationships_guard_org
  before insert on public.factoring_relationships
  for each row execute function public.guard_factoring_relationship_org();

drop trigger if exists factoring_relationships_guard_protected_fields on public.factoring_relationships;
drop function if exists public.guard_factoring_relationship_protected_fields();

alter table public.factoring_relationships
  drop constraint if exists factoring_relationships_noa_approval_complete,
  drop constraint if exists factoring_relationships_submission_email_present,
  drop constraint if exists factoring_relationships_submission_integration_present;

alter table public.factoring_relationships
  drop column if exists carrier_id,
  drop column if exists remittance_instructions,
  drop column if exists remittance_reference,
  drop column if exists noa_template_text,
  drop column if exists noa_document_id,
  drop column if exists noa_reference,
  drop column if exists noa_effective_date,
  drop column if exists noa_approved,
  drop column if exists noa_approved_by,
  drop column if exists noa_approved_at,
  drop column if exists submission_method,
  drop column if exists submission_destination_email,
  drop column if exists submission_integration_id,
  drop column if exists submission_notes;

alter table public.carriers drop column if exists factoring_mode;

drop type if exists public.factoring_submission_method;
drop type if exists public.carrier_factoring_mode;
-- public.integration_provider's 'factoring_api' value is NOT removed --
-- see header comment (Postgres cannot drop an enum value).

do $mig$
begin
  if exists (select 1 from information_schema.columns where table_schema='public' and table_name='factoring_relationships' and column_name='carrier_id') then
    raise exception 'ROLLBACK 0136 postcondition: factoring_relationships.carrier_id still exists.';
  end if;
  if exists (select 1 from information_schema.columns where table_schema='public' and table_name='carriers' and column_name='factoring_mode') then
    raise exception 'ROLLBACK 0136 postcondition: carriers.factoring_mode still exists.';
  end if;
  if to_regtype('public.carrier_factoring_mode') is not null then
    raise exception 'ROLLBACK 0136 postcondition: type public.carrier_factoring_mode still exists.';
  end if;
  if not exists (
    select 1 from pg_trigger where tgname='factoring_relationships_guard_org' and tgrelid='public.factoring_relationships'::regclass and not tgisinternal
  ) then
    raise exception 'ROLLBACK 0136 postcondition: factoring_relationships_guard_org trigger missing -- must be restored to its 0071 form, not removed entirely.';
  end if;
  raise notice 'ROLLBACK 0136 complete: carriers.factoring_mode + factoring_relationships'' carrier_id/remittance/NOA/submission columns removed; guard_factoring_relationship_org() restored to its 0071 (INSERT-only) form; the new protected-fields guard removed. 0071/0072''s tables, indexes, and RPC untouched throughout. integration_provider''s ''factoring_api'' value remains (Postgres cannot drop an enum value) -- harmless, disclosed above.';
end
$mig$;

commit;
