-- =============================================================================
-- VERIFY_0095_POST_APPLY.sql
-- Phase 2M.2B -- read-only structural verification AFTER applying 0095.
-- Behavioral/concurrency cases at the bottom still need to be run against
-- real authenticated sessions and genuinely overlapping transactions; this
-- file confirms the schema-level shape first.
-- =============================================================================

-- 1. Tables exist.
select table_name from information_schema.tables
where table_schema = 'public' and table_name in ('broker_packets', 'broker_packet_items', 'broker_packet_requirements')
order by table_name;
-- expect 3 rows

-- 2. broker_packet_status enum has exactly the 7 expected values.
select enumlabel from pg_enum e join pg_type t on t.oid = e.enumtypid
where t.typname = 'broker_packet_status' order by e.enumsortorder;
-- expect: draft, generating, generated, sent, superseded, failed, voided

-- 3. entity_type gained 'broker_packet'.
select enumlabel from pg_enum e join pg_type t on t.oid = e.enumtypid
where t.typname = 'entity_type' and e.enumlabel = 'broker_packet';
-- expect 1 row

-- 4. Key columns present on broker_packets, including the 2M.2B amendment.
select column_name, is_nullable, data_type from information_schema.columns
where table_schema = 'public' and table_name = 'broker_packets'
  and column_name in ('version', 'generated_pdf_sha256', 'document_count', 'superseded_by', 'superseded_at')
order by column_name;
-- expect version nullable, generated_pdf_sha256 nullable text, document_count not null,
-- superseded_by/superseded_at nullable

-- 5. Constraints present.
select conname from pg_constraint
where conrelid = 'public.broker_packets'::regclass
  and conname in ('broker_packet_version_required_once_reserved','broker_packet_generated_shape','broker_packet_failed_shape','broker_packet_superseded_shape');
-- expect 4 rows

select conname from pg_constraint where conrelid = 'public.broker_packet_items'::regclass
  and conname in ('broker_packet_item_hash_format','broker_packet_item_page_range');
-- expect 2 rows

-- 6. Indexes present, including the partial unique version index.
select indexname, indexdef from pg_indexes
where schemaname = 'public' and tablename = 'broker_packets' and indexname = 'broker_packets_broker_version_idx';
-- expect 1 row, indexdef containing "WHERE (version IS NOT NULL)"

-- 7. RLS enabled on all three tables.
select relname, relrowsecurity from pg_class
where oid in ('public.broker_packets'::regclass, 'public.broker_packet_items'::regclass, 'public.broker_packet_requirements'::regclass);
-- expect true for all three

-- 8. RLS policies: SELECT-only on packets/items (including viewer), full
-- CRUD minus viewer/driver on requirements.
select tablename, policyname, cmd from pg_policies
where schemaname = 'public' and tablename in ('broker_packets','broker_packet_items','broker_packet_requirements')
order by tablename, cmd;
-- expect exactly 1 SELECT policy each for broker_packets/broker_packet_items
-- (no insert/update/delete policy on either -- RPC-only), and 4 policies
-- (select/insert/update/delete) on broker_packet_requirements

-- 9. No raw INSERT/UPDATE/DELETE grant exists that would make an RLS-less
-- write path meaningful on the two immutable tables (defense in depth --
-- RLS with zero policies already blocks this, but confirm the grant
-- posture matches intent).
select grantee, privilege_type from information_schema.role_table_grants
where table_schema = 'public' and table_name in ('broker_packets','broker_packet_items') and grantee = 'authenticated'
order by table_name, privilege_type;
-- expect only SELECT (no INSERT/UPDATE/DELETE) for authenticated on either table

-- 10. Triggers present.
select tgname from pg_trigger where tgrelid = 'public.broker_packets'::regclass and not tgisinternal order by tgname;
-- expect: broker_packets_immutability_guard, broker_packets_relationship_guard, broker_packets_set_updated_at
select tgname from pg_trigger where tgrelid = 'public.broker_packet_items'::regclass and not tgisinternal order by tgname;
-- expect: broker_packet_items_guard, broker_packet_items_immutability_guard
select tgname from pg_trigger where tgrelid = 'public.broker_packet_requirements'::regclass and not tgisinternal order by tgname;
-- expect: broker_packet_requirements_organization_guard, broker_packet_requirements_set_updated_at
select tgname from pg_trigger where tgrelid = 'public.email_send_log'::regclass and not tgisinternal and tgname = 'email_send_log_broker_packet_org_guard';
-- expect 1 row; confirm the pre-existing setup-package equivalent trigger is untouched
select tgname from pg_trigger where tgrelid = 'public.email_send_log'::regclass and not tgisinternal and tgname = 'email_send_log_setup_package_org_guard';
-- expect 1 row, unchanged from 0087

-- 11. RPC existence + grants.
select p.proname, p.prosecdef, r.rolname as grantee
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
join aclexplode(p.proacl) a on true
join pg_roles r on r.oid = a.grantee
where n.nspname = 'public' and p.proname in (
  'create_broker_packet_draft','add_broker_packet_item','remove_broker_packet_item','reorder_broker_packet_items',
  'delete_broker_packet_draft','reserve_broker_packet','finalize_broker_packet','fail_broker_packet',
  'mark_broker_packet_sent','void_broker_packet'
)
order by p.proname, r.rolname;
-- expect: finalize_broker_packet and fail_broker_packet granted to service_role ONLY (no authenticated);
-- every other function granted to authenticated only (no public/anon anywhere)

-- 12. Storage bucket + policies.
select id, public, file_size_limit, allowed_mime_types from storage.buckets where id = 'broker-packets';
-- expect public=false, file_size_limit=52428800, allowed_mime_types={application/pdf}
select policyname, cmd from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname like 'broker_packets_storage_%';
-- expect 2 rows (select, insert)

-- 13. broker_has_protected_history() now includes broker_packets as its
-- seventh clause.
select pg_get_functiondef(p.oid) like '%broker_packets%' as includes_broker_packets
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname = 'broker_has_protected_history';
-- expect true

-- 14. broker_packets.broker_id FK is ON DELETE RESTRICT (not SET NULL/CASCADE).
select confdeltype from pg_constraint
where conrelid = 'public.broker_packets'::regclass and conname = 'broker_packets_broker_id_fkey';
-- expect 'r' (restrict)

-- 15. email_send_log gained broker_packet_id + FK to broker_packets.
select column_name from information_schema.columns
where table_schema = 'public' and table_name = 'email_send_log' and column_name = 'broker_packet_id';
-- expect 1 row

-- =============================================================================
-- 2M.2C additions.
-- =============================================================================

-- 16. Polymorphic document guards for carrier/organization exist.
select tgname from pg_trigger where tgrelid = 'public.documents'::regclass and not tgisinternal
  and tgname in ('guard_document_carrier_link_insert','guard_document_carrier_link_update',
                 'guard_document_organization_link_insert','guard_document_organization_link_update')
order by tgname;
-- expect 4 rows

-- 17. 'generating'->'superseded' is now a legal transition (2M.2C
-- amendment) -- read the transition graph out of the guard function's own
-- source and eyeball it directly (string-matching the exact transition
-- list is too fragile to assert mechanically; read the printed body).
select pg_get_functiondef(p.oid)
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname = 'guard_broker_packet_immutability';
-- expect the "old.status = 'generating'" branch to allow
-- ('generating','generated','superseded','failed')

-- 18. THE INVARIANT ITSELF, directly queryable post-apply and at any time
-- in production thereafter: at most one 'generated'/'sent' (non-voided,
-- non-superseded) broker_packets row per broker. Expect 0 rows always.
select broker_id, count(*) as current_count
from public.broker_packets
where status in ('generated', 'sent')
group by broker_id
having count(*) > 1;

-- 19. The current packet for any broker (if one exists) must be the
-- highest version among every row that ever successfully reached
-- 'generated'/'sent'/'superseded' for that broker -- i.e. no
-- 'superseded' row may outrank the live 'generated'/'sent' row. Expect 0
-- rows.
select cur.broker_id, cur.version as current_version, sup.version as superseded_version
from public.broker_packets cur
join public.broker_packets sup on sup.broker_id = cur.broker_id and sup.status = 'superseded'
where cur.status in ('generated', 'sent') and sup.version > cur.version;

-- =============================================================================
-- Behavioral / concurrency checks (NOT pure SQL -- run via authenticated
-- sessions using disposable TEST-2M2B-* fixtures, mirroring the 2M.1C/2M.1D
-- pattern):
--
--   a) owner/admin/dispatcher create_broker_packet_draft() -> draft row,
--      version NULL, document_count 0
--   b) accountant/viewer/driver/anonymous create_broker_packet_draft() ->
--      denied
--   c) add_broker_packet_item() with an eligible broker/carrier document ->
--      succeeds, document_count increments
--   d) add_broker_packet_item() with a foreign-org, unverified, rejected,
--      expired, wrong-MIME, or oversized document -> refused with the
--      guard trigger's specific message
--   e) reorder_broker_packet_items() with a full, correct item list ->
--      succeeds, no unique-constraint collision
--   f) reorder_broker_packet_items() with a partial/duplicate list ->
--      refused before any row changes
--   g) reserve_broker_packet() with a missing required document type ->
--      refused, packet remains draft, no version assigned
--   h) reserve_broker_packet() with requirements satisfied -> transitions
--      to generating, version assigned, all three snapshots populated,
--      EIN absent from carrier_snapshot, broker MC/DOT included only when
--      populated on the broker record
--   i) two concurrent reserve_broker_packet() calls for the SAME broker's
--      two different draft packets -> serialize via the advisory lock,
--      distinct versions, no duplicate version (mirrors 0087's proven
--      mechanism exactly)
--   j) delete_broker_packet_draft() on a non-draft packet -> refused
--   k) void_broker_packet() from draft -> succeeds, version stays NULL
--   l) void_broker_packet() from generated/sent -> succeeds, artifact
--      fields unchanged
--   m) attempted raw table INSERT/UPDATE/DELETE against broker_packets or
--      broker_packet_items as an authenticated user -> 42501/RLS-blocked
--      (no policy exists for those commands)
--   n) delete_broker_safely() / raw delete against a broker with ANY
--      broker_packets row (including a bare draft) -> refused, exactly
--      like 2M.1C's history matrix, now covering a 7th relationship
--   o) foreign-org read/mutation attempts against a broker packet -> generic
--      not-found/denied, no existence leak (mirrors 2M.1C section 15)
--
-- 2M.2C additions -- finalize_broker_packet() can be exercised directly
-- via service_role even though the render step it will eventually follow
-- is still deferred; these ARE runnable post-apply without waiting for
-- the next checkpoint, by calling finalize_broker_packet() with
-- synthetic-but-valid-looking arguments as service_role against
-- disposable draft packets:
--
--   p) reserve v1, reserve v2 (same broker), finalize v2, finalize v1 ->
--      v2 ends 'generated' (current), v1 ends 'superseded' with
--      superseded_by = v2.id; v1 NEVER observed as 'generated' at any
--      point (query broker_packets immediately after each finalize call
--      completes, not just at the end)
--   q) reserve v1, finalize v1, reserve v2, finalize v2, reserve v3
--      (leave 'generating'), fail v3 -> v2 remains 'generated'/current
--      throughout; v3 ends 'failed' with null artifact fields; v1 stays
--      'superseded'
--   r) with v2 current from (q), void_broker_packet(v2) -> v2 becomes
--      'voided'; v1 (already superseded) is NOT resurrected or altered;
--      no broker_packets row for this broker has status in
--      ('generated','sent') until a new version is reserved+finalized
--   s) attempt void_broker_packet() on an already-'superseded' row ->
--      refused ("not found or cannot be voided"), confirming superseded
--      stays terminal even under a deliberate misuse attempt
--   t) fire two finalize_broker_packet() calls for two different draft
--      packets of the SAME broker via Promise.all (genuine parallel-fire,
--      same technique as 2M.1C's race tests) repeated ~15x -> across all
--      trials, query 18/19's invariant queries after each trial and
--      confirm they always return 0 rows; also confirm no query ever
--      hangs (would indicate a deadlock, not just a race)
--   u) confirm delete_broker_safely()/raw delete refusal (2M.1C's
--      history matrix) is unaffected by any of the above -- a broker
--      with a 'superseded' or 'voided' broker_packets row is still
--      protected history exactly like a 'generated' one (the predicate
--      checks existence of ANY row, not status)
--   v) add_broker_packet_item() with an eligible 'carrier'-typed document
--      -> succeeds (2M.2C guard allows valid carrier docs through
--      unchanged)
--   w) add_broker_packet_item() with a random/foreign-org/nonexistent
--      carrier-typed document's id -> refused by
--      guard_document_carrier_link() at the documents-insert boundary,
--      never even reaching broker_packet_items (test this by attempting
--      a raw documents insert with entity_type='carrier' and a garbage
--      entity_id directly, not just through add_broker_packet_item())
--   x) attempt a documents insert with entity_type='organization' and an
--      entity_id different from organization_id -> refused by
--      guard_document_organization_link()
--   y) (documented limitation, not a test to pass) confirm a raw
--      `DELETE FROM carriers` against a carrier that already has a
--      'carrier'-typed document still succeeds today, orphaning that
--      document -- this is the known, out-of-scope gap from 0095's own
--      header comment; recorded here so it is never mistaken for
--      something 0095 was supposed to have closed
-- =============================================================================
