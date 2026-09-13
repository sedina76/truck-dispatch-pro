-- ############################################################################
-- ##  MANUAL EMERGENCY ROLLBACK -- 0142_immutable_carrier_invoice_foundation ##
-- ##  .sql                                                                  ##
-- ##                                                                        ##
-- ##  DO NOT RUN unless a decision has been made to reverse 0142.           ##
-- ##  APPLY AS ONE TRANSACTION.                                             ##
-- ##                                                                        ##
-- ##  Restores the EXACT pre-0142 (0141-boundary) state: drops every table/ ##
-- ##  function/trigger/type/index 0142 introduced, and reverts platform_    ##
-- ##  settings.dispatch_invoice_prefix. public.invoices and every other     ##
-- ##  0001-0141 object are never touched (0142 never touched them either). ##
-- ##                                                                        ##
-- ##  DATA-PRESERVING REFUSAL: if ANY carrier_invoices row has ever reached ##
-- ##  'issued' or beyond (i.e. an issuance snapshot exists), rolling back   ##
-- ##  would destroy real, immutable financial history. This script REFUSES ##
-- ##  outright (raises, whole transaction rolls back) in that case, exactly ##
-- ##  like ROLLBACK_0141's own refusal posture for non-'draft' rows. Since  ##
-- ##  0142 ships no issuance RPC, this can only ever be reached today by    ##
-- ##  direct data manipulation in a disposable test database -- but the    ##
-- ##  guard is unconditional regardless.                                   ##
-- ############################################################################

begin;

-- --- Guard 0: this exact 0142 migration was applied -------------------------
do $rb$
begin
  if to_regclass('public.carrier_invoices') is null then
    raise exception 'ROLLBACK 0142: public.carrier_invoices not found -- 0142 does not appear to be applied. STOP.';
  end if;
end
$rb$;

-- --- Guard 1: refuse if a later migration appears to depend on 0142 --------
do $rb$
begin
  if to_regclass('public.carrier_invoice_delivery_events') is not null then
    raise exception 'ROLLBACK 0142: an unrecognized carrier_invoice_delivery_events table exists -- a later migration may depend on 0142''s tables. STOP.';
  end if;
end
$rb$;

-- --- Guard 2: refuse if any invoice has ever been issued (real financial
-- history that cannot be safely discarded) -------------------------------
do $rb$
declare v_issued int;
begin
  select count(*) into v_issued from public.carrier_invoices where issuance_status not in ('draft', 'ready_for_issue');
  if v_issued > 0 then
    raise exception 'ROLLBACK 0142: % carrier_invoices row(s) have been issued (or voided) -- refusing to drop tables holding real financial history. STOP.', v_issued;
  end if;
  if (select count(*) from public.carrier_invoices where payment_status <> 'unpaid') > 0 then
    raise exception 'ROLLBACK 0142: at least one carrier_invoices row has a non-unpaid payment_status -- refusing to drop tables holding real payment history. STOP.';
  end if;
  if (select count(*) from public.carrier_invoice_issuance_snapshots) > 0 then
    raise exception 'ROLLBACK 0142: carrier_invoice_issuance_snapshots is non-empty -- refusing to drop immutable financial snapshots. STOP.';
  end if;
  if (select count(*) from public.legacy_invoice_carrier_migration_review where reviewed) > 0 then
    raise exception 'ROLLBACK 0142: at least one legacy_invoice_carrier_migration_review row has been reviewed -- refusing to drop real review/audit history. STOP.';
  end if;
end
$rb$;

-- --- A. drop everything 0142 introduced --------------------------------
drop trigger if exists a0142_guard_delete on public.carrier_invoices;
drop trigger if exists a0142_guard_lifecycle_transition on public.carrier_invoices;
drop trigger if exists a0142_guard_org_consistency on public.carrier_invoices;
drop trigger if exists set_updated_at on public.carrier_invoices;

drop trigger if exists a0142_guard_snapshot_immutable on public.carrier_invoice_issuance_snapshots;

drop trigger if exists a0142_recalculate_totals on public.carrier_invoice_line_items;
drop trigger if exists a0142_guard_line_item_mutability on public.carrier_invoice_line_items;
drop trigger if exists set_updated_at on public.carrier_invoice_line_items;

drop trigger if exists a0142_guard_load_mutability on public.carrier_invoice_loads;
drop trigger if exists a0142_guard_load_consistency on public.carrier_invoice_loads;

drop trigger if exists set_updated_at on public.legacy_invoice_carrier_migration_review;

drop function if exists public.update_carrier_invoice_draft(uuid, jsonb, timestamptz, text, text);
drop function if exists public.review_legacy_invoice_carrier_migration(uuid, text, text, timestamptz, text);
drop function if exists public.scan_legacy_invoices_for_carrier_migration();
drop function if exists public.classify_legacy_invoice_for_carrier_migration(uuid);
drop function if exists public.carrier_invoice_issuance_problem(uuid);
drop function if exists public.carrier_invoice_factoring_readiness_problem(uuid);
drop function if exists public.carrier_invoice_recipient_problem(uuid);
drop function if exists public.guard_carrier_invoice_delete();
drop function if exists public.guard_carrier_invoice_lifecycle_transition();
drop function if exists public.guard_carrier_invoice_load_mutability();
drop function if exists public.guard_carrier_invoice_load_consistency();
drop function if exists public.guard_carrier_invoice_issuance_snapshot_immutable();
drop function if exists public.recalculate_carrier_invoice_totals();
drop function if exists public.guard_carrier_invoice_line_item_mutability();
drop function if exists public.guard_carrier_invoice_org_consistency();
drop function if exists public._generate_carrier_invoice_number_internal(public.invoice_document_type, uuid, text);

drop table if exists public.legacy_invoice_review_idempotency;
drop table if exists public.legacy_invoice_carrier_migration_review;
drop table if exists public.carrier_invoice_lifecycle_idempotency;
drop table if exists public.carrier_invoice_issuance_snapshots;
drop table if exists public.carrier_invoice_number_counters;
drop table if exists public.carrier_invoice_loads;
drop table if exists public.carrier_invoice_line_items;
drop table if exists public.carrier_invoices;

-- Dropped only after the table (civs_no_forbidden_keys) that depended on
-- it is already gone.
drop function if exists public.jsonb_contains_forbidden_key(jsonb, text[]);

alter table public.platform_settings drop column if exists dispatch_invoice_prefix;

drop type if exists public.invoice_recipient_type;
drop type if exists public.invoice_payment_status;
drop type if exists public.invoice_issuance_status;
drop type if exists public.invoice_document_type;

-- --- Guard: postconditions -- prove the 0141 boundary, not just "no error" -
do $rb$
begin
  if to_regclass('public.carrier_invoices') is not null then
    raise exception 'ROLLBACK 0142 postcondition: public.carrier_invoices still exists.';
  end if;
  if to_regclass('public.carrier_invoice_issuance_snapshots') is not null then
    raise exception 'ROLLBACK 0142 postcondition: public.carrier_invoice_issuance_snapshots still exists.';
  end if;
  if to_regclass('public.legacy_invoice_carrier_migration_review') is not null then
    raise exception 'ROLLBACK 0142 postcondition: public.legacy_invoice_carrier_migration_review still exists.';
  end if;
  if exists (select 1 from pg_type where typname = 'invoice_document_type') then
    raise exception 'ROLLBACK 0142 postcondition: invoice_document_type enum still exists.';
  end if;
  if exists (select 1 from information_schema.columns where table_schema='public' and table_name='platform_settings' and column_name='dispatch_invoice_prefix') then
    raise exception 'ROLLBACK 0142 postcondition: platform_settings.dispatch_invoice_prefix still exists.';
  end if;
  if to_regprocedure('public._generate_carrier_invoice_number_internal(public.invoice_document_type,uuid,text)') is not null then
    raise exception 'ROLLBACK 0142 postcondition: the private numbering mechanism function still exists.';
  end if;
  if to_regprocedure('public.review_legacy_invoice_carrier_migration(uuid,text,text,timestamptz,text)') is not null then
    raise exception 'ROLLBACK 0142 postcondition: review_legacy_invoice_carrier_migration() still exists.';
  end if;
  if to_regprocedure('public.update_carrier_invoice_draft(uuid,jsonb,timestamptz,text,text)') is not null then
    raise exception 'ROLLBACK 0142 postcondition: update_carrier_invoice_draft() still exists.';
  end if;
  if to_regclass('public.legacy_invoice_review_idempotency') is not null then
    raise exception 'ROLLBACK 0142 postcondition: legacy_invoice_review_idempotency still exists.';
  end if;
  if exists (select 1 from pg_type where typname in ('invoice_issuance_status', 'invoice_payment_status')) then
    raise exception 'ROLLBACK 0142 postcondition: invoice_issuance_status / invoice_payment_status still exist.';
  end if;
  if to_regprocedure('public.jsonb_contains_forbidden_key(jsonb,text[])') is not null then
    raise exception 'ROLLBACK 0142 postcondition: jsonb_contains_forbidden_key(jsonb,text[]) still exists.';
  end if;
  raise notice 'ROLLBACK 0142 complete: carrier_invoices/carrier_invoice_line_items/carrier_invoice_loads/carrier_invoice_number_counters/carrier_invoice_issuance_snapshots/carrier_invoice_lifecycle_idempotency/legacy_invoice_carrier_migration_review/legacy_invoice_review_idempotency and every 0142 function/trigger/enum dropped; platform_settings.dispatch_invoice_prefix reverted. public.invoices and every 0001-0141 object were never touched by 0142 and remain untouched now.';
end
$rb$;

commit;
