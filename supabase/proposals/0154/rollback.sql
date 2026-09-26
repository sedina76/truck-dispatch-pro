-- rollback.sql -- EMERGENCY reversal of proposal 0154 (re-introduces the F-05 exposure)
-- PROPOSAL 0154 -- NOT APPROVED FOR PRODUCTION. NOT APPLIED. NOT A PRODUCTION MIGRATION (lives under supabase/proposals/, not supabase/migrations/).
-- Sequencing: 0130..0147 -> 0149 -> 0150 -> 0151 -> 0152 -> 0154 (this) -> 0155 -> 0156. Numbers 0154-0156 are taken by the blocker proposals; the unrelated proposal 0148 MUST be
-- renumbered to 0153 (unused) or to 0157 or higher before promotion -- never to 0154, 0155 or 0156. Finding F-05 of ADVERSARIAL_REVIEW.md.
-- Restores the EXACT 0130 definition (extracted from the migration) and the ACL 0130 itself declared (revoke PUBLIC, grant authenticated). NOTE: that ACL is the intended 0130 state, not the accidental
-- default-privilege exposure to anon/service_role. REFUSES (changing nothing) unless the live functions are exactly the reviewed 0154 definitions AND proposal 0155 (which depends on the trusted
-- writer) is not applied. Drops only the trusted function. Single transaction; run once.
begin;
set local lock_timeout = '15s';
do $mig$
begin
  if to_regprocedure('public._record_unresolved_carrier_record_trusted(uuid,text,uuid,text,jsonb)') is null then raise exception 'ROLLBACK 0154 REFUSED: trusted writer missing (0154 not applied, or already rolled back). Nothing changed.'; end if;
  if (select md5(regexp_replace(lower(regexp_replace(prosrc, '--[^\n]*', '', 'g')), '\s+', '', 'g')) from pg_proc where oid = to_regprocedure('public.record_unresolved_carrier_record(uuid,text,uuid,text,jsonb)')) is distinct from 'c7f9a4c2c34fc44639b2ee96cd348c4e' then raise exception 'ROLLBACK 0154 REFUSED: live record_unresolved_carrier_record is not the reviewed 0154 definition. Nothing changed.'; end if;
  if to_regclass('public.carrier_inference_review_0155') is not null then raise exception 'ROLLBACK 0154 REFUSED: proposal 0155 is applied and depends on the trusted writer -- roll back 0155 first. Nothing changed.'; end if;
end
$mig$;

create or replace function public.record_unresolved_carrier_record(
  p_organization_id uuid,
  p_record_type text,
  p_record_id uuid,
  p_reason text,
  p_detail jsonb default '{}'::jsonb
)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog, public
as $fn$
declare
  v_uid uuid := auth.uid();
  v_id  uuid;
begin
  if p_organization_id is null or p_record_type is null or p_record_id is null
     or p_reason is null or btrim(p_reason) = '' then
    raise exception 'record_unresolved_carrier_record: organization_id, record_type, record_id and reason are all required.'
      using errcode = '22023';
  end if;

  -- Interactive caller (has a JWT): must be same-org and privileged. A
  -- migration / service context has auth.uid() = NULL and is trusted (this
  -- is how 0133's own backfill calls it, for every record_type it needs).
  if v_uid is not null then
    if p_organization_id is distinct from public.current_org_id() then
      raise exception 'record_unresolved_carrier_record: cross-organization write rejected.'
        using errcode = '42501';
    end if;
    if not public.has_role(array['owner','admin','dispatcher','accountant']::public.org_role[]) then
      raise exception 'record_unresolved_carrier_record: caller role is not permitted.'
        using errcode = '42501';
    end if;

    -- record_id is POLYMORPHIC (record_type decides which table it points
    -- into) and carries no FK, so an interactive caller could otherwise
    -- fabricate an exception "about" a record_id belonging to a DIFFERENT
    -- organization's load/invoice/document/trailer/factoring relationship.
    -- Phase 3A can only verify this for record_type='load' (the only type
    -- it actually has a caller for -- 0133's own backfill, which is trusted
    -- and never reaches this branch). Every OTHER record_type is therefore
    -- REJECTED for interactive callers until its own slice adds the matching
    -- validation -- restricting the function per correction #2 rather than
    -- leaving the other 8 record_types unverifiable.
    if p_record_type = 'load' then
      if (select organization_id from public.loads where id = p_record_id) is distinct from p_organization_id then
        raise exception 'record_unresolved_carrier_record: record_id does not belong to the caller''s organization.'
          using errcode = '42501';
      end if;
    else
      raise exception 'record_unresolved_carrier_record: interactive callers may report record_type=''load'' only in this phase; record_type ''%'' requires a trusted internal (migration/service) caller until its own slice adds record_id validation.', p_record_type
        using errcode = '42501';
    end if;
  end if;

  insert into public.unresolved_carrier_records (organization_id, record_type, record_id, reason, detail)
  values (p_organization_id, p_record_type, p_record_id, p_reason, coalesce(p_detail, '{}'::jsonb))
  on conflict (record_type, record_id) where (status = 'unresolved')
  do nothing
  returning id into v_id;

  if v_id is null then
    select id into v_id
    from public.unresolved_carrier_records
    where record_type = p_record_type and record_id = p_record_id and status = 'unresolved';
  end if;

  return v_id;
end;
$fn$;

revoke all on function public.record_unresolved_carrier_record(uuid,text,uuid,text,jsonb) from public;
grant execute on function public.record_unresolved_carrier_record(uuid,text,uuid,text,jsonb) to authenticated;
drop function public._record_unresolved_carrier_record_trusted(uuid,text,uuid,text,jsonb);
grant update on public.unresolved_carrier_records to authenticated;

do $mig$
begin
  if (select md5(regexp_replace(lower(regexp_replace(prosrc, '--[^\n]*', '', 'g')), '\s+', '', 'g')) from pg_proc where oid = to_regprocedure('public.record_unresolved_carrier_record(uuid,text,uuid,text,jsonb)')) <> '25982afd9f6a4da0d2c18b0315a8eec9' then raise exception 'ROLLBACK 0154 postcondition: body is not the 0130 baseline.'; end if;
  if to_regprocedure('public._record_unresolved_carrier_record_trusted(uuid,text,uuid,text,jsonb)') is not null then raise exception 'ROLLBACK 0154 postcondition: trusted writer still present.'; end if;
  raise notice 'ROLLBACK 0154 complete: the 0130 definition is restored (F-05 exposure is BACK; anon may again reach it if default privileges grant it).';
end
$mig$;
commit;
