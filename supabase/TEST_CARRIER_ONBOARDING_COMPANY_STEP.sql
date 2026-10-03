-- =============================================================================
-- TEST_CARRIER_ONBOARDING_COMPANY_STEP.sql -- PRODUCTION TWIN ONLY (supabase/ci/twin-db.sh).
-- NEVER run on a real database. Ends in ROLLBACK. The carrier portal's
-- Company step and the step it continues to, exactly as the server actions
-- run them (service role, no staff login):
--   C1 save company info (incl. EIN encryption) on a draft application
--   C2 the Tax Info (W-9) step can create its draft for that application
-- =============================================================================
\set ON_ERROR_STOP 1
begin;
do $$ begin
  if (select count(*) from public.organizations) > 80 then raise exception 'REFUSING: not a twin database'; end if;
end $$;

insert into auth.users (id, email, aud, role) values ('17200000-0000-0000-0000-00000000000a', 'o172@test.invalid', 'authenticated', 'authenticated');
select set_config('request.jwt.claims', '{"sub":"17200000-0000-0000-0000-00000000000a","role":"authenticated"}', true);
set local role authenticated; select public.create_organization_with_owner('T172 Org', 't172-org') is not null; reset role;
select id as org from public.organizations where slug = 't172-org' \gset
insert into public.carrier_onboarding_applications (id, organization_id) values ('17200000-0000-0000-0000-0000000000a1', :'org');

-- the carrier portal's server actions run as service_role
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
set local role service_role;
do $$
declare v_enc bytea; v_w9 uuid;
begin
  v_enc := public.encrypt_carrier_onboarding_ein('123456789');
  update public.carrier_onboarding_applications set
    legal_name = 'Test Carrier LLC', contact_name = 'Pat', phone = '555-0100', email = 'pat@test.invalid', mc_number = 'MC-1', dot_number = '1',
    address_line1 = '1 Main', city = 'Austin', state = 'TX', postal_code = '78701', country = 'US', factoring_company_name = null, has_factoring = false,
    ein_encrypted = v_enc, ein_last4 = '6789'
  where id = '17200000-0000-0000-0000-0000000000a1';
  if not found then raise exception 'FAIL C1: update matched no row'; end if;
  raise notice 'OK C1: company info saved (EIN encrypted: %).', v_enc is not null;

  v_w9 := public.create_carrier_w9_draft((select organization_id from public.carrier_onboarding_applications where id = '17200000-0000-0000-0000-0000000000a1'), '17200000-0000-0000-0000-0000000000a1', null);
  if v_w9 is null then raise exception 'FAIL C2: no W-9 draft'; end if;
  raise notice 'OK C2: the Tax Info step created its W-9 draft.';
end $$;
reset role;

do $$ begin raise notice 'ALL CARRIER ONBOARDING COMPANY-STEP CHECKS PASSED'; end $$;
rollback;
