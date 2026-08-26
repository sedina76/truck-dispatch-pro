-- =============================================================================
-- 0094_broker_permanent_delete_boundary.sql
-- Phase 2M.1A: close the raw-table DELETE bypass around
-- delete_broker_safely() discovered during post-0093 live acceptance.
-- Phase 2M.1B (folded in before first apply -- see bottom of file): closes
-- the one concurrency gap the 2M.1A pre-apply review flagged and did not
-- fix -- a broker-linked `documents` row can be inserted/reassigned
-- concurrently with a broker delete because `documents.entity_id` is
-- polymorphic and carries no FK, so it never participated in the
-- FOR KEY SHARE / FOR UPDATE lock conflict that already protects the five
-- real-FK tables (loads/invoices/statements/carrier_setup_packages/
-- email_send_log). Folded into this same migration rather than a separate
-- 0095 because 0094 has not been applied yet and both halves are "the
-- broker permanent-delete integrity boundary" -- splitting an unapplied,
-- still-in-review migration into two would just make the two halves
-- reviewable independently for no benefit, since neither is safe to apply
-- without the other (0094-only leaves the documents race open; the
-- documents fix alone doesn't matter without 0094 closing the raw-delete
-- bypass first).
--
-- What was wrong: delete_broker_safely() (0093) correctly refuses to delete
-- a broker with operational/financial history, but it was never the only
-- way to delete a brokers row. public.brokers was swept into the
-- standard_tables loop in 0010_rls_policies.sql, which granted owner/admin
-- a plain RLS delete policy (brokers_delete) on top of the blanket
-- `grant delete on all tables ... to authenticated`. Any owner/admin could
-- therefore call `supabase.from('brokers').delete()` directly and skip the
-- RPC's history check entirely. Worse, every FK the RPC checks
-- (loads/invoices/statements/carrier_setup_packages/email_send_log) is
-- `on delete set null`, and `documents` is a polymorphic relationship
-- (entity_type/entity_id) with no FK at all -- so a raw delete would not
-- even be stopped by referential integrity. It would silently null out
-- history on five tables and permanently orphan any broker-linked
-- documents, exactly the "silently remove evidence" failure this product
-- requirement exists to prevent.
--
-- Two independent layers, per the accepted repair:
--   1. Remove the raw authenticated DELETE path (drop the policy AND
--      revoke the underlying grant, not just one or the other).
--   2. Add a BEFORE DELETE trigger on public.brokers that independently
--      re-checks history -- authoritative regardless of caller, including
--      service_role (bypasses RLS) or any future SECURITY DEFINER function
--      that doesn't route through delete_broker_safely(). Unlike
--      guard_broker_archive_boundary() (0093), this trigger has NO
--      current_user allowlist bypass: archive/restore are reversible and
--      the RPC is the deliberate source of truth for that state, but a
--      DELETE is not reversible, so the check must not trust who is
--      asking. delete_broker_safely() already never issues the DELETE
--      statement for a protected broker, so this trigger only ever
--      actually has to refuse a delete when something *other* than
--      delete_broker_safely() attempts one.
--
-- delete_broker_safely() is repointed at a new shared predicate,
-- public.broker_has_protected_history(), so the RPC and the trigger check
-- exactly the same six relationships and cannot silently drift apart in a
-- future edit. The predicate is SECURITY DEFINER so it always sees ground
-- truth regardless of the calling role's own RLS visibility into
-- loads/invoices/documents/statements/carrier_setup_packages/
-- email_send_log -- required for the trigger to be authoritative for
-- service_role and any future caller, not just today's `authenticated`
-- owner/admin case.
--
-- Out of scope / not touched here: existing FK `on delete set null`
-- behavior on loads/invoices/statements/carrier_setup_packages/
-- email_send_log is left exactly as-is (explicitly not to be changed by
-- this repair); no production broker rows are read/written by this
-- migration; delete_broker_safely()'s own authorization/role checks are
-- unchanged.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Shared protected-history predicate used by both delete_broker_safely()
-- and the new guard trigger below, so the two checks cannot drift apart.
-- ---------------------------------------------------------------------------
create or replace function public.broker_has_protected_history(p_broker_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists(select 1 from public.loads where broker_id = p_broker_id)
      or exists(select 1 from public.invoices where broker_id = p_broker_id)
      or exists(select 1 from public.documents where entity_type = 'broker' and entity_id = p_broker_id)
      or exists(select 1 from public.statements where broker_id = p_broker_id)
      or exists(select 1 from public.carrier_setup_packages where broker_id = p_broker_id)
      or exists(select 1 from public.email_send_log where broker_id = p_broker_id);
$$;

revoke execute on function public.broker_has_protected_history(uuid) from public, anon;
grant execute on function public.broker_has_protected_history(uuid) to authenticated;

comment on function public.broker_has_protected_history(uuid) is
  'Single source of truth for whether a broker has protected operational/financial history (loads, invoices, broker documents, statements, carrier setup packages, or broker-linked email history). Used by both delete_broker_safely() and guard_broker_permanent_delete_trigger so the two checks cannot drift.';

-- ---------------------------------------------------------------------------
-- 1. Remove the raw authenticated DELETE path on public.brokers.
-- No replacement DELETE policy is added: authenticated has no legitimate
-- reason to delete a brokers row directly, ever. Only
-- delete_broker_safely() (SECURITY DEFINER, bypasses RLS internally) may
-- delete a brokers row from application code.
-- ---------------------------------------------------------------------------
drop policy if exists brokers_delete on public.brokers;
revoke delete on public.brokers from authenticated;

-- ---------------------------------------------------------------------------
-- 2. Defense-in-depth: a BEFORE DELETE trigger that is authoritative
-- regardless of caller or privilege layer. No current_user bypass.
-- ---------------------------------------------------------------------------
create or replace function public.guard_broker_permanent_delete()
returns trigger language plpgsql set search_path = public as $$
begin
  if public.broker_has_protected_history(old.id) then
    raise exception 'This broker has operational or financial history and cannot be permanently deleted. Archive the broker instead.';
  end if;
  return old;
end;
$$;

create trigger guard_broker_permanent_delete_trigger
  before delete on public.brokers
  for each row execute function public.guard_broker_permanent_delete();

-- ---------------------------------------------------------------------------
-- 3. Re-point delete_broker_safely() at the shared predicate. No behavior
-- change for any existing caller -- this only removes the duplicated
-- six-way EXISTS block so the RPC and the trigger cannot silently drift.
-- ---------------------------------------------------------------------------
create or replace function public.delete_broker_safely(p_broker_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_broker public.brokers;
begin
  if not public.has_role(array['owner','admin']::public.org_role[]) then
    raise exception 'You do not have permission to permanently delete brokers.';
  end if;
  select * into v_broker from public.brokers where id = p_broker_id for update;
  if v_broker.id is null or v_broker.organization_id <> public.current_org_id() then
    raise exception 'Broker not found in your organization.';
  end if;
  if public.broker_has_protected_history(p_broker_id) then
    return jsonb_build_object('deletion_status','not_deletable','message',
      'This broker has operational or financial history and cannot be permanently deleted. Archive the broker instead.');
  end if;
  perform public.log_activity('broker'::public.entity_type,p_broker_id,'broker_deleted',jsonb_build_object('broker_id',p_broker_id));
  delete from public.brokers where id=p_broker_id;
  return jsonb_build_object('deletion_status','deleted');
end;
$$;

comment on function public.delete_broker_safely(uuid) is
  'Owner/admin-only UUID-scoped broker deletion that refuses via public.broker_has_protected_history() to detach operational, financial, document, setup-package, or statement history. guard_broker_permanent_delete_trigger enforces the identical rule independently at the table level, so no other code path (raw table delete, service_role, or a future function) can bypass it.';

-- No grant changes needed for delete_broker_safely() itself -- 0093 already
-- revoked execute from public/anon and granted it to authenticated only.

-- =============================================================================
-- 4. Phase 2M.1B -- broker-document referential lock.
--
-- documents.entity_id is polymorphic (organization/load/dispatch/carrier/
-- broker/customer/driver/truck/trailer/invoice/settlement/expense/...) so it
-- cannot carry a real foreign key to any one target table, including
-- brokers. That means an insert linking a document to a broker
-- (entity_type='broker', entity_id=<broker id>) never took the automatic
-- FOR KEY SHARE lock a real FK would take on the referenced row, and so
-- never participated in the lock conflict that already protects
-- loads/invoices/statements/carrier_setup_packages/email_send_log against
-- delete_broker_safely()'s `for update` lock. Confirmed live: the generic
-- document-upload path (src/app/(app)/documents/new/page.tsx ->
-- createDocument() -> insertRecord()) already lets any org member type an
-- arbitrary "Entity ID" for entity_type='broker' with zero validation that
-- it names a real broker, let alone one in their own organization -- so
-- both the concurrency gap and a plain data-integrity gap are real and
-- already reachable today, not hypothetical.
--
-- guard_broker_document_link() closes both at once: for any insert, or any
-- update that changes entity_type into 'broker' or changes entity_id/
-- organization_id on an already-broker document, it takes a FOR KEY SHARE
-- lock on the referenced brokers row (id + organization_id both matching --
-- same shape as delete_broker_safely()'s org check) and refuses the write
-- if no such row exists. FOR KEY SHARE is the correct mode: it's exactly
-- what Postgres itself takes for a real FK-referencing insert, so this
-- mirrors the existing five-table behavior instead of inventing a new lock
-- protocol, and it conflicts with delete_broker_safely()'s FOR UPDATE lock
-- (and with a raw DELETE's implicit row lock) while NOT conflicting with
-- itself -- two concurrent broker-document inserts for the same broker do
-- not block each other, only a concurrent delete attempt does.
--
-- Lock ordering (both interleavings are race-free):
--   * delete locks first: the document insert's FOR KEY SHARE blocks until
--     the delete's transaction ends. If the broker was clean and got
--     deleted, the resumed insert re-checks and finds no matching row ->
--     refused, no orphan. If the broker was protected (by something else)
--     and delete_broker_safely() returned not_deletable without deleting,
--     the broker row is unchanged when the insert resumes -> insert
--     proceeds normally.
--   * insert locks first: the document commits with its FOR KEY SHARE
--     held until commit; delete_broker_safely()'s FOR UPDATE request then
--     waits for that commit, after which broker_has_protected_history()
--     (which itself does a plain, unlocked read -- no lock needed, since by
--     that point in the transaction the FOR UPDATE lock on the brokers row
--     is already held, and the concurrent document insert has already
--     committed or aborted, so the read is stable) correctly sees the
--     now-committed document and refuses deletion. No orphan either way.
--
-- Not touched: no FK is added (impossible for a polymorphic column, and
-- explicitly out of scope); every non-broker entity_type is completely
-- unaffected (the triggers' WHEN clauses only fire when the row is, or is
-- becoming, a broker document); no historical data is modified (a live
-- preflight scan found zero existing entity_type='broker' document rows,
-- so there is nothing to backfill or reconcile).
-- =============================================================================
create or replace function public.guard_broker_document_link()
returns trigger language plpgsql set search_path = public as $$
begin
  if not exists (
    select 1 from public.brokers
    where id = new.entity_id and organization_id = new.organization_id
    for key share
  ) then
    raise exception 'Document references a broker that does not exist in this organization.';
  end if;
  return new;
end;
$$;

comment on function public.guard_broker_document_link() is
  'Before a documents row is inserted, or updated into/within entity_type=''broker'', takes FOR KEY SHARE on the referenced brokers row (matching id + organization_id) and refuses the write if it does not exist -- the polymorphic equivalent of a real FK, closing both the delete-race window in broker_has_protected_history() and the pre-existing gap where entity_id was never validated at all.';

-- Fires on every insert of a broker document.
create trigger guard_broker_document_link_insert
  before insert on public.documents
  for each row when (new.entity_type = 'broker')
  execute function public.guard_broker_document_link();

-- Fires on update only when the row is newly becoming a broker document,
-- or an already-broker document is being reassigned to a different broker
-- or organization. A plain metadata edit (file_name, notes, is_verified,
-- ...) on an already-valid broker document does not re-fire this, so the
-- common case pays no extra lock/lookup cost.
create trigger guard_broker_document_link_update
  before update on public.documents
  for each row when (
    new.entity_type = 'broker'
    and (
      old.entity_type is distinct from 'broker'
      or old.entity_id is distinct from new.entity_id
      or old.organization_id is distinct from new.organization_id
    )
  )
  execute function public.guard_broker_document_link();

-- =============================================================================
-- Read-only preflight (run BEFORE applying, informational only) and
-- post-apply verification queries live in
-- supabase/VERIFY_0094_PREFLIGHT.sql and supabase/VERIFY_0094_POST_APPLY.sql
-- -- see the Phase 2M.1A / 2M.1B pre-apply reports for the accompanying
-- analysis.
-- =============================================================================
