-- =============================================================================
-- CLEANUP_TEST_ORGS_2026_09.sql
--
-- One-off, manually authorized removal of the 57 disposable TEST-* fixture
-- organizations created during August 2026 live acceptance testing (2B, 2L*,
-- 2M*, 2N5, 2P2C, DISPATCH, EMAIL, GATE, INTEGRATIONS). NOT a migration.
--
-- HOW TO RUN (Supabase SQL Editor):
--   0. FIRST delete their stored files with scripts/cleanup-test-org-files.mjs
--      (Supabase does not allow deleting storage files from SQL).
--   1. Run this file AS IS. It is a DRY RUN: it performs every delete inside
--      one transaction, runs every safety check, then deliberately aborts with
--      an error message beginning "DRY RUN OK" that lists what it WOULD
--      delete. Nothing is changed.
--   2. Only if the dry run says "DRY RUN OK": change 'DRY_RUN' to 'COMMIT' on
--      the marked line below and run again. The final result table must show
--      zero leftovers.
--
-- SAFETY:
--   * Targets are the EXACT 57 organization ids from the 2026-09-30 read-only
--     inventory, AND must still be named/slugged test-*. If the count is not
--     exactly 57, it aborts before touching anything.
--   * Login accounts are captured once from those orgs' profiles, and the run
--     aborts if ANY of them has an email that does not look like a test
--     address.
--   * Guard triggers (immutability / permanent-delete guards) are suspended
--     only inside this transaction via session_replication_role = replica,
--     which reverts automatically at COMMIT/ROLLBACK.
--   * Because that also suspends foreign-key cascades, every foreign key in
--     the public schema is checked for broken references BEFORE and AFTER;
--     if the delete created even one new broken reference, the run aborts and
--     everything is rolled back.
--   * Every delete is scoped to organization_id in the captured id set.
-- =============================================================================

begin;

select set_config('cleanup.mode', 'DRY_RUN', true);   -- <<< change to 'COMMIT' for the real run

-- ---- 1. capture targets exactly once ---------------------------------------
create temporary table _t_orgs on commit drop as
select o.id
from public.organizations o
join (values
    ('cff1741f-482c-4dec-ae56-9aa96b437222'::uuid),
    ('77573b3e-b592-4a57-873d-730691e46664'::uuid),
    ('c8c54b0d-2884-4834-b157-fcf21b3771f4'::uuid),
    ('e0e1b6b7-a500-4f20-9c4a-19c90b4c9f4e'::uuid),
    ('f4fad9a1-361f-4b0c-8b46-b7a48375e834'::uuid),
    ('67fcdf5a-81af-46f2-b49a-2f299ea32933'::uuid),
    ('8e5d429d-f42e-493a-989d-6a8bfeeedc8f'::uuid),
    ('fb679df5-855a-461f-ba37-93372e20af84'::uuid),
    ('ab7acc7b-88c2-4bcd-8a9e-1aa885075a04'::uuid),
    ('3b447641-ae2e-41f9-95f2-4812fee76379'::uuid),
    ('29006a77-b880-4824-a92a-071f36ee2bbc'::uuid),
    ('1d6b5a35-c873-4b60-afe0-8a0e4511b0f8'::uuid),
    ('0f6dde3a-318b-4dca-ac8c-077144988468'::uuid),
    ('70a8b305-f4e4-41f4-996b-d8e0c10bfca9'::uuid),
    ('048151a4-e631-43d1-9cd7-016c33d77441'::uuid),
    ('5882ee05-468b-4bde-ac80-29c2a765e5f4'::uuid),
    ('253ea23e-2d5c-4526-8d4c-f97e485d2a24'::uuid),
    ('8b954676-1d2c-45e6-b782-50a6a18be673'::uuid),
    ('4c317e8e-63ea-4be4-b257-2fd66a2ed19f'::uuid),
    ('46e4b9f5-4b75-4804-b86f-4c763e69d3cf'::uuid),
    ('5e5c6fc1-ef93-4c96-98b2-33d2fcf98467'::uuid),
    ('90011a38-da5e-49c0-85a8-d28d59ff38f0'::uuid),
    ('b0b7d39a-538c-4025-b27d-8cf005cca265'::uuid),
    ('5cab052d-e873-42eb-a983-b5e82f609f85'::uuid),
    ('0595592d-bb41-45b4-b975-2e350b3f1c8f'::uuid),
    ('d5406dde-e16e-481d-9bca-50e384920316'::uuid),
    ('80345581-6e8f-494d-95e0-928e56cfc607'::uuid),
    ('b336c6eb-d663-4dd2-a9a9-ec329ba23578'::uuid),
    ('21cec5aa-b1cf-4351-8e57-184351d675c1'::uuid),
    ('87d3daae-73c3-4489-ab53-b2f8840478e2'::uuid),
    ('08e86b20-1c93-4cc3-b19c-ac949e96ed21'::uuid),
    ('6003480c-4b2d-42ac-9920-e4ee7567df16'::uuid),
    ('4eaaf343-a644-4359-88b7-0ce903a2d2d6'::uuid),
    ('cf4a79d6-aa11-4e76-bed0-3fadca473935'::uuid),
    ('21bb7b0c-8e74-460c-bd17-5c59d8ea77ae'::uuid),
    ('6543132f-8c8a-4bd9-bdc6-a9ab91cacd3b'::uuid),
    ('d8dd013f-5856-4911-b095-ef3520cad379'::uuid),
    ('64df4ebc-4c24-4b76-9be3-92ae05e9b052'::uuid),
    ('1a5cf430-c8e3-4e39-be13-ccdea79f37ce'::uuid),
    ('3ab05428-d4fb-4bcd-90c0-fe24642cfc6f'::uuid),
    ('4c7bf062-35ee-4c27-8ec3-ae402dc293cf'::uuid),
    ('096afba5-c76c-4092-8b9b-59146a6b8b61'::uuid),
    ('80b9f8e3-6958-4ac7-b6a3-401c7ff77022'::uuid),
    ('6023cf3b-d66d-4e20-871f-2837483261c6'::uuid),
    ('0adb64d6-4917-4c70-9afd-a4ab1c0e003e'::uuid),
    ('7378100f-9e42-4fce-87b7-8142bc10d754'::uuid),
    ('188f9b7d-caaf-4ae5-aab8-d85d759af681'::uuid),
    ('a1dea96d-5a30-4b76-bdec-3910d9bd29db'::uuid),
    ('f5040e1f-2986-449f-a747-2004bf295db3'::uuid),
    ('3839e890-f055-4dca-952d-0de0b1fdd789'::uuid),
    ('0dff921c-e114-4e73-a697-1e45eb7b80be'::uuid),
    ('47a44ff3-cacb-4f98-b548-6130df618d6b'::uuid),
    ('b8ac115b-0251-471a-8f66-e0fb71e6e03c'::uuid),
    ('a24bc06e-c381-436a-b1c0-1cf961269fc7'::uuid),
    ('84e06630-db6b-4826-8903-1e17ae8b7408'::uuid),
    ('0c52867f-86fb-4cad-b0a4-f845426aa86f'::uuid),
    ('1f2200b8-146e-4ea4-94fb-8e78b92002b9'::uuid)
) as allow(id) on allow.id = o.id
where o.name ilike 'test-%' or o.slug ilike 'test-%';

create temporary table _t_users on commit drop as
select p.id, u.email
from public.profiles p
left join auth.users u on u.id = p.id
where p.organization_id in (select id from _t_orgs);

create temporary table _t_report (tbl text primary key, n bigint) on commit drop;
create temporary table _t_fk_baseline (con_oid oid primary key, label text, orphans bigint) on commit drop;

do $$
declare n int; bad text;
begin
  select count(*) into n from _t_orgs;
  if n <> 57 then
    raise exception 'SAFETY STOP: expected exactly 57 TEST organizations, found %. Nothing was changed.', n;
  end if;
  select string_agg(coalesce(email, '(no auth account) ' || id::text), ', ') into bad
  from _t_users
  where email is null
     or not (email ilike '%@example.invalid' or email ilike '%@example.com'
             or email ilike '%@test.invalid' or email ilike 'test%');
  if bad is not null then
    raise exception 'SAFETY STOP: these accounts in TEST orgs do not look like test accounts: %. Nothing was changed.', bad;
  end if;
end $$;

-- ---- 2. broken-reference baseline over every public foreign key -------------
create or replace function pg_temp.fk_orphan_counts()
returns table (con_oid oid, label text, orphans bigint)
language plpgsql as $$
declare r record; nn text; cond text; q text; cnt bigint;
begin
  for r in
    select c.oid, c.conname, c.conrelid::regclass as child, c.confrelid::regclass as parent,
           array(select quote_ident(a.attname) from unnest(c.conkey) with ordinality k(attnum, ord)
                 join pg_attribute a on a.attrelid = c.conrelid and a.attnum = k.attnum order by k.ord) as ccols,
           array(select quote_ident(a.attname) from unnest(c.confkey) with ordinality k(attnum, ord)
                 join pg_attribute a on a.attrelid = c.confrelid and a.attnum = k.attnum order by k.ord) as pcols
    from pg_constraint c
    join pg_namespace n on n.oid = c.connamespace
    where c.contype = 'f' and n.nspname = 'public'
  loop
    select string_agg('c.' || x || ' is not null', ' and ') into nn from unnest(r.ccols) x;
    select string_agg('p.' || r.pcols[i] || ' = c.' || r.ccols[i], ' and ') into cond
      from generate_subscripts(r.ccols, 1) i;
    q := format('select count(*) from %s c where %s and not exists (select 1 from %s p where %s)',
                r.child, nn, r.parent, cond);
    execute q into cnt;
    con_oid := r.oid; label := r.child::text || ' -> ' || r.parent::text || ' (' || r.conname || ')'; orphans := cnt;
    return next;
  end loop;
end $$;

insert into _t_fk_baseline select * from pg_temp.fk_orphan_counts();

-- ---- 3. delete (guard triggers suspended for this transaction only) ---------
set local session_replication_role = replica;

do $$
declare t record; n bigint;
begin
  for t in
    select c.table_name
    from information_schema.columns c
    join information_schema.tables tb
      on tb.table_schema = c.table_schema and tb.table_name = c.table_name and tb.table_type = 'BASE TABLE'
    where c.table_schema = 'public' and c.column_name = 'organization_id'
    order by c.table_name
  loop
    execute format('delete from public.%I where organization_id in (select id from _t_orgs)', t.table_name);
    get diagnostics n = row_count;
    if n > 0 then insert into _t_report values (t.table_name, n); end if;
  end loop;
  delete from public.organizations where id in (select id from _t_orgs);
  get diagnostics n = row_count;
  insert into _t_report values ('organizations', n);
end $$;

set local session_replication_role = origin;

-- login accounts last, with normal cascades on (auth.identities, sessions, ...)
with d as (delete from auth.users where id in (select id from _t_users) returning 1)
insert into _t_report select 'auth.users', count(*) from d;

-- ---- 4. verify: no new broken references anywhere --------------------------
do $$
declare bad text;
begin
  select string_agg(a.label || ': ' || coalesce(b.orphans, 0) || ' -> ' || a.orphans, '; ') into bad
  from pg_temp.fk_orphan_counts() a
  left join _t_fk_baseline b on b.con_oid = a.con_oid
  where a.orphans > coalesce(b.orphans, 0);
  if bad is not null then
    raise exception 'SAFETY STOP: cleanup would leave broken references: %. Everything was rolled back.', bad;
  end if;
end $$;

-- ---- 5. stored files must already be gone (real run only) -------------------
do $$
declare files bigint; summary text; total bigint;
begin
  select count(*) into files from storage.objects s
  where split_part(s.name, '/', 1) in (select id::text from _t_orgs);
  select sum(n) into total from _t_report where tbl not in ('organizations', 'auth.users');
  select string_agg(tbl || '=' || n, ', ' order by n desc) into summary from _t_report;

  if current_setting('cleanup.mode') <> 'COMMIT' then
    raise exception 'DRY RUN OK -- nothing was changed. Would delete % organizations, % data rows, % login accounts. Stored files still present: %. Details: %',
      (select n from _t_report where tbl = 'organizations'), total,
      (select n from _t_report where tbl = 'auth.users'), files, summary;
  end if;
  if files > 0 then
    raise exception 'STOP: % stored files still exist for these organizations. Run scripts/cleanup-test-org-files.mjs --commit first. Everything was rolled back.', files;
  end if;
end $$;

commit;

-- ---- 6. after a real run: every value must be 0 -----------------------------
select
  (select count(*) from public.organizations
    where id in (
    ('cff1741f-482c-4dec-ae56-9aa96b437222'::uuid),
    ('77573b3e-b592-4a57-873d-730691e46664'::uuid),
    ('c8c54b0d-2884-4834-b157-fcf21b3771f4'::uuid),
    ('e0e1b6b7-a500-4f20-9c4a-19c90b4c9f4e'::uuid),
    ('f4fad9a1-361f-4b0c-8b46-b7a48375e834'::uuid),
    ('67fcdf5a-81af-46f2-b49a-2f299ea32933'::uuid),
    ('8e5d429d-f42e-493a-989d-6a8bfeeedc8f'::uuid),
    ('fb679df5-855a-461f-ba37-93372e20af84'::uuid),
    ('ab7acc7b-88c2-4bcd-8a9e-1aa885075a04'::uuid),
    ('3b447641-ae2e-41f9-95f2-4812fee76379'::uuid),
    ('29006a77-b880-4824-a92a-071f36ee2bbc'::uuid),
    ('1d6b5a35-c873-4b60-afe0-8a0e4511b0f8'::uuid),
    ('0f6dde3a-318b-4dca-ac8c-077144988468'::uuid),
    ('70a8b305-f4e4-41f4-996b-d8e0c10bfca9'::uuid),
    ('048151a4-e631-43d1-9cd7-016c33d77441'::uuid),
    ('5882ee05-468b-4bde-ac80-29c2a765e5f4'::uuid),
    ('253ea23e-2d5c-4526-8d4c-f97e485d2a24'::uuid),
    ('8b954676-1d2c-45e6-b782-50a6a18be673'::uuid),
    ('4c317e8e-63ea-4be4-b257-2fd66a2ed19f'::uuid),
    ('46e4b9f5-4b75-4804-b86f-4c763e69d3cf'::uuid),
    ('5e5c6fc1-ef93-4c96-98b2-33d2fcf98467'::uuid),
    ('90011a38-da5e-49c0-85a8-d28d59ff38f0'::uuid),
    ('b0b7d39a-538c-4025-b27d-8cf005cca265'::uuid),
    ('5cab052d-e873-42eb-a983-b5e82f609f85'::uuid),
    ('0595592d-bb41-45b4-b975-2e350b3f1c8f'::uuid),
    ('d5406dde-e16e-481d-9bca-50e384920316'::uuid),
    ('80345581-6e8f-494d-95e0-928e56cfc607'::uuid),
    ('b336c6eb-d663-4dd2-a9a9-ec329ba23578'::uuid),
    ('21cec5aa-b1cf-4351-8e57-184351d675c1'::uuid),
    ('87d3daae-73c3-4489-ab53-b2f8840478e2'::uuid),
    ('08e86b20-1c93-4cc3-b19c-ac949e96ed21'::uuid),
    ('6003480c-4b2d-42ac-9920-e4ee7567df16'::uuid),
    ('4eaaf343-a644-4359-88b7-0ce903a2d2d6'::uuid),
    ('cf4a79d6-aa11-4e76-bed0-3fadca473935'::uuid),
    ('21bb7b0c-8e74-460c-bd17-5c59d8ea77ae'::uuid),
    ('6543132f-8c8a-4bd9-bdc6-a9ab91cacd3b'::uuid),
    ('d8dd013f-5856-4911-b095-ef3520cad379'::uuid),
    ('64df4ebc-4c24-4b76-9be3-92ae05e9b052'::uuid),
    ('1a5cf430-c8e3-4e39-be13-ccdea79f37ce'::uuid),
    ('3ab05428-d4fb-4bcd-90c0-fe24642cfc6f'::uuid),
    ('4c7bf062-35ee-4c27-8ec3-ae402dc293cf'::uuid),
    ('096afba5-c76c-4092-8b9b-59146a6b8b61'::uuid),
    ('80b9f8e3-6958-4ac7-b6a3-401c7ff77022'::uuid),
    ('6023cf3b-d66d-4e20-871f-2837483261c6'::uuid),
    ('0adb64d6-4917-4c70-9afd-a4ab1c0e003e'::uuid),
    ('7378100f-9e42-4fce-87b7-8142bc10d754'::uuid),
    ('188f9b7d-caaf-4ae5-aab8-d85d759af681'::uuid),
    ('a1dea96d-5a30-4b76-bdec-3910d9bd29db'::uuid),
    ('f5040e1f-2986-449f-a747-2004bf295db3'::uuid),
    ('3839e890-f055-4dca-952d-0de0b1fdd789'::uuid),
    ('0dff921c-e114-4e73-a697-1e45eb7b80be'::uuid),
    ('47a44ff3-cacb-4f98-b548-6130df618d6b'::uuid),
    ('b8ac115b-0251-471a-8f66-e0fb71e6e03c'::uuid),
    ('a24bc06e-c381-436a-b1c0-1cf961269fc7'::uuid),
    ('84e06630-db6b-4826-8903-1e17ae8b7408'::uuid),
    ('0c52867f-86fb-4cad-b0a4-f845426aa86f'::uuid),
    ('1f2200b8-146e-4ea4-94fb-8e78b92002b9'::uuid)
    )) as leftover_target_orgs,
  (select count(*) from public.organizations where name ilike 'test-%' or slug ilike 'test-%') as remaining_test_named_orgs,
  (select count(*) from pg_trigger where not tgisinternal and tgenabled = 'D'
     and tgrelid::regclass::text like 'public.%') as disabled_triggers_in_public;
