-- Read-only diagnostic: why the "Change Load Number" control might not be
-- appearing for LD-100023. NO writes anywhere in this script -- safe to
-- run against production at any time, and LD-100023 itself is NOT
-- modified. Run each numbered block in the Supabase SQL Editor while
-- signed in AS the user who does not see the button, if possible (for
-- block 1, which depends on auth.uid() -- see its own note).

-- 1. Current signed-in profile's role -- the ENTIRE basis for
--    canChangeLoadNumber in src/app/(app)/loads/[id]/page.tsx (confirmed
--    by direct code read: `OWNER_ADMIN_ROLES.includes(roleData)`, where
--    roleData comes from the current_role() RPC -- purely role-based, no
--    dependency on dispatch/invoice state at all).
-- NOTE: auth.uid() is NULL in the SQL Editor itself (no browser session
-- bound to this connection) -- this query will show NULL/no role here
-- regardless of what the real signed-in user's role is. To check the
-- REAL answer, look at Settings > Users in the app (or query by email
-- below), not this auth.uid()-based query.
select auth.uid() as sql_editor_has_no_session_normally, public.current_role() as role_for_this_connection;

-- 1b. The actual answer: look up the specific user's role directly by
-- email (fill in the real signed-in user's email).
select p.id, p.email, p.role, p.organization_id
from public.profiles p
where p.email = '<signed-in user''s email>';
-- REVIEW: role must be exactly 'owner' or 'admin' (case-sensitive, must
-- match public.org_role's enum values) for the button to render at all,
-- and for change_load_number()/guard_load_number_change() to permit an
-- actual change. 'dispatcher' or any other role: button is correctly
-- hidden, by design.

-- 2. LD-100023's organization vs. that user's organization -- the button
--    itself has no organization check (role-only), but change_load_
--    number() does: a mismatch here would surface as "Load not found."
--    if the dialog were ever opened and submitted, not as a hidden
--    button -- included for completeness, not because it explains a
--    HIDDEN button.
select l.id, l.load_number, l.organization_id as load_org, o.name as load_org_name
from public.loads l
join public.organizations o on o.id = l.organization_id
where l.load_number = 'LD-100023';
-- Compare load_org above to the role_for_this_connection query's
-- organization_id (1b) for the specific signed-in user in question.

-- 3. Any dispatches row for this load -- note there is no "draft" dispatch
--    concept in this schema at all (public.dispatch_status has no such
--    value: 'assigned', 'accepted', 'en_route_to_pickup', ... 'cancelled'
--    -- confirmed directly from 0001_extensions_enums_helpers.sql). A
--    dispatch either exists as a real row (status >= 'assigned') or it
--    does not -- merely opening /dispatch/new?load_id=... never creates
--    one (dispatch-data.ts, which backs that page's GET render, contains
--    zero insert/update/upsert/delete calls -- confirmed by direct code
--    search -- only createDispatch(), a separate server action bound to
--    the form's actual SUBMIT, ever inserts a row).
select id, status, dispatched_at, carrier_id, truck_id, driver_id
from public.dispatches
where load_id = (select id from public.loads where load_number = 'LD-100023');
-- REVIEW: zero rows = no dispatch exists for this load, at all, in any
-- state. This does NOT hide the button (see item 7 below) -- but if a
-- REAL dispatch row does exist here, THAT (correctly) locks load_number
-- changes at the database level (guard_load_number_change()), even
-- though the button itself would still render for an owner/admin (the
-- dialog would open, and the change attempt would be rejected with "Load
-- number cannot be changed after dispatch or billing activity has
-- begun." -- a locked load still SHOWS the control if the role check
-- passes; the control is not conditioned on lock state, only on role,
-- per this migration's own design).
select id, status from public.dispatches where load_id = (select id from public.loads where load_number = 'LD-100023');

-- 4. Any invoices row for this load, in any status (including draft/void
--    -- both still count as "an invoice row exists" for the lock check,
--    since guard_load_number_change()'s own condition is a plain EXISTS
--    against public.invoices with no status filter at all).
select id, invoice_number, status
from public.invoices
where load_id = (select id from public.loads where load_number = 'LD-100023');
-- REVIEW: same note as item 3 -- an invoice existing locks the DATABASE
-- change (correctly, by design), it does not hide the BUTTON.

-- 8. Confirm the 0114 objects this feature depends on actually exist in
--    THIS database, with the expected shape/privileges -- if 0114 has
--    not been applied yet, change_load_number()/guard_load_number_change()
--    do not exist at all, and calling the RPC would fail outright (a
--    different symptom than "button hidden," but worth ruling out if the
--    button DOES render and clicking Save fails).
select
  (select count(*) from pg_proc where proname = 'change_load_number' and pronamespace = 'public'::regnamespace) as change_load_number_exists,
  (select count(*) from pg_trigger where tgname = 'loads_guard_load_number_change') as guard_trigger_exists,
  (select count(*) from pg_proc where proname = 'guard_load_number_change' and pronamespace = 'public'::regnamespace) as guard_function_exists;
-- expect (only if 0114 has been applied): 1, 1, 1. If all three are 0,
-- 0114 is not applied yet -- the button rendering is a pure frontend
-- concern independent of this, but the ACTUAL change would fail with a
-- generic "function does not exist" error if attempted.

select
  has_function_privilege('authenticated', 'public.change_load_number(uuid, text, text)', 'EXECUTE') as authenticated_can_call_it;
-- expect: true (only meaningful if change_load_number_exists = 1 above).
