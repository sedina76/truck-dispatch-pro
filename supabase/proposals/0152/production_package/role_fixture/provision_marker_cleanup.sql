-- provision_marker_cleanup.sql -- removes the F-30 marker (f30_test_control) provisioned by provision_marker.sql. See HOSTED_PROVISIONING_PLAN.md.
-- NOT EXECUTED BY ANYTHING IN THIS REPOSITORY. NOT APPLIED. This file MAKES NO HOSTED CONNECTION AND CHANGES NO DATABASE by itself -- paste it manually, and only after ALL fixture
-- work (role_fixture/cleanup.sql and the parent probe's own cleanup) is already complete and verified. Deliberately separate from cleanup.sql: the marker is the last thing removed,
-- never the first, so a partially-cleaned run can never leave the target looking like a fresh non-production project by accident. The guard below is the SAME guard cleanup.sql
-- itself runs on this marker (operator identity, full reference/environment/database/fixture validation, ownership/ACL drift, the explicit f30.expected_project_ref match, and the
-- shared advisory lock) -- not a weaker subset of it.
begin;
do $guard$
declare m record;
begin
  if current_user <> session_user then raise exception 'F30_OPERATOR_REQUIRED'; end if;
  if to_regclass('f30_test_control.marker') is null then raise exception 'provision_marker_cleanup: no marker exists -- nothing to remove. STOP.'; end if;
  select * into strict m from f30_test_control.marker;
  if m.environment is distinct from 'nonproduction-f30' or m.database_name is distinct from current_database()
     or m.project_ref is null
     or m.project_ref in ('zteixenjpcygjvznueuo', 'fjmrvvyjvqdyopnyetez')
     or m.project_ref like 'fjmrvvyjvqd%' or m.project_ref !~ '^[a-z0-9]{20}$'
     or m.fixture_id is distinct from 'F30_SYNTHETIC_ROLE_MODEL_V1'
     or (m.project_ref = 'localdisposablef30xx' and (inet_server_addr() is not null or current_database() <> 'frz_lab')) then
    raise exception 'provision_marker_cleanup: F30_TEST_TARGET_REFUSED -- the marker fails validation (format / forbidden reference / environment / database / fixture mismatch). STOP -- this may not be the marker you think it is.';
  end if;
  if exists(select 1 from pg_class c where c.oid = 'f30_test_control.marker'::regclass and c.relowner <> (select oid from pg_roles where rolname = current_user))
     or exists(select 1 from pg_class c cross join lateral aclexplode(coalesce(c.relacl, acldefault('r', c.relowner))) a
               where c.oid = 'f30_test_control.marker'::regclass and a.grantee <> c.relowner) then
    raise exception 'provision_marker_cleanup: F30_MARKER_OWNERSHIP_OR_ACL_DRIFT -- the marker''s owner or grants changed since it was provisioned. STOP.';
  end if;
  if current_setting('f30.expected_project_ref', true) is distinct from m.project_ref then
    raise exception 'provision_marker_cleanup: F30_EXPLICIT_TARGET_REQUIRED -- set f30.expected_project_ref to the same verified reference in this session before removing the marker.';
  end if;
  if to_regnamespace('f30_probe') is not null then
    raise exception 'provision_marker_cleanup: f30_probe still exists. STOP -- run role_fixture/cleanup.sql (the fixture cleanup) first; the marker is removed LAST.';
  end if;
  perform pg_advisory_xact_lock(303030157);  -- same lock reset.sql/cleanup.sql take
end
$guard$;
drop schema f30_test_control restrict; -- RESTRICT: any unexpected extra object in the schema aborts atomically rather than being silently swept away.
commit;
select to_regnamespace('f30_test_control') is null as marker_removed;
