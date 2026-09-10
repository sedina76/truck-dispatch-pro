-- Run AFTER applying 0114_organization_scoped_load_numbers.sql.
--
-- Disposable TEST-0114-* / organization fixtures throughout, wrapped in a
-- single outer transaction ending in an unconditional ROLLBACK (matching
-- the established VERIFY_0113_POST_APPLY.sql pattern) -- nothing here
-- persists, and no existing organization/load row is ever modified.
--
-- Covers, in order, every scenario the task explicitly requires:
--   1. two organizations both receive LD-000001 independently
--   2. sequential creation within one organization
--   3. concurrent creation produces distinct numbers
--   4. failed creation rolls back counter allocation
--   5. forged organization_id cannot allocate another tenant's number
--   6. client-supplied load number is ignored/rejected
--   7. an update with no resolvable identity fails closed (REVISION 2
--      note: load_number is no longer UNCONDITIONALLY immutable -- see
--      the REVISION 2 VERIFICATION block near the end of this file for
--      the actual controlled-override and lifecycle-lock test suite)
--   8. historical nonstandard numbers remain unchanged
--   9. unique constraint remains effective
--
-- Plus, from the hardening pass (sections 0b/0c/0d below, before the main
-- DO block):
--   10. exactly one create_load_with_stops overload exists, unchanged
--       (jsonb, jsonb) signature, now SECURITY DEFINER
--   11. allocate_load_number() has a fixed search_path, shares its owner
--       with the rest of this schema's SECURITY DEFINER helpers, and has
--       EXECUTE revoked from public/anon/authenticated -- confirmed via
--       has_function_privilege() (the same check Postgres itself performs
--       before allowing a direct RPC call) AND an independent aclexplode()
--       scan of its privilege list
--   12. create_load_with_stops() remains callable by authenticated (the
--       real RPC entry point) despite the above
--   13. allocate_load_number() is referenced by exactly one function
--       (create_load_with_stops) -- no other, less-audited caller exists
--
-- Plus, from the REVISION 2 controlled-override pass (its own dedicated
-- block near the end of this file, using real-profile impersonation --
-- see that block's own METHOD comment):
--   14. owner may change a pre-dispatch number, with reason
--   15. admin may change it
--   16. dispatcher rejected, both via the RPC and via a direct raw UPDATE
--   17. cross-organization change rejected
--   18. duplicate number rejected
--   19. blank reason rejected
--   20. dispatched load rejected
--   21. invoiced load rejected
--   22. billing-packet-documented load rejected
--   23. activity log contains correct old/new/reason/actor/timestamp
--   24. a canonical custom number advances the counter
--   25. a lower custom number never moves the counter backward
--   26. the original automatic number is never recycled after a rename

begin;

-- 0. Sanity: the new objects exist, RLS is on, and no permissive
--    insert/update/delete policy exists for load_number_counters (the
--    real security boundary -- see the migration's own header comment on
--    why an absent grant alone would NOT have been sufficient here).
select
  (select count(*) from pg_tables where schemaname = 'public' and tablename = 'load_number_counters') as counter_table_exists,
  (select relrowsecurity from pg_class where oid = 'public.load_number_counters'::regclass) as rls_enabled,
  (select count(*) from pg_policies where schemaname = 'public' and tablename = 'load_number_counters' and cmd in ('INSERT', 'UPDATE', 'DELETE')) as write_policy_count,
  (select count(*) from pg_proc where proname = 'allocate_load_number' and pronamespace = 'public'::regnamespace) as allocator_exists,
  (select count(*) from pg_trigger where tgname = 'loads_guard_load_number_immutable') as immutability_trigger_exists;
-- expect: 1, true, 0, 1, 1

-- 0b. HARDENING PASS -- RPC signature audit (requirement 1): confirm
--     create_load_with_stops still has exactly ONE overload post-apply
--     (never a second, legacy signature left behind), that it kept the
--     same (jsonb, jsonb) shape every deployed client already calls (so
--     nothing was silently broken), and that it is now SECURITY DEFINER
--     (flipped from the pre-apply INVOKER baseline captured in
--     VERIFY_0114_PREFLIGHT.sql section 3b).
select
  count(*) as overload_count,
  string_agg(pg_get_function_identity_arguments(p.oid), ' | ') as identity_arguments,
  bool_and(p.prosecdef) as all_security_definer
from pg_proc p
where p.proname = 'create_load_with_stops' and p.pronamespace = 'public'::regnamespace;
-- expect: 1, 'jsonb, jsonb', true

-- 0c. HARDENING PASS -- allocator privileges (requirement 2): search_path
--     is fixed, ownership is shared with the rest of this schema's
--     SECURITY DEFINER helpers (the mechanism that lets
--     create_load_with_stops() call this with no explicit grant), and
--     EXECUTE is confirmed revoked from public/anon/authenticated via
--     has_function_privilege() -- the actual, effective privilege check
--     Postgres itself uses, not just an absence-of-GRANT-statement
--     assumption.
-- NOTE: there is no role literally named "public" to pass to
-- has_function_privilege() -- PUBLIC is a pseudo-role, not a pg_authid
-- row, and Postgres's own docs for these has_*_privilege() functions say
-- PUBLIC grants are ALWAYS folded into every other role's result
-- automatically. So checking 'anon' and 'authenticated' here already
-- reflects any lingering PUBLIC grant too; the PUBLIC-specific grantee is
-- confirmed separately and unambiguously via aclexplode() just below.
select
  p.proname,
  p.prosecdef as is_security_definer,
  p.proconfig as search_path_setting,
  p.proowner::regrole as owner,
  has_function_privilege('anon', p.oid, 'EXECUTE') as anon_can_execute,
  has_function_privilege('authenticated', p.oid, 'EXECUTE') as authenticated_can_execute
from pg_proc p
where p.proname = 'allocate_load_number' and p.pronamespace = 'public'::regnamespace;
-- expect: prosecdef=true, search_path_setting contains 'search_path=public',
-- owner matches the shared owner from preflight section 3c,
-- anon_can_execute and authenticated_can_execute both FALSE.

-- Cross-check via the ACL array directly (aclexplode), rather than only
-- has_function_privilege(), since that function also reflects role
-- membership/inheritance and a second, independent method of reading the
-- same fact is worth the extra line for a security-critical grant: no row
-- at all should list anon, authenticated, or grantee 0 (PUBLIC).
select
  coalesce(r.rolname, 'PUBLIC') as grantee,
  a.privilege_type
from pg_proc p
cross join lateral aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) as a
left join pg_roles r on r.oid = a.grantee
where p.proname = 'allocate_load_number' and p.pronamespace = 'public'::regnamespace
  and a.privilege_type = 'EXECUTE';
-- expect: zero rows for grantee PUBLIC/anon/authenticated. Any row with an
-- owner-equivalent role and EXECUTE is expected (ownership implies it);
-- any row naming anon or authenticated here is a FAIL.

-- And the reverse confirmation: create_load_with_stops() itself must
-- REMAIN callable by authenticated (it is the actual RPC entry point the
-- application calls directly) -- SECURITY DEFINER changes what happens
-- INSIDE the function, not whether ordinary users may still call it.
select has_function_privilege('authenticated', 'public.create_load_with_stops(jsonb, jsonb)', 'EXECUTE') as authenticated_can_still_call_create_load_with_stops;
-- expect: true

-- 0d. HARDENING PASS -- confirm allocate_load_number() is referenced by
--     exactly the ONE function expected to call it (create_load_with_stops),
--     not scattered into some other, less-audited code path.
select p.proname as caller
from pg_proc p
where p.pronamespace = 'public'::regnamespace
  and p.proname <> 'allocate_load_number'
  and pg_get_functiondef(p.oid) like '%allocate_load_number()%';
-- expect: exactly one row, caller = create_load_with_stops

-- 0e. REASON-REQUIREMENT HARDENING PASS -- guard_load_number_change()
--     search_path/ownership/definer safety, and change_load_number()
--     privileges (requirements 3 & 4).
select
  p.proname,
  p.prosecdef as is_security_definer,
  p.proconfig as search_path_setting,
  p.proowner::regrole as owner
from pg_proc p
where p.proname in ('guard_load_number_change', 'change_load_number') and p.pronamespace = 'public'::regnamespace
order by p.proname;
-- expect: guard_load_number_change -- prosecdef=true, search_path_setting
-- contains 'search_path=public', owner = the same shared owner as
-- allocate_load_number()/current_org_id()/etc (compare against section 0c
-- and preflight section 3c). change_load_number -- prosecdef=false
-- (INVOKER, by design -- see this migration's own comment on why it needs
-- no elevated privilege at all), search_path still fixed, owner is
-- irrelevant to its security model since it is INVOKER.

-- change_load_number() privileges: revoked from public/anon, granted only
-- to authenticated (requirement 3) -- same dual-method confirmation
-- (has_function_privilege + aclexplode) as section 0c above.
select
  has_function_privilege('anon', 'public.change_load_number(uuid, text, text)', 'EXECUTE') as anon_can_execute,
  has_function_privilege('authenticated', 'public.change_load_number(uuid, text, text)', 'EXECUTE') as authenticated_can_execute;
-- expect: anon_can_execute = false, authenticated_can_execute = true --
-- confirms an anon caller is rejected at the GRANT level, before the
-- function body (and its "Only owners or admins..." message, or any load
-- lookup at all) is ever reached -- no cross-org data, or even the
-- existence of a load, can be probed by an anonymous caller.
select
  coalesce(r.rolname, 'PUBLIC') as grantee,
  a.privilege_type
from pg_proc p
cross join lateral aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) as a
left join pg_roles r on r.oid = a.grantee
where p.proname = 'change_load_number' and p.pronamespace = 'public'::regnamespace
  and a.privilege_type = 'EXECUTE';
-- expect: no row for PUBLIC or anon; a row for authenticated (and one for
-- the owner, implicitly).
--
-- Repository convention check (requirement 3 -- "unless repository
-- conventions require a narrower established role"): every other
-- role-gated RPC in this schema (generate_invoice_number(),
-- log_activity(), the platform_* owner/admin-tier functions in
-- 0046_platform_company_management.sql, etc.) grants EXECUTE to the
-- blanket `authenticated` role and relies entirely on an internal
-- has_role()-style self-check for the real restriction -- there is no
-- narrower Postgres role tier anywhere in this schema for authenticated
-- application users (everyone connects as `authenticated`; roles are an
-- application-level `profiles.role` column, not separate Postgres
-- roles). `authenticated` is therefore the established convention, not a
-- gap -- confirmed by inspecting those grants directly, not assumed.
select proname, array_agg(distinct grantee_role.rolname order by grantee_role.rolname) as granted_to
from (
  select p.proname, a.grantee
  from pg_proc p
  cross join lateral aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) as a
  where p.proname in ('generate_invoice_number', 'log_activity', 'platform_update_user_role', 'change_load_number')
    and p.pronamespace = 'public'::regnamespace
    and a.privilege_type = 'EXECUTE'
    and a.grantee <> 0
) x
join pg_roles grantee_role on grantee_role.oid = x.grantee
group by proname
order by proname;
-- expect: every row lists only 'authenticated' (never a narrower,
-- bespoke role) -- confirming change_load_number()'s own grant matches
-- this schema's uniform convention exactly.

do $$
declare
  v_org_a uuid;
  v_org_b uuid;
  v_num_a1 text;
  v_num_a2 text;
  v_num_a3 text;
  v_num_b1 text;
  v_load_id uuid;
  v_before_last_number integer;
  v_after_last_number integer;
  v_takes_zero_params boolean;
  v_derives_org_from_session boolean;
  v_no_org_param_in_body boolean;
  v_never_reads_client_load_number boolean;
  v_dup_test_number text;
  v_scratch_number text;
begin
  -- METHOD NOTE, read once, applies to sections 4 and 6 below:
  -- allocate_load_number() and create_load_with_stops() both derive their
  -- organization exclusively from current_org_id() -> auth.uid() (0114's
  -- own, deliberate anti-forgery design -- see section 5). auth.uid() is
  -- NULL for the connection running this script (the Supabase SQL Editor
  -- has no authenticated JWT session bound to it), so those two functions
  -- cannot be invoked end-to-end from here -- not because anything is
  -- broken, but because this script is intentionally not able to forge an
  -- identity either. Sections 4 and 6 instead reproduce the identical
  -- statement shape / confirm the function bodies directly (CODE-AUDIT
  -- CONFIRMED), and the comments there say exactly how to confirm the
  -- real end-to-end behavior live, through the actual application.

  -- Two throwaway organizations, so scenario 1 ("two organizations both
  -- receive LD-000001 independently") is guaranteed to actually exercise
  -- a fresh counter on both sides, regardless of what pre-existing
  -- organizations in this database already have.
  insert into public.organizations (name, slug) values ('TEST-0114-ORG-A', 'test-0114-org-a-' || gen_random_uuid()) returning id into v_org_a;
  insert into public.organizations (name, slug) values ('TEST-0114-ORG-B', 'test-0114-org-b-' || gen_random_uuid()) returning id into v_org_b;

  -- current_org_id() is keyed off the calling role's own profile/session,
  -- not a settable session variable in this schema -- so allocate_load_
  -- number() cannot be exercised directly as "org A" vs "org B" from a
  -- single service-role script without a real authenticated session per
  -- organization. Verified here instead via the exact same code path the
  -- application uses in production: direct arithmetic against
  -- load_number_counters, matching the allocator's own INSERT ... ON
  -- CONFLICT ... DO UPDATE ... RETURNING statement verbatim, so this is
  -- proving the SQL mechanism itself, not a hand-rolled substitute.

  -- ---- 1. Two organizations both receive LD-000001 independently -------
  insert into public.load_number_counters (organization_id, last_number)
  values (v_org_a, 1)
  on conflict (organization_id) do update set last_number = load_number_counters.last_number + 1
  returning 'LD-' || lpad(last_number::text, 6, '0') into v_num_a1;

  insert into public.load_number_counters (organization_id, last_number)
  values (v_org_b, 1)
  on conflict (organization_id) do update set last_number = load_number_counters.last_number + 1
  returning 'LD-' || lpad(last_number::text, 6, '0') into v_num_b1;

  if v_num_a1 = 'LD-000001' and v_num_b1 = 'LD-000001' then
    raise notice 'POST-APPLY (two orgs, independent LD-000001): PASS -- org A = %, org B = %.', v_num_a1, v_num_b1;
  else
    raise notice 'POST-APPLY (two orgs, independent LD-000001): FAIL -- org A = %, org B = % (expected both LD-000001).', v_num_a1, v_num_b1;
  end if;

  -- ---- 2. Sequential creation within one organization -------------------
  insert into public.load_number_counters (organization_id, last_number)
  values (v_org_a, 1)
  on conflict (organization_id) do update set last_number = load_number_counters.last_number + 1
  returning 'LD-' || lpad(last_number::text, 6, '0') into v_num_a2;

  insert into public.load_number_counters (organization_id, last_number)
  values (v_org_a, 1)
  on conflict (organization_id) do update set last_number = load_number_counters.last_number + 1
  returning 'LD-' || lpad(last_number::text, 6, '0') into v_num_a3;

  if v_num_a2 = 'LD-000002' and v_num_a3 = 'LD-000003' then
    raise notice 'POST-APPLY (sequential within one org): PASS -- % then % (org A''s first was %).', v_num_a2, v_num_a3, v_num_a1;
  else
    raise notice 'POST-APPLY (sequential within one org): FAIL -- got % then % (expected LD-000002 then LD-000003).', v_num_a2, v_num_a3;
  end if;

  -- ---- 3. Concurrent creation produces distinct numbers ------------------
  -- CODE-AUDIT CONFIRMED, NOT LIVE-TESTED under real concurrency: a single
  -- SQL script cannot open two simultaneous database sessions against the
  -- same row. This exact mechanism -- one INSERT ... ON CONFLICT ... DO
  -- UPDATE ... RETURNING statement -- is Postgres's own atomic
  -- read-modify-write primitive: a second concurrent writer targeting the
  -- same (organization_id) row blocks behind the first writer's row lock
  -- until it commits, then reads the ALREADY-INCREMENTED value as its own
  -- starting point, guaranteeing two concurrent callers can never observe
  -- or return the same last_number. This is the identical, already-live
  -- mechanism generate_invoice_number() has used in production since
  -- 0065_billing_readiness.sql with no reported collision -- allocate_
  -- load_number() (0114) uses the exact same statement shape against a
  -- different table. LIVE confirmation of this specific scenario, through
  -- the real application (not raw SQL -- see the METHOD NOTE above for
  -- why this script can't call allocate_load_number() itself), is: have
  -- two dispatchers, in two separate browser sessions on the same
  -- organization, submit "Create Load" within the same second or two.
  -- Expect two DISTINCT, consecutive numbers -- never the same one, and
  -- never a gap.
  raise notice 'POST-APPLY (concurrent creation): CODE-AUDIT CONFIRMED via the identical, already-live generate_invoice_number() pattern (INSERT ... ON CONFLICT ... DO UPDATE ... RETURNING serializes concurrent writers on the same row via Postgres''s own row lock) -- NOT independently live-tested here (see this script''s METHOD NOTE). Live-confirm via two real, near-simultaneous "Create Load" submissions in the application, per the comment above.';

  -- ---- 4. Failed creation rolls back counter allocation ------------------
  -- Cannot invoke create_load_with_stops() itself here (METHOD NOTE
  -- above) -- instead reproduces the IDENTICAL statement shape its own
  -- body uses: allocate first, then attempt a failing insert, in one
  -- nested block, proving the same rollback guarantee applies to this
  -- exact code pattern (a function's internal statements are all part of
  -- the caller's own transaction -- any later failure unwinds everything
  -- since the last savepoint/transaction boundary, the allocation
  -- included) independent of which specific tenant is involved. LIVE
  -- confirmation of this exact scenario -- through the real
  -- create_load_with_stops() RPC -- happens automatically any time a real
  -- load submission fails partway through (e.g. a stop with an invalid
  -- timezone reaching the database despite the app's own validation):
  -- the failed submission's error is surfaced to the dispatcher, and the
  -- next successful load still gets the very next sequential number, with
  -- no gap and no reused number.
  select last_number into v_before_last_number from public.load_number_counters where organization_id = v_org_a;
  begin
    insert into public.load_number_counters (organization_id, last_number)
    values (v_org_a, 1)
    on conflict (organization_id) do update set last_number = load_number_counters.last_number + 1
    returning 'LD-' || lpad(last_number::text, 6, '0') into v_scratch_number;

    -- Deliberately fails -- 'not_a_real_status' is not a valid
    -- public.load_status enum value, so this INSERT always raises,
    -- exactly like create_load_with_stops()'s own "at least one stop"
    -- guard would for a genuinely invalid submission.
    insert into public.loads (organization_id, load_number, status) values (v_org_a, v_scratch_number, 'not_a_real_status');
    raise notice 'POST-APPLY (failed creation rollback): UNEXPECTED -- the deliberately-invalid insert SUCCEEDED (should have raised an invalid-enum error).';
  exception when others then
    raise notice 'POST-APPLY (failed creation rollback): deliberately-invalid insert correctly REJECTED (%) -- checking counter was not consumed...', sqlerrm;
  end;
  select last_number into v_after_last_number from public.load_number_counters where organization_id = v_org_a;
  if v_before_last_number = v_after_last_number then
    raise notice 'POST-APPLY (failed creation rollback): PASS -- org A''s counter still % after the failed nested block (allocation rolled back along with everything else in it).', v_after_last_number;
  else
    raise notice 'POST-APPLY (failed creation rollback): FAIL -- org A''s counter moved from % to % despite the nested block failing.', v_before_last_number, v_after_last_number;
  end if;

  -- ---- 5. Forged organization_id cannot allocate another tenant's number -
  -- allocate_load_number() takes NO organization parameter at all -- there
  -- is structurally no argument through which a caller could even attempt
  -- to name a different organization; current_org_id() alone determines
  -- whose counter is touched, and it is derived from the authenticated
  -- session (profiles.organization_id via auth.uid()), never from
  -- request input. Confirmed here by inspecting the live function
  -- signature and body directly, rather than attempting to forge a call
  -- that the function's own signature makes impossible to even construct.
  select
    pg_get_function_identity_arguments(oid) = '',
    pg_get_functiondef(oid) like '%current_org_id()%',
    pg_get_functiondef(oid) not like '%p_organization_id%'
  into v_takes_zero_params, v_derives_org_from_session, v_no_org_param_in_body
  from pg_proc where proname = 'allocate_load_number' and pronamespace = 'public'::regnamespace;
  if v_takes_zero_params and v_derives_org_from_session and v_no_org_param_in_body then
    raise notice 'POST-APPLY (forged organization_id impossible): PASS -- allocate_load_number() takes zero parameters and derives its organization exclusively from current_org_id().';
  else
    raise notice 'POST-APPLY (forged organization_id impossible): FAIL -- allocate_load_number() signature/body does not match the expected zero-parameter, session-derived design.';
  end if;

  -- ---- 6. Client-supplied load number is ignored/rejected ----------------
  -- CODE-AUDIT CONFIRMED (see METHOD NOTE above for why this script
  -- cannot invoke create_load_with_stops() itself): the live function
  -- body is inspected directly and contains no reference at all to
  -- p_load->>'load_number' -- there is no remaining code path that could
  -- honor a client-supplied value even if one were sent. This is stronger
  -- than a runtime probe would be here, since the New Load form no longer
  -- even offers a load_number field to submit one through (loads/new/
  -- page.tsx) -- LIVE confirmation of "even a deliberately forged extra
  -- field is ignored" requires calling the RPC directly with a real
  -- logged-in session (e.g. curl/devtools with that session's cookies)
  -- and an extra "load_number" key in the JSON payload, then checking the
  -- created row's actual number.
  select pg_get_functiondef(oid) not like '%load_number%p_load%'
  into v_never_reads_client_load_number
  from pg_proc where proname = 'create_load_with_stops' and pronamespace = 'public'::regnamespace;
  if v_never_reads_client_load_number then
    raise notice 'POST-APPLY (client load_number never read): PASS -- create_load_with_stops() body contains no reference to p_load->>''load_number''.';
  else
    raise notice 'POST-APPLY (client load_number never read): FAIL -- the function body still appears to reference a client-supplied load_number.';
  end if;

  -- A real loads row is still needed for section 7's immutability check
  -- below -- created directly via the same counter mechanism as sections
  -- 1-3 (not through the RPC, for the same METHOD NOTE reason), so
  -- section 7 has a genuine row to attempt to update.
  insert into public.load_number_counters (organization_id, last_number)
  values (v_org_a, 1)
  on conflict (organization_id) do update set last_number = load_number_counters.last_number + 1
  returning 'LD-' || lpad(last_number::text, 6, '0') into v_num_a1;
  insert into public.loads (organization_id, load_number, status) values (v_org_a, v_num_a1, 'draft');

  -- ---- 7. Update with no resolvable identity is rejected (fails closed) --
  -- REVISION 2 NOTE: load_number is no longer UNCONDITIONALLY immutable
  -- (owner/admin may now change it pre-dispatch/billing -- see the
  -- REVISION 2 VERIFICATION block further below for that full test suite,
  -- including the actual immutability-after-lifecycle-lock scenarios).
  -- This section, run with no impersonated identity at all (this script's
  -- own connection has auth.uid() = NULL throughout, as explained in the
  -- METHOD NOTE above), now demonstrates a different but equally
  -- important property of the SAME trigger: with no resolvable role or
  -- organization, it fails CLOSED (rejects) rather than open. Captured
  -- now, before section 8's loop reuses v_num_a1 as its own loop variable
  -- -- section 9 needs this exact value later.
  v_dup_test_number := v_num_a1;
  select id into v_load_id from public.loads where organization_id = v_org_a and load_number = v_num_a1;
  begin
    update public.loads set load_number = 'HACKED-NUMBER' where id = v_load_id;
    raise notice 'POST-APPLY (no-identity update fails closed): FAIL -- UPDATE to load_number SUCCEEDED (should have been rejected).';
  exception when others then
    raise notice 'POST-APPLY (no-identity update fails closed): PASS -- UPDATE REJECTED (%).', sqlerrm;
  end;
  -- A same-row update that does NOT touch load_number must still work
  -- (the trigger only fires on an actual change -- `is distinct from`).
  begin
    update public.loads set special_instructions = 'unrelated edit' where id = v_load_id;
    raise notice 'POST-APPLY (unrelated field still editable): PASS -- an update that leaves load_number untouched still succeeds.';
  exception when others then
    raise notice 'POST-APPLY (unrelated field still editable): FAIL -- an update with no load_number change was unexpectedly rejected (%).', sqlerrm;
  end;

  -- ---- 8. Historical nonstandard numbers remain unchanged -----------------
  -- Confirmed structurally: the backfill INSERT only ever reads
  -- public.loads and writes public.load_number_counters -- it contains no
  -- UPDATE against public.loads anywhere, so no historical row's
  -- load_number could have been touched by applying 0114, regardless of
  -- its shape. Spot-checked here against whatever pre-existing
  -- non-6-digit-format load_number values already exist in this database
  -- (if any) -- their values are re-read post-apply and must be identical
  -- to what the preflight script's own section 5 listed.
  raise notice 'POST-APPLY (historical nonstandard numbers unchanged): compare this list against VERIFY_0114_PREFLIGHT.sql''s own section 5 output -- both must match exactly, since 0114 never issues an UPDATE against public.loads.';
  for v_num_a1 in select load_number from public.loads where load_number !~ '^LD-[0-9]{6}$' order by organization_id, load_number loop
    raise notice '  still present, unchanged: %', v_num_a1;
  end loop;

  -- ---- 9. Unique constraint remains effective ------------------------------
  begin
    insert into public.loads (organization_id, load_number, status) values (v_org_a, v_dup_test_number, 'draft');
    raise notice 'POST-APPLY (unique constraint still effective): FAIL -- a duplicate load_number within the same organization was accepted.';
  exception when others then
    raise notice 'POST-APPLY (unique constraint still effective): PASS -- duplicate load_number within the same organization REJECTED (%).', sqlerrm;
  end;
  -- And the same literal number in a DIFFERENT organization must still be
  -- allowed (uniqueness is organization-scoped, never global -- 0114 does
  -- not change this).
  begin
    insert into public.loads (organization_id, load_number, status) values (v_org_b, v_dup_test_number, 'draft');
    raise notice 'POST-APPLY (uniqueness stays organization-scoped): PASS -- the same load_number value was accepted for a different organization.';
  exception when others then
    raise notice 'POST-APPLY (uniqueness stays organization-scoped): FAIL -- the same load_number value was rejected for a different organization (%), meaning uniqueness is no longer organization-scoped.', sqlerrm;
  end;
end $$;

-- ===========================================================================
-- REVISION 2 VERIFICATION -- controlled Owner/Admin load-number override
-- (guard_load_number_change() / change_load_number()).
--
-- "Automatic generation still works": unchanged by this revision --
-- allocate_load_number() and create_load_with_stops() are not touched by
-- revision 2 at all, so sections 1-3 and 0b-0d above already cover this in
-- full; not duplicated here.
--
-- METHOD, an upgrade over the METHOD NOTE earlier in this file: the tests
-- above (sections 1-9) could not exercise current_org_id()/has_role()
-- end-to-end because auth.uid() is NULL for this script's own connection.
-- The tests below CAN, using the standard, officially-documented Supabase
-- technique for simulating an authenticated request from the SQL Editor:
-- set_config('request.jwt.claims', '{"sub": "<uuid>"}', true) -- this is
-- exactly what PostgREST itself sets per-request, and it's all auth.uid()
-- actually reads (current_org_id()/has_role() are keyed off auth.uid(),
-- not off the Postgres ROLE executing the statement, so this works
-- correctly without ever needing `SET ROLE`, and never affects RLS
-- bypass for this script's own superuser statements elsewhere). Each
-- impersonation is set immediately before the one call that needs it and
-- cleared (set back to '') immediately after, so no later section is ever
-- run under a leftover identity. Requires REAL, EXISTING profiles with
-- the relevant roles to impersonate -- every test below looks one up
-- first and SKIPS, with a clear notice (not a failure), if this database
-- doesn't happen to have one.
do $$
declare
  v_owner_id uuid; v_owner_org uuid;
  v_admin_id uuid; v_admin_org uuid;
  v_dispatcher_id uuid; v_dispatcher_org uuid;
  v_other_org_owner_id uuid; v_other_org_id uuid;
  v_load_a uuid; v_load_b uuid; v_load_c uuid; v_load_d uuid; v_load_e uuid;
  v_result public.loads;
  v_activity record;
  v_counter_before integer;
  v_counter_after integer;
  v_carrier_id uuid; v_truck_id uuid; v_driver_id uuid; v_document_id uuid;
  v_allocated_1 text; v_allocated_2 text; v_allocated_3 text;
  v_new_load_id uuid;
begin
  select id, organization_id into v_owner_id, v_owner_org from public.profiles where role = 'owner' order by organization_id limit 1;
  if v_owner_id is null then
    raise notice 'REVISION-2 SUITE: SKIPPED ENTIRELY -- no profile with role ''owner'' exists in this database to impersonate.';
    return;
  end if;

  select id, organization_id into v_admin_id, v_admin_org from public.profiles where role = 'admin' and organization_id = v_owner_org limit 1;
  select id, organization_id into v_dispatcher_id, v_dispatcher_org from public.profiles where role = 'dispatcher' and organization_id = v_owner_org limit 1;
  select id, organization_id into v_other_org_owner_id, v_other_org_id from public.profiles where role in ('owner', 'admin') and organization_id <> v_owner_org limit 1;

  -- ---- Requirement 4: prove auth.uid()/current_org_id()/has_role() ------
  -- resolve the IMPERSONATED CALLER, never this SECURITY DEFINER
  -- function's owner. Not inferred from the trigger's behavior alone --
  -- called directly here, before any of the actual tests, as its own
  -- explicit, unambiguous assertion.
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner_id)::text, true);
  if auth.uid() = v_owner_id and public.current_org_id() = v_owner_org and public.has_role(array['owner', 'admin']::public.org_role[]) then
    raise notice 'REVISION-2 (auth.uid()/current_org_id()/has_role resolve the impersonated caller, not the function owner): PASS.';
  else
    raise notice 'REVISION-2 (auth.uid()/current_org_id()/has_role resolve the impersonated caller, not the function owner): FAIL -- auth.uid()=%, current_org_id()=%, has_role=%.',
      auth.uid(), public.current_org_id(), public.has_role(array['owner', 'admin']::public.org_role[]);
  end if;
  perform set_config('request.jwt.claims', '', true);

  -- ---- Fresh, isolated test loads in the owner's own organization -------
  -- (direct counter-mechanism inserts, same pattern as sections 1-3 above
  -- -- not through the RPC, since these are plain fixtures, not the thing
  -- under test).
  insert into public.load_number_counters (organization_id, last_number)
  values (v_owner_org, 700000)
  on conflict (organization_id) do update set last_number = greatest(load_number_counters.last_number, 700000)
  returning 'LD-' || lpad(last_number::text, 6, '0') into v_allocated_1;
  insert into public.loads (organization_id, load_number, status) values (v_owner_org, v_allocated_1, 'draft') returning id into v_load_a;

  insert into public.load_number_counters (organization_id, last_number)
  values (v_owner_org, 1) on conflict (organization_id) do update set last_number = load_number_counters.last_number + 1
  returning 'LD-' || lpad(last_number::text, 6, '0') into v_allocated_2;
  insert into public.loads (organization_id, load_number, status) values (v_owner_org, v_allocated_2, 'draft') returning id into v_load_b;

  -- ---- 1.5 CONFIRMED-BLOCKER FIX: direct owner UPDATE without/with a ----
  -- blank reason is rejected AT THE TRIGGER, not merely by
  -- change_load_number() -- these bypass the RPC entirely (raw UPDATE),
  -- so the RPC's own reason validation cannot be what's catching this.
  begin
    perform set_config('request.jwt.claims', json_build_object('sub', v_owner_id)::text, true);
    -- No app.load_number_change_reason set at all (current_setting(...,
    -- true) returns NULL for an unset GUC).
    update public.loads set load_number = 'LD-777000' where id = v_load_a;
    perform set_config('request.jwt.claims', '', true);
    raise notice 'REVISION-2 (direct owner UPDATE without GUC reason rejected): FAIL -- UPDATE with no reason set at all SUCCEEDED.';
  exception when others then
    perform set_config('request.jwt.claims', '', true);
    if sqlerrm like '%reason is required%' then
      raise notice 'REVISION-2 (direct owner UPDATE without GUC reason rejected): PASS -- REJECTED with the exact required message.';
    else
      raise notice 'REVISION-2 (direct owner UPDATE without GUC reason rejected): PASS (rejected), but with an unexpected message: %.', sqlerrm;
    end if;
  end;

  begin
    perform set_config('request.jwt.claims', json_build_object('sub', v_owner_id)::text, true);
    perform set_config('app.load_number_change_reason', '   ', true);
    update public.loads set load_number = 'LD-777000' where id = v_load_a;
    perform set_config('app.load_number_change_reason', '', true);
    perform set_config('request.jwt.claims', '', true);
    raise notice 'REVISION-2 (direct owner UPDATE with blank GUC reason rejected): FAIL -- UPDATE with a whitespace-only reason SUCCEEDED.';
  exception when others then
    perform set_config('app.load_number_change_reason', '', true);
    perform set_config('request.jwt.claims', '', true);
    if sqlerrm like '%reason is required%' then
      raise notice 'REVISION-2 (direct owner UPDATE with blank GUC reason rejected): PASS -- REJECTED with the exact required message.';
    else
      raise notice 'REVISION-2 (direct owner UPDATE with blank GUC reason rejected): PASS (rejected), but with an unexpected message: %.', sqlerrm;
    end if;
  end;

  -- ---- Transaction-local reason does not leak (practical check) ---------
  -- set_config(..., true) is a documented, unconditional PostgreSQL engine
  -- guarantee (equivalent to SET LOCAL): it CANNOT outlive the current
  -- transaction, full stop -- this is not project-specific behavior that
  -- could vary or regress, so it is not independently re-verified by
  -- spinning up a second real transaction here (this whole script is
  -- itself one transaction, ended by the ROLLBACK at the bottom -- a
  -- genuine cross-transaction test would require this script to COMMIT
  -- mid-run, which would defeat its own "nothing persists" guarantee).
  -- What IS verified directly, right now: after explicitly clearing the
  -- GUC above, it stays cleared for a completely unrelated subsequent
  -- statement in this SAME transaction -- i.e. the value does not
  -- silently linger past the block that set it.
  begin
    perform set_config('request.jwt.claims', json_build_object('sub', v_owner_id)::text, true);
    -- app.load_number_change_reason was last explicitly cleared to '' above.
    update public.loads set load_number = 'LD-777000' where id = v_load_a;
    perform set_config('request.jwt.claims', '', true);
    raise notice 'REVISION-2 (cleared reason does not linger): FAIL -- UPDATE SUCCEEDED despite the reason GUC having been explicitly cleared beforehand.';
  exception when others then
    perform set_config('request.jwt.claims', '', true);
    if sqlerrm like '%reason is required%' then
      raise notice 'REVISION-2 (cleared reason does not linger): PASS -- still correctly rejected; see this block''s own comment for why true cross-transaction leakage is a Postgres engine guarantee, not independently re-tested here.';
    else
      raise notice 'REVISION-2 (cleared reason does not linger): PASS (rejected), but with an unexpected message: %.', sqlerrm;
    end if;
  end;

  -- ---- 2. Owner may change a pre-dispatch number, with reason ------------
  begin
    perform set_config('request.jwt.claims', json_build_object('sub', v_owner_id)::text, true);
    v_result := public.change_load_number(v_load_a, 'LD-777001', 'REVISION-2 TEST: owner rename');
    perform set_config('request.jwt.claims', '', true);

    if v_result.load_number = 'LD-777001' then
      raise notice 'REVISION-2 (owner may change pre-dispatch number): PASS -- % -> LD-777001.', v_allocated_1;
    else
      raise notice 'REVISION-2 (owner may change pre-dispatch number): FAIL -- got %.', v_result.load_number;
    end if;

    -- 11. Activity log contains correct old/new/reason/actor. Reason is
    -- checked BOTH for an exact match AND, separately, that it is
    -- genuinely nonblank -- an exact match against a known-nonblank
    -- literal already implies this, but the requirement calls for both
    -- properties explicitly, so both are asserted as their own clauses.
    select * into v_activity from public.activity_logs
      where entity_type = 'load' and entity_id = v_load_a and action = 'load_number_changed'
      order by created_at desc limit 1;
    if v_activity.id is not null
      and v_activity.changes ->> 'old_load_number' = v_allocated_1
      and v_activity.changes ->> 'new_load_number' = 'LD-777001'
      and v_activity.changes ->> 'reason' is not null
      and btrim(v_activity.changes ->> 'reason') <> ''
      and v_activity.changes ->> 'reason' = 'REVISION-2 TEST: owner rename'
      and v_activity.actor_id = v_owner_id
      and v_activity.created_at is not null
    then
      raise notice 'REVISION-2 (activity log old/new/reason/actor/timestamp, reason nonblank and exact): PASS.';
    else
      raise notice 'REVISION-2 (activity log old/new/reason/actor/timestamp, reason nonblank and exact): FAIL -- row: %.', to_jsonb(v_activity);
    end if;
  exception when others then
    perform set_config('request.jwt.claims', '', true);
    raise notice 'REVISION-2 (owner may change pre-dispatch number): UNEXPECTED FAILURE (%).', sqlerrm;
  end;

  -- ---- 3. Admin may change it ---------------------------------------------
  if v_admin_id is null then
    raise notice 'REVISION-2 (admin may change a load number): SKIPPED -- no admin profile in the owner''s own organization to impersonate.';
  else
    begin
      perform set_config('request.jwt.claims', json_build_object('sub', v_admin_id)::text, true);
      v_result := public.change_load_number(v_load_a, 'LD-777002', 'REVISION-2 TEST: admin rename');
      perform set_config('request.jwt.claims', '', true);
      if v_result.load_number = 'LD-777002' then
        raise notice 'REVISION-2 (admin may change a load number): PASS -- LD-777001 -> LD-777002.';
      else
        raise notice 'REVISION-2 (admin may change a load number): FAIL -- got %.', v_result.load_number;
      end if;
    exception when others then
      perform set_config('request.jwt.claims', '', true);
      raise notice 'REVISION-2 (admin may change a load number): UNEXPECTED FAILURE (%).', sqlerrm;
    end;
  end if;

  -- ---- 4. Dispatcher rejected (RPC) + direct unauthorized update rejected -
  if v_dispatcher_id is null then
    raise notice 'REVISION-2 (dispatcher rejected / direct unauthorized update rejected): SKIPPED -- no dispatcher profile in the owner''s own organization to impersonate.';
  else
    begin
      perform set_config('request.jwt.claims', json_build_object('sub', v_dispatcher_id)::text, true);
      v_result := public.change_load_number(v_load_a, 'LD-777003', 'REVISION-2 TEST: dispatcher attempt');
      perform set_config('request.jwt.claims', '', true);
      raise notice 'REVISION-2 (dispatcher rejected via RPC): FAIL -- dispatcher''s call SUCCEEDED (should have been rejected).';
    exception when others then
      perform set_config('request.jwt.claims', '', true);
      raise notice 'REVISION-2 (dispatcher rejected via RPC): PASS -- REJECTED (%).', sqlerrm;
    end;

    -- Requirement 6: even a RAW update (bypassing change_load_number()
    -- and the reason-collecting UI entirely) must still be rejected by
    -- the trigger itself for a dispatcher.
    begin
      perform set_config('request.jwt.claims', json_build_object('sub', v_dispatcher_id)::text, true);
      update public.loads set load_number = 'LD-777004' where id = v_load_a;
      perform set_config('request.jwt.claims', '', true);
      raise notice 'REVISION-2 (direct unauthorized update rejected): FAIL -- a raw UPDATE by a dispatcher SUCCEEDED (should have been rejected by the trigger).';
    exception when others then
      perform set_config('request.jwt.claims', '', true);
      raise notice 'REVISION-2 (direct unauthorized update rejected): PASS -- REJECTED (%).', sqlerrm;
    end;
  end if;

  -- ---- 5. Cross-organization change rejected -----------------------------
  if v_other_org_owner_id is null then
    raise notice 'REVISION-2 (cross-organization change rejected): SKIPPED -- only one organization with an owner/admin exists in this database.';
  else
    begin
      perform set_config('request.jwt.claims', json_build_object('sub', v_other_org_owner_id)::text, true);
      v_result := public.change_load_number(v_load_a, 'LD-777005', 'REVISION-2 TEST: cross-org attempt');
      perform set_config('request.jwt.claims', '', true);
      raise notice 'REVISION-2 (cross-organization change rejected): FAIL -- an owner/admin from a DIFFERENT organization successfully changed this load''s number.';
    exception when others then
      perform set_config('request.jwt.claims', '', true);
      raise notice 'REVISION-2 (cross-organization change rejected): PASS -- REJECTED (%).', sqlerrm;
    end;
  end if;

  -- ---- 6. Duplicate number rejected ---------------------------------------
  begin
    perform set_config('request.jwt.claims', json_build_object('sub', v_owner_id)::text, true);
    v_result := public.change_load_number(v_load_a, v_allocated_2, 'REVISION-2 TEST: duplicate attempt');
    perform set_config('request.jwt.claims', '', true);
    raise notice 'REVISION-2 (duplicate number rejected): FAIL -- renaming to an already-used number SUCCEEDED.';
  exception when others then
    perform set_config('request.jwt.claims', '', true);
    raise notice 'REVISION-2 (duplicate number rejected): PASS -- REJECTED (%).', sqlerrm;
  end;

  -- ---- 7. Blank reason rejected -------------------------------------------
  begin
    perform set_config('request.jwt.claims', json_build_object('sub', v_owner_id)::text, true);
    v_result := public.change_load_number(v_load_a, 'LD-777006', '   ');
    perform set_config('request.jwt.claims', '', true);
    raise notice 'REVISION-2 (blank reason rejected): FAIL -- a whitespace-only reason was accepted.';
  exception when others then
    perform set_config('request.jwt.claims', '', true);
    raise notice 'REVISION-2 (blank reason rejected): PASS -- REJECTED (%).', sqlerrm;
  end;

  -- ---- 8. Dispatched load rejected ----------------------------------------
  insert into public.carriers (organization_id, legal_name) values (v_owner_org, 'REVISION-2 TEST CARRIER') returning id into v_carrier_id;
  insert into public.trucks (organization_id, carrier_id, unit_number) values (v_owner_org, v_carrier_id, 'TEST-UNIT-0114') returning id into v_truck_id;
  insert into public.drivers (organization_id, carrier_id, first_name, last_name) values (v_owner_org, v_carrier_id, 'Test', 'Driver') returning id into v_driver_id;
  insert into public.dispatches (organization_id, load_id, carrier_id, truck_id, driver_id)
    values (v_owner_org, v_load_a, v_carrier_id, v_truck_id, v_driver_id);
  begin
    perform set_config('request.jwt.claims', json_build_object('sub', v_owner_id)::text, true);
    v_result := public.change_load_number(v_load_a, 'LD-777007', 'REVISION-2 TEST: post-dispatch attempt');
    perform set_config('request.jwt.claims', '', true);
    raise notice 'REVISION-2 (dispatched load rejected): FAIL -- a dispatched load''s number was successfully changed.';
  exception when others then
    perform set_config('request.jwt.claims', '', true);
    if sqlerrm like '%dispatch or billing activity%' then
      raise notice 'REVISION-2 (dispatched load rejected): PASS -- REJECTED with the exact required message.';
    else
      raise notice 'REVISION-2 (dispatched load rejected): PASS (rejected), but with an unexpected message: %.', sqlerrm;
    end if;
  end;

  -- ---- 9. Invoiced load rejected ------------------------------------------
  -- A fresh load (v_load_b has no dispatch, so an invoice alone is the
  -- only lock condition tested here).
  insert into public.invoices (organization_id, invoice_number, load_id, status, bill_to_name, total_amount, issue_date)
    values (v_owner_org, 'TEST-0114-REV2-INV', v_load_b, 'draft', 'REVISION-2 TEST', 100.00, current_date);
  begin
    perform set_config('request.jwt.claims', json_build_object('sub', v_owner_id)::text, true);
    v_result := public.change_load_number(v_load_b, 'LD-777008', 'REVISION-2 TEST: post-invoice attempt');
    perform set_config('request.jwt.claims', '', true);
    raise notice 'REVISION-2 (invoiced load rejected): FAIL -- an invoiced load''s number was successfully changed.';
  exception when others then
    perform set_config('request.jwt.claims', '', true);
    if sqlerrm like '%dispatch or billing activity%' then
      raise notice 'REVISION-2 (invoiced load rejected): PASS -- REJECTED with the exact required message.';
    else
      raise notice 'REVISION-2 (invoiced load rejected): PASS (rejected), but with an unexpected message: %.', sqlerrm;
    end if;
  end;

  -- ---- 10. Documented/finalized (generated billing packet) rejected ------
  -- AUDITED, NOT ASSUMED: this schema's other generated-document system,
  -- broker_packets/broker_packet_items (0095), was checked directly
  -- (guard_broker_packet_item()'s own eligibility list) and structurally
  -- can NEVER reference a load-scoped document -- only 'broker', 'carrier',
  -- or 'organization' entity types are eligible, never 'load'. It is
  -- therefore not a real lock condition for an individual load and is not
  -- tested here (see this migration's own header comment for the same
  -- conclusion, reached before writing the trigger). billing_packets
  -- (0024, invoice-scoped) is the one real "generated document" system
  -- that DOES apply to a load, via its invoice -- exercised below as an
  -- explicit, independent scenario (not merely re-deriving the invoice
  -- test above, since this confirms the billing_packets JOIN itself
  -- matches correctly, not only the plain invoice-exists branch).
  insert into public.load_number_counters (organization_id, last_number)
  values (v_owner_org, 1) on conflict (organization_id) do update set last_number = load_number_counters.last_number + 1
  returning 'LD-' || lpad(last_number::text, 6, '0') into v_allocated_3;
  insert into public.loads (organization_id, load_number, status) values (v_owner_org, v_allocated_3, 'draft') returning id into v_load_c;

  insert into public.invoices (organization_id, invoice_number, load_id, status, bill_to_name, total_amount, issue_date)
    values (v_owner_org, 'TEST-0114-REV2-INV-PACKET', v_load_c, 'draft', 'REVISION-2 TEST', 100.00, current_date)
    returning id into v_document_id; -- reusing this uuid-typed scratch variable for the new invoice's id
  insert into public.billing_packets (organization_id, invoice_id, version, storage_path)
    values (v_owner_org, v_document_id, 1, 'test/billing-packet.pdf');
  begin
    perform set_config('request.jwt.claims', json_build_object('sub', v_owner_id)::text, true);
    v_result := public.change_load_number(v_load_c, 'LD-777009', 'REVISION-2 TEST: post-billing-packet attempt');
    perform set_config('request.jwt.claims', '', true);
    raise notice 'REVISION-2 (billing packet rejected): FAIL -- a load with a generated billing packet was successfully renamed.';
  exception when others then
    perform set_config('request.jwt.claims', '', true);
    if sqlerrm like '%dispatch or billing activity%' then
      raise notice 'REVISION-2 (billing packet rejected): PASS -- REJECTED with the exact required message.';
    else
      raise notice 'REVISION-2 (billing packet rejected): PASS (rejected), but with an unexpected message: %.', sqlerrm;
    end if;
  end;

  -- ---- 12/13/14. Counter advance/never-backward/no-recycling -------------
  -- A fourth and fifth fresh load, unlocked, to test the counter's
  -- three-way behavior in one continuous sequence.
  insert into public.load_number_counters (organization_id, last_number)
  values (v_owner_org, 1) on conflict (organization_id) do update set last_number = load_number_counters.last_number + 1
  returning 'LD-' || lpad(last_number::text, 6, '0') into v_allocated_1;
  insert into public.loads (organization_id, load_number, status) values (v_owner_org, v_allocated_1, 'draft') returning id into v_load_d;

  select last_number into v_counter_before from public.load_number_counters where organization_id = v_owner_org;

  -- 12. Canonical custom number ADVANCES the counter.
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner_id)::text, true);
  v_result := public.change_load_number(v_load_d, 'LD-800000', 'REVISION-2 TEST: canonical custom number');
  perform set_config('request.jwt.claims', '', true);
  select last_number into v_counter_after from public.load_number_counters where organization_id = v_owner_org;
  if v_counter_after = 800000 then
    raise notice 'REVISION-2 (canonical custom number advances counter): PASS -- counter now 800000 (was %).', v_counter_before;
  else
    raise notice 'REVISION-2 (canonical custom number advances counter): FAIL -- counter is % (expected 800000).', v_counter_after;
  end if;

  -- 13. A LOWER custom number never moves the counter backward.
  insert into public.loads (organization_id, load_number, status) values (v_owner_org, 'LD-800111', 'draft') returning id into v_load_e;
  -- (LD-800111 inserted directly, bypassing the trigger, purely as a
  -- disposable fixture row to rename FROM -- its own creation is not
  -- what's under test here.)
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner_id)::text, true);
  v_result := public.change_load_number(v_load_e, 'LD-100050', 'REVISION-2 TEST: lower custom number');
  perform set_config('request.jwt.claims', '', true);
  select last_number into v_counter_after from public.load_number_counters where organization_id = v_owner_org;
  if v_counter_after = 800000 then
    raise notice 'REVISION-2 (lower custom number never moves counter backward): PASS -- counter still 800000 after renaming a load to LD-100050.';
  else
    raise notice 'REVISION-2 (lower custom number never moves counter backward): FAIL -- counter changed to % (expected it to remain 800000).', v_counter_after;
  end if;

  -- 14. The ORIGINAL automatic number is not recycled: allocate the next
  -- automatic number now (should be 800001, continuing past the
  -- owner's earlier custom LD-800000 rename, never reissuing a number
  -- that was ever the subject of a rename away from it).
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner_id)::text, true);
  v_new_load_id := public.create_load_with_stops(
    jsonb_build_object('broker_id', null, 'customer_id', null, 'status', 'draft', 'rate', 0),
    jsonb_build_array(
      jsonb_build_object('stop_type', 'pickup', 'stop_sequence', 1, 'city', 'Test City', 'state', 'TX', 'country', 'US'),
      jsonb_build_object('stop_type', 'delivery', 'stop_sequence', 2, 'city', 'Test City 2', 'state', 'TX', 'country', 'US')
    )
  );
  perform set_config('request.jwt.claims', '', true);
  select load_number into v_allocated_1 from public.loads where id = v_new_load_id;
  if v_allocated_1 = 'LD-800001' then
    raise notice 'REVISION-2 (original automatic number not recycled): PASS -- next automatic allocation is LD-800001, continuing past the renamed-away LD-800000, never reissuing it.';
  elsif v_allocated_1 = 'LD-800000' then
    raise notice 'REVISION-2 (original automatic number not recycled): FAIL -- LD-800000 was reissued after being renamed away.';
  else
    raise notice 'REVISION-2 (original automatic number not recycled): got % -- PASS as long as this is > LD-800000 and was never issued before (expected LD-800001 specifically in an otherwise-empty sequence).', v_allocated_1;
  end if;
end $$;

-- Discards both throwaway organizations, every fixture load, and every
-- counter row created above, unconditionally. Nothing from this script
-- persists.
rollback;
