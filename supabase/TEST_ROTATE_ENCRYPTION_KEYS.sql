-- =============================================================================
-- TEST_ROTATE_ENCRYPTION_KEYS.sql
--
-- NEVER RUN ON PRODUCTION. Disposable PostgreSQL only (migrations 0001..0119
-- on the Supabase stand-in). COMMITS fixture data -- the database is thrown
-- away afterwards by the runner.
--
-- Proves for maintenance/ROTATE_ENCRYPTION_KEYS.sql:
--   R1  an undecryptable value aborts the rotation and NOTHING changes
--   R2  all three keys are replaced
--   R3  every value decrypts with the new key to exactly the old plaintext
--   R4  the old keys no longer decrypt anything
--   R5  a certified (immutable) W-9 is re-encrypted, its immutability guard is
--       back on afterwards, and updated_at was not bumped
--   R6  the app's own write path (set_driver_pii) uses the new key
-- =============================================================================
\set ON_ERROR_STOP 1
set search_path = public, extensions, pg_catalog;

do $$ begin
  if (select count(*) from public.organizations) > 20 then
    raise exception 'REFUSING: this database has > 20 organizations -- looks like a real database.';
  end if;
end $$;

-- ---- fixtures (committed) ---------------------------------------------------
insert into public.organizations (id, name, slug) values ('0a000000-0000-0000-0000-0000000000a1', 'Rotate Org', 'rotate-org');

create table public.zz_rotate_plain (tbl text, id uuid, col text, plain text);

do $$
declare
  o uuid := '0a000000-0000-0000-0000-0000000000a1';
  kd text := public.get_app_encryption_key('driver_pii_key');
  kc text := public.get_app_encryption_key('carrier_pii_key');
  kq text := public.get_app_encryption_key('quickbooks_token_key');
  car uuid := gen_random_uuid(); drv uuid := gen_random_uuid(); bank uuid := gen_random_uuid();
  app uuid := gen_random_uuid(); dw9 uuid := gen_random_uuid(); coa uuid := gen_random_uuid();
  cw9 uuid := gen_random_uuid(); qb uuid := gen_random_uuid();
begin
  insert into public.carriers (id, organization_id, legal_name) values (car, o, 'Rotate Carrier');
  insert into public.drivers (id, organization_id, carrier_id, first_name, last_name, ssn_encrypted, direct_deposit_account_encrypted, direct_deposit_routing_encrypted)
    values (drv, o, car, 'Rita', 'Rotate', pgp_sym_encrypt('123-45-6789', kd), pgp_sym_encrypt('000111222333', kd), pgp_sym_encrypt('021000021', kd));
  insert into public.drivers (organization_id, carrier_id, first_name, last_name) values (o, car, 'No', 'Pii');   -- all-null row
  insert into public.organization_bank_accounts (id, organization_id, bank_name, routing_number_encrypted, account_number_encrypted)
    values (bank, o, 'Test Bank', pgp_sym_encrypt('111000025', kd), pgp_sym_encrypt('987654321', kd));
  insert into public.driver_applications (id, organization_id, first_name, last_name, signature_name, ssn_encrypted)
    values (app, o, 'App', 'Licant', 'App Licant', pgp_sym_encrypt('222-33-4444', kd));
  insert into public.driver_w9s (id, organization_id, driver_id, tin_encrypted) values (dw9, o, drv, pgp_sym_encrypt('555667777', kd));
  insert into public.carrier_onboarding_applications (id, organization_id, ein_encrypted) values (coa, o, pgp_sym_encrypt('12-3456789', kc));
  insert into public.carrier_w9s (id, organization_id, carrier_id, tin_encrypted) values (cw9, o, car, pgp_sym_encrypt('987654321', kc));
  update public.carrier_w9s set certified_at = now() - interval '3 days', updated_at = now() - interval '3 days' where id = cw9;
  insert into public.quickbooks_connections (id, organization_id, realm_id, access_token_encrypted, refresh_token_encrypted, access_token_expires_at)
    values (qb, o, 'realm-rotate', pgp_sym_encrypt('access-token-xyz', kq), pgp_sym_encrypt('refresh-token-xyz', kq), now() + interval '1 hour');

  insert into public.zz_rotate_plain values
    ('drivers', drv, 'ssn_encrypted', '123-45-6789'), ('drivers', drv, 'direct_deposit_account_encrypted', '000111222333'),
    ('drivers', drv, 'direct_deposit_routing_encrypted', '021000021'),
    ('organization_bank_accounts', bank, 'routing_number_encrypted', '111000025'), ('organization_bank_accounts', bank, 'account_number_encrypted', '987654321'),
    ('driver_applications', app, 'ssn_encrypted', '222-33-4444'), ('driver_w9s', dw9, 'tin_encrypted', '555667777'),
    ('carrier_onboarding_applications', coa, 'ein_encrypted', '12-3456789'), ('carrier_w9s', cw9, 'tin_encrypted', '987654321'),
    ('quickbooks_connections', qb, 'access_token_encrypted', 'access-token-xyz'), ('quickbooks_connections', qb, 'refresh_token_encrypted', 'refresh-token-xyz');
end $$;

-- immutability guard really is active before rotation
do $$ begin
  begin
    update public.carrier_w9s set tin_encrypted = pgp_sym_encrypt('1', 'x') where certified_at is not null;
    raise exception 'SETUP: certified W-9 was mutable';
  exception when others then
    if sqlerrm like 'SETUP:%' then raise; end if;
  end;
end $$;

create table public.zz_rotate_oldkeys as select key_name, key_value from public.app_encryption_keys;
create table public.zz_rotate_w9_before as select id, updated_at from public.carrier_w9s;

-- ---- R1: a value encrypted with some OTHER key aborts everything --------------
insert into public.driver_w9s (id, organization_id, driver_id, tin_encrypted)
  values ('0a000000-0000-0000-0000-0000000000ff', '0a000000-0000-0000-0000-0000000000a1',
          (select id from public.drivers where first_name = 'No'), pgp_sym_encrypt('999', 'not-the-key'));
\set ON_ERROR_STOP 0
\ir maintenance/ROTATE_ENCRYPTION_KEYS.sql
\set ON_ERROR_STOP 1
rollback;  -- clears the aborted transaction left by the failed run (warning if none)
do $$ begin
  if exists (select 1 from public.app_encryption_keys k join public.zz_rotate_oldkeys o using (key_name) where k.key_value <> o.key_value) then
    raise exception 'FAIL R1: keys changed although a value could not be decrypted';
  end if;
  if (select pgp_sym_decrypt(ssn_encrypted, (select key_value from public.zz_rotate_oldkeys where key_name = 'driver_pii_key'))
      from public.drivers where ssn_encrypted is not null) <> '123-45-6789' then
    raise exception 'FAIL R1: data changed although the rotation aborted';
  end if;
  raise notice 'OK R1: an undecryptable value stops the rotation; keys and data unchanged.';
end $$;
delete from public.driver_w9s where id = '0a000000-0000-0000-0000-0000000000ff';

-- ---- the real rotation --------------------------------------------------------
\ir maintenance/ROTATE_ENCRYPTION_KEYS.sql

do $$
declare r record; v text; n int := 0;
begin
  if exists (select 1 from public.app_encryption_keys k join public.zz_rotate_oldkeys o using (key_name) where k.key_value = o.key_value)
     or (select count(*) from public.app_encryption_keys) <> 3 then
    raise exception 'FAIL R2: not all three keys were replaced';
  end if;
  raise notice 'OK R2: all three keys replaced.';

  for r in select p.*, m.key_name from public.zz_rotate_plain p
           join (values ('organization_bank_accounts','driver_pii_key'), ('drivers','driver_pii_key'), ('driver_applications','driver_pii_key'),
                        ('driver_w9s','driver_pii_key'), ('carrier_onboarding_applications','carrier_pii_key'), ('carrier_w9s','carrier_pii_key'),
                        ('quickbooks_connections','quickbooks_token_key')) m(tbl, key_name) using (tbl) loop
    execute format('select pgp_sym_decrypt(%I, %L) from public.%I where id = %L', r.col,
                   (select key_value from public.app_encryption_keys where key_name = r.key_name), r.tbl, r.id) into v;
    if v is distinct from r.plain then raise exception 'FAIL R3: %.% decrypted to %', r.tbl, r.col, v; end if;
    begin
      execute format('select pgp_sym_decrypt(%I, %L) from public.%I where id = %L', r.col,
                     (select key_value from public.zz_rotate_oldkeys where key_name = r.key_name), r.tbl, r.id) into v;
      raise exception 'FAIL R4: old key still decrypts %.%', r.tbl, r.col;
    exception when others then
      if sqlerrm like 'FAIL R4%' then raise; end if;
    end;
    n := n + 1;
  end loop;
  if n <> 11 then raise exception 'FAIL R3: checked % values, expected 11', n; end if;
  if exists (select 1 from public.drivers where first_name = 'No' and (ssn_encrypted is not null or direct_deposit_account_encrypted is not null)) then
    raise exception 'FAIL R3: an empty value was filled in';
  end if;
  raise notice 'OK R3: all 11 values decrypt with the new keys to exactly the original text (empty values stay empty).';
  raise notice 'OK R4: the old keys decrypt nothing.';

  if exists (select 1 from public.carrier_w9s w join public.zz_rotate_w9_before b using (id) where w.updated_at <> b.updated_at) then
    raise exception 'FAIL R5: re-encryption bumped updated_at';
  end if;
  begin
    update public.carrier_w9s set tin_encrypted = pgp_sym_encrypt('1', 'x') where certified_at is not null;
    raise exception 'FAIL R5: certified W-9 is mutable after rotation (guard left disabled)';
  exception when others then
    if sqlerrm like 'FAIL R5%' then raise; end if;
  end;
  if exists (select 1 from pg_trigger where not tgisinternal and tgenabled = 'D') then
    raise exception 'FAIL R5: a trigger was left disabled';
  end if;
  raise notice 'OK R5: certified W-9 re-encrypted, guard back on, updated_at untouched, no trigger left disabled.';
end $$;

-- R6: the app's write path uses the new key (set_driver_pii as an owner)
insert into auth.users (id, email, aud, role) values ('0a000000-0000-0000-0000-00000000aaaa', 'rot-owner@test.invalid', 'authenticated', 'authenticated');
set app.bypass_profile_guard = 'true';
update public.profiles set organization_id = '0a000000-0000-0000-0000-0000000000a1', role = 'owner' where id = '0a000000-0000-0000-0000-00000000aaaa';
set app.bypass_profile_guard = 'false';
select set_config('request.jwt.claims', '{"sub":"0a000000-0000-0000-0000-00000000aaaa","role":"authenticated"}', false);
set role authenticated;
select public.set_driver_pii((select id from public.drivers where first_name = 'Rita'), 'ssn', '999-88-7777');
reset role;
do $$ begin
  if (select pgp_sym_decrypt(ssn_encrypted, (select key_value from public.app_encryption_keys where key_name = 'driver_pii_key'))
      from public.drivers where first_name = 'Rita') <> '999-88-7777' then
    raise exception 'FAIL R6: set_driver_pii did not encrypt with the new key';
  end if;
  raise notice 'OK R6: the app''s own encrypt path uses the new key.';
  raise notice 'ALL ROTATION CHECKS PASSED';
end $$;
