-- provision_marker.sql -- HOSTED PROVISIONING STEP A (marker) for the F-30 role/organization fixture. See HOSTED_PROVISIONING_PLAN.md for the full procedure.
-- NOT EXECUTED BY ANYTHING IN THIS REPOSITORY. NOT APPLIED. NOT a migration; never place under supabase/migrations/. This file MAKES NO HOSTED CONNECTION AND CHANGES NO DATABASE by
-- itself -- it is inert text until an authorized human operator pastes it into the SQL Editor of a project they have ALREADY, INDEPENDENTLY verified against the Supabase dashboard
-- URL/Settings themselves (SQL run in the SQL Editor cannot know its own project ref, so this is a human gate, never a database gate -- exactly the discipline documentation.py/
-- discovery_guard.py use elsewhere in this package).
--
-- Before running: replace the ONE placeholder below (v_ref) with the verified 20-character project reference. Nothing else needs editing -- database_name is read safely from
-- current_database() and the environment/fixture id are fixed constants that must match what f30_probe.check_target() (model.sql) requires. Refuses (raises, nothing created) if the
-- placeholder was left untouched, the reference is malformed, or it is the production reference pattern / the deleted temporary test project / the local-disposable-harness sentinel.
-- Refuses (raises, nothing created) if f30_test_control already exists -- this script never overwrites an existing marker; run provision_marker_cleanup.sql first if a genuine
-- re-provision is intended. Also requires: this session is not running under SET ROLE (F30_OPERATOR_REQUIRED, matching fixture.sql/reset.sql/cleanup.sql exactly), and takes the
-- SAME shared advisory lock (303030157) those three files use, so a provisioning run can never race a concurrent fixture/reset/cleanup run on the same database.
begin;
do $marker$
declare
  v_ref text := 'REPLACE_WITH_VERIFIED_PROJECT_REF';  -- <- the ONLY edit required
begin
  if current_user <> session_user then
    raise exception 'provision_marker: F30_OPERATOR_REQUIRED -- this session is running under SET ROLE. STOP -- connect and run this as your own operator session, matching fixture.sql/reset.sql/cleanup.sql.';
  end if;
  if v_ref = 'REPLACE_WITH_VERIFIED_PROJECT_REF' then
    raise exception 'provision_marker: the placeholder project reference was not replaced. STOP -- edit v_ref above with the reference you verified against the dashboard, then re-run.';
  end if;
  if v_ref !~ '^[a-z0-9]{20}$' then
    raise exception 'provision_marker: "%" is not a well-formed 20-character lowercase-alphanumeric project reference. STOP.', v_ref;
  end if;
  if v_ref in ('zteixenjpcygjvznueuo', 'fjmrvvyjvqdyopnyetez') or v_ref like 'fjmrvvyjvqd%' then
    raise exception 'provision_marker: "%" is a forbidden reference (the production project or the deleted temporary test project). STOP.', v_ref;
  end if;
  if v_ref = 'localdisposablef30xx' then
    raise exception 'provision_marker: "localdisposablef30xx" is reserved for the LOCAL disposable test harness only (role_fixture/tests.py) and can never be a real hosted project reference. STOP.';
  end if;
  perform pg_advisory_xact_lock(303030157);  -- same lock fixture.sql/reset.sql/cleanup.sql take: serializes against a concurrent fixture/reset/cleanup run
  if to_regnamespace('f30_test_control') is not null then
    raise exception 'provision_marker: schema f30_test_control already exists on this database. STOP -- run provision_marker_cleanup.sql first if this is a genuine re-provision; never overwrite an existing marker.';
  end if;

  create schema f30_test_control;
  create table f30_test_control.marker (
    singleton      boolean primary key default true check (singleton),
    project_ref    text not null,
    environment    text not null,
    database_name  text not null,
    fixture_id     text not null,
    provisioned_at timestamptz not null default now()
  );
  insert into f30_test_control.marker (project_ref, environment, database_name, fixture_id)
  values (v_ref, 'nonproduction-f30', current_database(), 'F30_SYNTHETIC_ROLE_MODEL_V1');

  -- owner-only, no grants to any other role (f30_probe.check_target() refuses if this ever drifts)
  revoke all on schema f30_test_control from public, anon, authenticated, service_role;
  revoke all on table f30_test_control.marker from public, anon, authenticated, service_role;
end
$marker$;
commit;

-- Read-only verification -- run separately, immediately after, and confirm every column by eye before proceeding to the next step. This is exactly what
-- f30_probe.check_target() / public.f30_probe_context() will read; it changes nothing.
select m.project_ref, m.environment, m.database_name, m.fixture_id, m.provisioned_at,
       (select count(*) from f30_test_control.marker) as row_count,
       (select c.relowner = (select oid from pg_roles where rolname = current_user) from pg_class c where c.oid = 'f30_test_control.marker'::regclass) as owned_by_this_session,
       not exists (
         select 1 from pg_class c cross join lateral aclexplode(coalesce(c.relacl, acldefault('r', c.relowner))) a
         where c.oid = 'f30_test_control.marker'::regclass and a.grantee <> c.relowner
       ) as no_grants_to_other_roles
from f30_test_control.marker m;
