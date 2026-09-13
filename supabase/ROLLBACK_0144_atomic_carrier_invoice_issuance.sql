-- =============================================================================
-- ROLLBACK_0144_atomic_carrier_invoice_issuance.sql
--
-- *** EMERGENCY USE ONLY. READ THIS HEADER BEFORE RUNNING. ***
--
-- Restores the EXACT 0143 boundary: drops issue_carrier_invoice(), restores
-- guard_carrier_invoice_line_item_mutability()/guard_carrier_invoice_load_
-- mutability() to their exact pre-0144 (0142) bodies, drops carrier_
-- invoice_line_items.line_type/source_load_id/source_dispatch_id and the
-- civli_amounts_nonnegative constraint, drops the carrier_invoice_
-- line_item_type enum, and (Phase 3B.3C.2, Section C) drops the
-- a0144_guard_load_stops_parent_lock trigger + guard_load_stops_parent_
-- lock() function -- restoring load_stops to its exact pre-0144 state
-- (zero guard triggers, generic RLS-based CRUD only, exactly as it was
-- in every migration 0001-0143).
--
-- DATA-PRESERVING REFUSALS (mirrors ROLLBACK_0141/0142/0143's own
-- established pattern):
--   1. Refuses outright if ANY carrier_invoice_issuance_snapshots row
--      exists, or ANY carrier_invoices row is issuance_status='issued'.
--      issue_carrier_invoice() is the ONLY thing that can ever create
--      such a row -- if one exists, real financial records have been
--      issued under this migration's numbering/snapshot mechanism, and
--      rolling back would either orphan them (a snapshot table/enum
--      still exists structurally, but the guarded RPC that is the sole
--      documented way to have produced them would be gone, and a FUTURE
--      reapply of 0144 could not prove those rows are safe to leave
--      alone) or require deleting/reinterpreting them, which this script
--      refuses to do, exactly as 0143 refuses to reinterpret an existing
--      MD5 fingerprint.
--   2. Refuses if any OTHER function in this schema (besides
--      issue_carrier_invoice, guard_carrier_invoice_line_item_mutability,
--      and guard_carrier_invoice_load_mutability) references line_type,
--      source_load_id, source_dispatch_id, or carrier_invoice_line_item_
--      type in its own source -- a later migration may have built on
--      these columns, and dropping them out from under such a dependent
--      would be an unrelated, silent breakage, not a clean rollback of
--      0144 alone.
--   3. Refuses if any carrier_invoice_line_items row has line_type =
--      'dispatch_service_fee' or a non-null source_load_id/source_
--      dispatch_id -- dropping those columns would silently discard real
--      data a later process may have written.
--
-- Never drops carrier_invoice_number_counters, carrier_invoice_lifecycle_
-- idempotency, or any 0142/0143 object -- those are 0142/0143's own and
-- are untouched by this script regardless of outcome.
--
-- STRUCTURE: explicit BEGIN/COMMIT. NOT idempotent -- running this twice
-- will fail the second time (0143 boundary already restored), which is
-- the correct, safe failure mode.
-- =============================================================================

begin;

do $rb$
declare
  v_issued_count integer;
  v_snapshot_count integer;
  v_dependent_count integer;
  v_line_type_data_count integer;
begin
  if to_regprocedure('public.issue_carrier_invoice(uuid,timestamptz,text,text)') is null then
    raise exception 'ROLLBACK_0144 precondition: issue_carrier_invoice(...) does not exist -- 0144 does not appear to be applied. STOP (nothing to roll back).';
  end if;

  -- Refusal 1: never orphan or reinterpret real issued financial records.
  select count(*) into v_snapshot_count from public.carrier_invoice_issuance_snapshots;
  select count(*) into v_issued_count from public.carrier_invoices where issuance_status = 'issued';
  if v_snapshot_count > 0 or v_issued_count > 0 then
    raise exception 'ROLLBACK_0144 refused: % issuance snapshot(s) and % issued invoice(s) exist -- issue_carrier_invoice() is the only path that could have created them. Rolling back would remove the sole documented, guarded issuance mechanism while real financial records issued through it remain in the database. Refusing to guess whether that is safe. Resolve manually (e.g. keep 0144 applied) before attempting this rollback again. STOP.', v_snapshot_count, v_issued_count;
  end if;

  -- Refusal 2: never drop columns/enum a later migration may depend on.
  select count(*) into v_dependent_count
  from pg_proc
  where pronamespace = 'public'::regnamespace
    and proname not in ('issue_carrier_invoice', 'guard_carrier_invoice_line_item_mutability', 'guard_carrier_invoice_load_mutability')
    and (
      prosrc ilike '%line_type%' or prosrc ilike '%source_load_id%' or prosrc ilike '%source_dispatch_id%'
      or prosrc ilike '%carrier_invoice_line_item_type%'
    );
  if v_dependent_count > 0 then
    raise exception 'ROLLBACK_0144 refused: % other function(s) besides issue_carrier_invoice()/the two mutability guards reference line_type/source_load_id/source_dispatch_id/carrier_invoice_line_item_type -- a later migration may depend on these columns. Resolve manually. STOP.', v_dependent_count;
  end if;

  -- Refusal 3: never silently discard real line-item data in the new columns.
  select count(*) into v_line_type_data_count
  from public.carrier_invoice_line_items
  where line_type = 'dispatch_service_fee' or source_load_id is not null or source_dispatch_id is not null;
  if v_line_type_data_count > 0 then
    raise exception 'ROLLBACK_0144 refused: % carrier_invoice_line_items row(s) carry non-default line_type/source_load_id/source_dispatch_id data -- dropping these columns would silently discard it. Resolve manually. STOP.', v_line_type_data_count;
  end if;

  -- Refusal 4 (Phase 3B.3C.2): never drop guard_load_stops_parent_lock()
  -- if some OTHER function has come to depend on it existing -- it is a
  -- pure lock-ordering device today, but a later migration may have
  -- built on its presence. issue_carrier_invoice() is excluded: its own
  -- body only mentions guard_load_stops_parent_lock() in an explanatory
  -- COMMENT (prosrc includes comments verbatim), never an actual call,
  -- and it is dropped by this same script a few statements below anyway.
  select count(*) into v_dependent_count
  from pg_proc
  where pronamespace = 'public'::regnamespace
    and proname not in ('guard_load_stops_parent_lock', 'issue_carrier_invoice')
    and prosrc ilike '%guard_load_stops_parent_lock%';
  if v_dependent_count > 0 then
    raise exception 'ROLLBACK_0144 refused: % other function(s) reference guard_load_stops_parent_lock() by name -- a later migration may depend on it. Resolve manually. STOP.', v_dependent_count;
  end if;

  raise notice 'ROLLBACK_0144 preconditions passed. Zero issuance snapshots, zero issued invoices, zero external dependents, zero non-default line-item data. Safe to restore the exact 0143 boundary.';
end
$rb$;

-- ======================= restore the exact 0142 mutability guards ==========
create or replace function public.guard_carrier_invoice_line_item_mutability()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $fn$
declare
  v_invoice_id uuid := coalesce(new.invoice_id, old.invoice_id);
  v_org uuid;
  v_status public.invoice_issuance_status;
begin
  select organization_id, issuance_status into v_org, v_status
  from public.carrier_invoices where id = v_invoice_id;
  if v_status is null then
    raise exception 'carrier_invoice_line_items: invoice not found.' using errcode = '23503';
  end if;
  if v_status not in ('draft', 'ready_for_issue') then
    raise exception 'carrier_invoice_line_items: line items are immutable once the invoice has left draft/ready_for_issue (current status: %).', v_status using errcode = '55000';
  end if;
  if tg_op in ('INSERT', 'UPDATE') and new.organization_id <> v_org then
    raise exception 'carrier_invoice_line_items: organization_id must match the invoice''s own organization.' using errcode = '23514';
  end if;
  return coalesce(new, old);
end;
$fn$;

create or replace function public.guard_carrier_invoice_load_mutability()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $fn$
declare
  v_status public.invoice_issuance_status;
begin
  select issuance_status into v_status
  from public.carrier_invoices where id = coalesce(new.invoice_id, old.invoice_id);
  if v_status not in ('draft', 'ready_for_issue') then
    raise exception 'carrier_invoice_loads: load links are immutable once the invoice has left draft/ready_for_issue (current status: %).', v_status using errcode = '55000';
  end if;
  return coalesce(new, old);
end;
$fn$;

-- ======================= drop issue_carrier_invoice() =======================
drop function public.issue_carrier_invoice(uuid, timestamptz, text, text);

-- ======================= restore load_stops (Phase 3B.3C.2, Section C) =====
drop trigger a0144_guard_load_stops_parent_lock on public.load_stops;
drop function public.guard_load_stops_parent_lock();

-- ======================= restore carrier_invoice_line_items (0142) =========
alter table public.carrier_invoice_line_items drop constraint civli_amounts_nonnegative;

alter table public.carrier_invoice_line_items
  drop column line_type,
  drop column source_load_id,
  drop column source_dispatch_id;

drop type public.carrier_invoice_line_item_type;

-- ======================= POSTCONDITIONS =====================================
do $rb$
begin
  if to_regprocedure('public.issue_carrier_invoice(uuid,timestamptz,text,text)') is not null then
    raise exception 'ROLLBACK_0144 postcondition: issue_carrier_invoice(...) still exists.';
  end if;
  if exists (select 1 from information_schema.columns where table_schema='public' and table_name='carrier_invoice_line_items' and column_name in ('line_type','source_load_id','source_dispatch_id')) then
    raise exception 'ROLLBACK_0144 postcondition: one or more 0144 line-item columns still present.';
  end if;
  if to_regtype('public.carrier_invoice_line_item_type') is not null then
    raise exception 'ROLLBACK_0144 postcondition: carrier_invoice_line_item_type still exists.';
  end if;
  if (select prosrc from pg_proc where proname = 'guard_carrier_invoice_line_item_mutability' and pronamespace = 'public'::regnamespace) ilike '%for update%' then
    raise exception 'ROLLBACK_0144 postcondition: guard_carrier_invoice_line_item_mutability() still locks the parent invoice row.';
  end if;
  if (select prosrc from pg_proc where proname = 'guard_carrier_invoice_load_mutability' and pronamespace = 'public'::regnamespace) ilike '%for update%' then
    raise exception 'ROLLBACK_0144 postcondition: guard_carrier_invoice_load_mutability() still locks the parent invoice row.';
  end if;
  if to_regprocedure('public.guard_load_stops_parent_lock()') is not null then
    raise exception 'ROLLBACK_0144 postcondition: guard_load_stops_parent_lock() still exists.';
  end if;
  if exists (
    select 1 from pg_trigger tg join pg_class t on t.oid = tg.tgrelid
    where t.relname = 'load_stops' and tg.tgname = 'a0144_guard_load_stops_parent_lock' and not tg.tgisinternal
  ) then
    raise exception 'ROLLBACK_0144 postcondition: a0144_guard_load_stops_parent_lock trigger still exists on load_stops.';
  end if;
  if exists (select 1 from pg_trigger tg join pg_class t on t.oid = tg.tgrelid where t.relname = 'load_stops' and not tg.tgisinternal) then
    raise exception 'ROLLBACK_0144 postcondition: load_stops still has a non-internal trigger -- it should have zero, exactly as in every migration 0001-0143.';
  end if;

  raise notice 'ROLLBACK_0144 complete: exact 0143 boundary restored (issue_carrier_invoice dropped; carrier_invoice_line_items back to its 0142 shape; both mutability guards back to their exact 0142 bodies; load_stops back to zero guard triggers). carrier_invoice_number_counters, carrier_invoice_lifecycle_idempotency, and every other 0142/0143 object left untouched.';
end
$rb$;

commit;
