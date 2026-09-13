-- =============================================================================
-- ROLLBACK_0143_canonical_financial_idempotency_hardening.sql
--
-- Restores the EXACT 0142 boundary: carrier_invoice_lifecycle_idempotency's
-- `action` column (narrow (organization_id, idempotency_key) unique
-- constraint, no fingerprint_version/state/created_by/updated_at columns)
-- and update_carrier_invoice_draft()'s original MD5-concatenation
-- fingerprint / 'update_draft' lock-key string / action-column INSERT.
--
-- DATA-PRESERVING REFUSAL (mirrors ROLLBACK_0141 / ROLLBACK_0142's own
-- established pattern): if carrier_invoice_lifecycle_idempotency is
-- non-empty at rollback time, this script REFUSES outright rather than
-- guess how to fold a SHA-256-era row (created_by populated, fingerprint_
-- version present, operation-scoped) back into 0142's narrower shape.
-- 0143 itself is only ever applied when the table is proven empty (its
-- own Phase 1 precondition), so a non-empty table at rollback time means
-- update_carrier_invoice_draft() has genuinely been used since 0143 went
-- live -- real financial idempotency history that must never be
-- reinterpreted, dropped, or silently downgraded to fit 0142's narrower
-- (organization_id, idempotency_key)-only constraint (which could not
-- even represent a future multi-operation row without an ambiguous
-- collision). Resolve manually (e.g. decide whether 0143 should simply
-- stay applied instead of rolling back) rather than force this script
-- through.
--
-- Never drops the pgcrypto extension (0001 already depends on it for
-- gen_random_uuid()-adjacent functionality and predates any assumption
-- this migration makes) and never drops
-- compute_financial_request_fingerprint(jsonb) if some OTHER function has
-- started depending on it since 0143 went live (checked explicitly below).
--
-- STRUCTURE: explicit BEGIN/COMMIT. NOT idempotent -- running this twice
-- will fail the second time (0142 boundary already restored), which is
-- the correct, safe failure mode.
-- =============================================================================

begin;

do $rb$
declare
  v_row_count integer;
  v_dependent_count integer;
begin
  if to_regclass('public.carrier_invoice_lifecycle_idempotency') is null then
    raise exception 'ROLLBACK_0143 precondition: carrier_invoice_lifecycle_idempotency missing entirely -- nothing to roll back to. STOP.';
  end if;
  if not exists (select 1 from information_schema.columns where table_schema='public' and table_name='carrier_invoice_lifecycle_idempotency' and column_name='operation') then
    raise exception 'ROLLBACK_0143 precondition: operation column absent -- 0143 does not appear to be applied. STOP (nothing to roll back).';
  end if;

  -- DATA-PRESERVING REFUSAL: never fold a real SHA-256-era row back into
  -- 0142's narrower shape.
  select count(*) into v_row_count from public.carrier_invoice_lifecycle_idempotency;
  if v_row_count > 0 then
    raise exception 'ROLLBACK_0143 refused: carrier_invoice_lifecycle_idempotency has % row(s) -- update_carrier_invoice_draft() has genuinely been used under 0143''s SHA-256/operation-scoped semantics since it went live. Rolling back would either destroy real financial idempotency history or silently reinterpret it under 0142''s narrower (organization_id, idempotency_key)-only constraint. Refusing to guess. Resolve manually (e.g. keep 0143 applied) before attempting this rollback again. STOP.', v_row_count;
  end if;

  -- Never remove compute_financial_request_fingerprint(jsonb) if some
  -- OTHER function (e.g. a 0144+ RPC not yet reviewed here) has started
  -- calling it -- dropping it out from under a live dependent would be a
  -- silent, unrelated breakage, not a clean rollback of 0143 alone.
  select count(*) into v_dependent_count
  from pg_proc
  where pronamespace = 'public'::regnamespace
    and proname <> 'update_carrier_invoice_draft'
    and prosrc ilike '%compute_financial_request_fingerprint%';
  if v_dependent_count > 0 then
    raise exception 'ROLLBACK_0143 refused: % other function(s) besides update_carrier_invoice_draft() now call compute_financial_request_fingerprint() -- dropping it would break them. Resolve manually. STOP.', v_dependent_count;
  end if;

  raise notice 'ROLLBACK_0143 preconditions passed. carrier_invoice_lifecycle_idempotency confirmed empty (0 rows) and compute_financial_request_fingerprint(jsonb) has no dependents outside update_carrier_invoice_draft(). Safe to restore the exact 0142 boundary.';
end
$rb$;

-- ======================= restore update_carrier_invoice_draft() (0142) =====
create or replace function public.update_carrier_invoice_draft(
  p_invoice_id uuid,
  p_patch jsonb,
  p_expected_updated_at timestamptz,
  p_reason text,
  p_idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $fn$
declare
  v_org uuid;
  v_row record;
  v_cached_result jsonb;
  v_cached_fingerprint text;
  v_fingerprint text;
  v_lock_key bigint;
  v_patch_keys text[];
  v_master_keys constant text[] := array['notes','due_date','payment_terms_days','broker_id','customer_id','currency'];
  v_financial_keys constant text[] := array['broker_id','customer_id','currency','payment_terms_days'];
  v_role_keys text[];
  v_new_notes text;
  v_new_due_date date;
  v_has_due_date boolean := false;
  v_new_payment_terms_days integer;
  v_has_payment_terms boolean := false;
  v_new_currency text;
  v_touches_recipient boolean := false;
  v_new_recipient_type public.invoice_recipient_type;
  v_new_broker_id uuid;
  v_new_customer_id uuid;
  v_party_status public.carrier_party_status;
  v_changed_fields text[] := '{}';
  v_result jsonb;
begin
  ------------------------------------------------------------------
  -- VALIDATE (nothing below this comment block, until the marked
  -- APPLY section, ever writes to carrier_invoices).
  ------------------------------------------------------------------
  if p_idempotency_key is null or btrim(p_idempotency_key) = '' then
    return jsonb_build_object('success', false, 'code', 'INVALID_INPUT', 'message', 'An idempotency key is required.');
  end if;
  if p_patch is null or jsonb_typeof(p_patch) <> 'object' then
    return jsonb_build_object('success', false, 'code', 'INVALID_INPUT', 'message', 'p_patch must be a JSON object.');
  end if;

  v_org := public.current_org_id();
  if v_org is null then
    return jsonb_build_object('success', false, 'code', 'NO_ORGANIZATION', 'message', 'No organization on this account.');
  end if;

  v_fingerprint := md5(
    coalesce(p_invoice_id::text, '') || '|' ||
    p_patch::text || '|' ||
    coalesce(p_reason, '') || '|' ||
    coalesce(p_expected_updated_at::text, '')
  );

  v_lock_key := hashtextextended(v_org::text || '|update_draft|' || p_idempotency_key, 0);
  perform pg_advisory_xact_lock(v_lock_key);

  select id, organization_id, invoice_document_type, issuance_status, updated_at, carrier_id,
         recipient_type, recipient_broker_id, recipient_customer_id
    into v_row
  from public.carrier_invoices where id = p_invoice_id for update;

  if v_row.id is null or v_row.organization_id <> v_org then
    return jsonb_build_object('success', false, 'code', 'NOT_FOUND', 'message', 'Invoice not found.');
  end if;

  select result, request_fingerprint into v_cached_result, v_cached_fingerprint
  from public.carrier_invoice_lifecycle_idempotency
  where organization_id = v_org and idempotency_key = p_idempotency_key;
  if v_cached_result is not null then
    if v_cached_fingerprint <> v_fingerprint then
      return jsonb_build_object('success', false, 'code', 'IDEMPOTENCY_KEY_REUSED', 'message', 'This idempotency key was already used for a different request.');
    end if;
    return v_cached_result;
  end if;

  if v_row.issuance_status not in ('draft', 'ready_for_issue') then
    return jsonb_build_object('success', false, 'code', 'NOT_EDITABLE', 'message', 'Only a draft or ready-for-issue invoice can be edited through this RPC.');
  end if;
  if v_row.updated_at is distinct from p_expected_updated_at then
    return jsonb_build_object('success', false, 'code', 'STALE_RECORD', 'message', 'This invoice has changed since you loaded it. Reload and try again.');
  end if;

  select array_agg(k) into v_patch_keys from jsonb_object_keys(p_patch) k;
  v_patch_keys := coalesce(v_patch_keys, '{}');
  if not (v_patch_keys <@ v_master_keys) then
    return jsonb_build_object('success', false, 'code', 'INVALID_INPUT', 'message', 'Unknown field in patch.');
  end if;
  if array_length(v_patch_keys, 1) is null then
    return jsonb_build_object('success', false, 'code', 'INVALID_INPUT', 'message', 'No recognized field was provided to change.');
  end if;

  if public.has_role(array['owner', 'admin']::public.org_role[]) then
    v_role_keys := array['notes', 'due_date', 'payment_terms_days', 'broker_id', 'customer_id', 'currency'];
  elsif public.has_role(array['accountant']::public.org_role[]) then
    v_role_keys := array['notes', 'due_date', 'payment_terms_days', 'currency'];
  elsif public.has_role(array['dispatcher']::public.org_role[]) then
    v_role_keys := array['notes'];
  else
    return jsonb_build_object('success', false, 'code', 'FORBIDDEN', 'message', 'You do not have permission to edit this invoice.');
  end if;

  if not (v_patch_keys <@ v_role_keys) then
    return jsonb_build_object('success', false, 'code', 'FORBIDDEN', 'message', 'One or more fields in this patch are not permitted for your role.');
  end if;

  if (v_patch_keys && v_financial_keys) and (p_reason is null or btrim(p_reason) = '') then
    return jsonb_build_object('success', false, 'code', 'INVALID_INPUT', 'message', 'A reason is required to change billing/recipient fields.');
  end if;

  -- ---- validate each field's shape/value (still no writes) ----
  if p_patch ? 'notes' then
    if jsonb_typeof(p_patch->'notes') not in ('string', 'null') then
      return jsonb_build_object('success', false, 'code', 'INVALID_INPUT', 'message', 'notes must be a string or null.');
    end if;
    v_new_notes := p_patch->>'notes';
  end if;

  if p_patch ? 'due_date' then
    if jsonb_typeof(p_patch->'due_date') not in ('string', 'null') then
      return jsonb_build_object('success', false, 'code', 'INVALID_INPUT', 'message', 'due_date must be a date string or null.');
    end if;
    begin
      v_new_due_date := nullif(p_patch->>'due_date', '')::date;
      v_has_due_date := true;
    exception when others then
      return jsonb_build_object('success', false, 'code', 'INVALID_INPUT', 'message', 'due_date is not a valid date.');
    end;
  end if;

  if p_patch ? 'payment_terms_days' then
    if jsonb_typeof(p_patch->'payment_terms_days') not in ('number', 'null') then
      return jsonb_build_object('success', false, 'code', 'INVALID_INPUT', 'message', 'payment_terms_days must be a number or null.');
    end if;
    begin
      v_new_payment_terms_days := (p_patch->>'payment_terms_days')::integer;
      v_has_payment_terms := true;
    exception when others then
      return jsonb_build_object('success', false, 'code', 'INVALID_INPUT', 'message', 'payment_terms_days is not a valid integer.');
    end;
    if v_new_payment_terms_days is not null and (v_new_payment_terms_days < 0 or v_new_payment_terms_days > 365) then
      return jsonb_build_object('success', false, 'code', 'INVALID_INPUT', 'message', 'payment_terms_days must be between 0 and 365.');
    end if;
  end if;

  if p_patch ? 'currency' then
    if jsonb_typeof(p_patch->'currency') <> 'string' then
      return jsonb_build_object('success', false, 'code', 'INVALID_INPUT', 'message', 'currency must be a string.');
    end if;
    v_new_currency := p_patch->>'currency';
    if v_new_currency !~ '^[A-Z]{3}$' then
      return jsonb_build_object('success', false, 'code', 'INVALID_INPUT', 'message', 'currency must be a 3-letter uppercase code.');
    end if;
  end if;

  -- ---- recipient change (broker_id / customer_id) -- still no writes ----
  if (p_patch ? 'broker_id') or (p_patch ? 'customer_id') then
    if v_row.invoice_document_type = 'dispatch_service_invoice' then
      return jsonb_build_object('success', false, 'code', 'INVALID_INPUT', 'message', 'A dispatch-service invoice cannot receive a broker/customer recipient.');
    end if;
    v_touches_recipient := true;

    if (p_patch ? 'broker_id') and jsonb_typeof(p_patch->'broker_id') not in ('string', 'null') then
      return jsonb_build_object('success', false, 'code', 'INVALID_INPUT', 'message', 'broker_id must be a uuid string or null.');
    end if;
    if (p_patch ? 'customer_id') and jsonb_typeof(p_patch->'customer_id') not in ('string', 'null') then
      return jsonb_build_object('success', false, 'code', 'INVALID_INPUT', 'message', 'customer_id must be a uuid string or null.');
    end if;

    begin
      v_new_broker_id := case when p_patch ? 'broker_id' then nullif(p_patch->>'broker_id', '')::uuid else v_row.recipient_broker_id end;
      v_new_customer_id := case when p_patch ? 'customer_id' then nullif(p_patch->>'customer_id', '')::uuid else v_row.recipient_customer_id end;
    exception when others then
      return jsonb_build_object('success', false, 'code', 'INVALID_INPUT', 'message', 'broker_id/customer_id must be valid uuids.');
    end;

    if (v_new_broker_id is not null) = (v_new_customer_id is not null) then
      return jsonb_build_object('success', false, 'code', 'INVALID_INPUT', 'message', 'Exactly one of broker_id or customer_id must be set for a freight invoice.');
    end if;
    v_new_recipient_type := case when v_new_broker_id is not null then 'broker' else 'customer' end;

    if v_new_broker_id is not null then
      if not exists (select 1 from public.brokers where id = v_new_broker_id and organization_id = v_org and not is_blacklisted) then
        return jsonb_build_object('success', false, 'code', 'INVALID_RECIPIENT', 'message', 'Selected broker is not available.');
      end if;
      select status into v_party_status from public.carrier_brokers where carrier_id = v_row.carrier_id and broker_id = v_new_broker_id;
      if v_party_status is distinct from 'active' then
        return jsonb_build_object('success', false, 'code', 'INVALID_RECIPIENT', 'message', 'This carrier has no active relationship with the selected broker.');
      end if;
    else
      if not exists (select 1 from public.customers where id = v_new_customer_id and organization_id = v_org and is_active) then
        return jsonb_build_object('success', false, 'code', 'INVALID_RECIPIENT', 'message', 'Selected customer is not available.');
      end if;
      select status into v_party_status from public.carrier_customers where carrier_id = v_row.carrier_id and customer_id = v_new_customer_id;
      if v_party_status is distinct from 'active' then
        return jsonb_build_object('success', false, 'code', 'INVALID_RECIPIENT', 'message', 'This carrier has no active relationship with the selected customer.');
      end if;
    end if;
  end if;

  ------------------------------------------------------------------
  -- APPLY
  ------------------------------------------------------------------
  begin
    if p_patch ? 'notes' then
      update public.carrier_invoices set notes = v_new_notes where id = p_invoice_id;
      v_changed_fields := array_append(v_changed_fields, 'notes');
    end if;
    if v_has_due_date then
      update public.carrier_invoices set due_date = v_new_due_date where id = p_invoice_id;
      v_changed_fields := array_append(v_changed_fields, 'due_date');
    end if;
    if v_has_payment_terms then
      update public.carrier_invoices set payment_terms_days = v_new_payment_terms_days where id = p_invoice_id;
      v_changed_fields := array_append(v_changed_fields, 'payment_terms_days');
    end if;
    if p_patch ? 'currency' then
      update public.carrier_invoices set currency = v_new_currency where id = p_invoice_id;
      v_changed_fields := array_append(v_changed_fields, 'currency');
    end if;
    if v_touches_recipient then
      update public.carrier_invoices
        set recipient_type = v_new_recipient_type, recipient_broker_id = v_new_broker_id, recipient_customer_id = v_new_customer_id
        where id = p_invoice_id;
      v_changed_fields := array_append(v_changed_fields, 'recipient');
    end if;

    perform public.log_activity('invoice'::public.entity_type, p_invoice_id, 'carrier_invoice_draft_updated',
      jsonb_build_object('changed_fields', to_jsonb(v_changed_fields), 'reason', p_reason));

    v_result := jsonb_build_object(
      'success', true, 'code', 'UPDATED', 'invoice_id', p_invoice_id,
      'changed_fields', to_jsonb(v_changed_fields),
      'updated_at', (select updated_at from public.carrier_invoices where id = p_invoice_id)
    );

    insert into public.carrier_invoice_lifecycle_idempotency (organization_id, idempotency_key, invoice_id, action, request_fingerprint, result)
    values (v_org, p_idempotency_key, p_invoice_id, 'update_draft', v_fingerprint, v_result);
  exception
    when unique_violation then
      declare
        v_constraint text;
      begin
        get stacked diagnostics v_constraint = constraint_name;
        if v_constraint <> 'civ_idempotency_unique' then
          raise;
        end if;
      end;
      select result, request_fingerprint into v_cached_result, v_cached_fingerprint
      from public.carrier_invoice_lifecycle_idempotency
      where organization_id = v_org and idempotency_key = p_idempotency_key;
      if v_cached_fingerprint <> v_fingerprint then
        return jsonb_build_object('success', false, 'code', 'IDEMPOTENCY_KEY_REUSED', 'message', 'This idempotency key was already used for a different request.');
      end if;
      return v_cached_result;
  end;

  return v_result;
end;
$fn$;

grant execute on function public.update_carrier_invoice_draft(uuid, jsonb, timestamptz, text, text) to authenticated;

comment on function public.update_carrier_invoice_draft(uuid, jsonb, timestamptz, text, text) is
  'Phase 3B.3A.2 Section B (Phase 3B.3A.3 Section A/B: idempotency-collision closure) -- the ONLY guarded path for due_date/payment_terms_days/broker_id/customer_id/currency changes (notes also has a direct column grant). p_patch is a strict, flat allowlisted JSON object -- presence of a key means "set it" (including to JSON null), absence means "leave unchanged". Role-gated: owner/admin get the full field set; accountant gets billing fields (due_date/payment_terms_days/currency) + notes; dispatcher gets notes only; driver/viewer are FORBIDDEN immediately. Only draft/ready_for_issue invoices are editable. carrier_id/invoice_document_type/issuance_status/payment_status/invoice_number/totals/snapshot identity are NEVER in the patch allowlist -- structurally immutable through this RPC, not merely unused. Lock order: derive organization -> acquire a pg_advisory_xact_lock scoped to (organization, ''update_draft'', idempotency_key) -> lock the invoice row -> revalidate org/not-found from that locked row -> resolve idempotency -> validate -> mutate+audit+idempotency-insert as one atomic block. The advisory lock (never a bare global lock -- organization_id is baked into the hashed key) fully serializes every caller sharing the same (org, operation, key) tuple regardless of which invoice each targets, closing the same-key/different-invoice race a prior pass left open; a client never receives a raw constraint name, SQL text, or internal identifier -- only IDEMPOTENCY_KEY_REUSED. The request fingerprint (deterministic, canonical, no randomness, never client-supplied) covers invoice id + patch + reason + expected_updated_at, so a replayed key with ANY different logical input -- including a different expected version -- is rejected as reused rather than silently replayed or applied; jsonb''s own key-order canonicalization means logically identical patches with differently-ordered keys always fingerprint identically. Optimistic concurrency (STALE_RECORD); exactly one log_activity() audit event per successful call, zero for a collision (the mutation+audit+insert are one savepoint-scoped block, rolled back together on collision); every validation happens before the first write.';

-- ======================= restore carrier_invoice_lifecycle_idempotency (0142) =====
alter table public.carrier_invoice_lifecycle_idempotency drop constraint civ_idempotency_unique;

alter table public.carrier_invoice_lifecycle_idempotency
  drop column fingerprint_version,
  drop column state,
  drop column created_by,
  drop column updated_at;

alter table public.carrier_invoice_lifecycle_idempotency rename column operation to action;

alter table public.carrier_invoice_lifecycle_idempotency add constraint civ_idempotency_unique unique (organization_id, idempotency_key);

comment on table public.carrier_invoice_lifecycle_idempotency is
  'Used by update_carrier_invoice_draft() today and reserved for 0143''s issuance RPC. No client INSERT/UPDATE/DELETE policy -- writable only via a SECURITY DEFINER RPC, matching factoring_integration_lifecycle_idempotency (0141). request_fingerprint lets a replay with a DIFFERENT payload under the same key be rejected rather than silently replayed or silently applied.';

-- ======================= drop the 0143 fingerprint primitive ===============
drop function public.compute_financial_request_fingerprint(jsonb);

-- Deliberately does NOT drop the pgcrypto extension -- 0001 already
-- depends on it and predates any assumption 0143 makes; dropping it here
-- would be an unrelated, irreversible action this rollback has no
-- business taking.

-- ======================= POSTCONDITIONS =====================================
do $rb$
begin
  if exists (select 1 from information_schema.columns where table_schema='public' and table_name='carrier_invoice_lifecycle_idempotency' and column_name='operation') then
    raise exception 'ROLLBACK_0143 postcondition: operation column still present.';
  end if;
  if not exists (select 1 from information_schema.columns where table_schema='public' and table_name='carrier_invoice_lifecycle_idempotency' and column_name='action') then
    raise exception 'ROLLBACK_0143 postcondition: action column not restored.';
  end if;
  if exists (select 1 from information_schema.columns where table_schema='public' and table_name='carrier_invoice_lifecycle_idempotency' and column_name in ('fingerprint_version','state','created_by','updated_at')) then
    raise exception 'ROLLBACK_0143 postcondition: one or more 0143 columns still present.';
  end if;
  if not exists (
    select 1 from pg_constraint c join pg_class t on t.oid = c.conrelid
    where t.relname = 'carrier_invoice_lifecycle_idempotency' and c.conname = 'civ_idempotency_unique'
      and (
        select array_agg(a.attname::text order by a.attname)
        from unnest(c.conkey) ck(attnum) join pg_attribute a on a.attrelid = t.oid and a.attnum = ck.attnum
      ) = array['idempotency_key','organization_id']
  ) then
    raise exception 'ROLLBACK_0143 postcondition: civ_idempotency_unique is not restored to exactly (organization_id, idempotency_key).';
  end if;
  if to_regprocedure('public.compute_financial_request_fingerprint(jsonb)') is not null then
    raise exception 'ROLLBACK_0143 postcondition: compute_financial_request_fingerprint(jsonb) still exists.';
  end if;
  if (select prosrc from pg_proc where proname = 'update_carrier_invoice_draft' and pronamespace = 'public'::regnamespace) not ilike '%md5(%' then
    raise exception 'ROLLBACK_0143 postcondition: update_carrier_invoice_draft() does not reference md5() -- 0142 fingerprint not restored.';
  end if;
  if (select prosrc from pg_proc where proname = 'update_carrier_invoice_draft' and pronamespace = 'public'::regnamespace) ilike '%compute_financial_request_fingerprint%' then
    raise exception 'ROLLBACK_0143 postcondition: update_carrier_invoice_draft() still calls compute_financial_request_fingerprint().';
  end if;
  if (select count(*) from public.carrier_invoice_lifecycle_idempotency) <> 0 then
    raise exception 'ROLLBACK_0143 postcondition: table unexpectedly non-empty after a rollback that only proceeds when it was empty.';
  end if;

  raise notice 'ROLLBACK_0143 complete: exact 0142 boundary restored (action column, narrow (organization_id, idempotency_key) unique constraint, MD5 concatenation fingerprint, ''update_draft'' lock-key string). compute_financial_request_fingerprint(jsonb) dropped. pgcrypto extension left in place (0001 dependency).';
end
$rb$;

commit;
