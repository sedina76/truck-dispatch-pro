-- ---------------------------------------------------------------------------
-- Fixes a latent bug in 0014: set_bank_account_pii, reveal_bank_account_pii,
-- set_driver_pii, and reveal_driver_pii all call pgp_sym_encrypt/
-- pgp_sym_decrypt (pgcrypto) but only had `set search_path = public`.
-- Discovered earlier this session with the *same* class of function
-- (gen_salt/crypt in the driver-portal PIN functions) -- pgcrypto lives in
-- the `extensions` schema on Supabase, not `public`, so any unqualified
-- call fails at runtime with "function pgp_sym_encrypt(...) does not exist"
-- even though the function itself was created successfully. Because 0014's
-- live status was never confirmed, this was caught by inspection while
-- building the driver-application feature (which calls the same encryption
-- path) rather than by a failed call in production. CREATE OR REPLACE is
-- safe to run whether or not 0014 has been applied yet.
-- ---------------------------------------------------------------------------

create or replace function public.set_bank_account_pii(
  p_bank_account_id uuid,
  p_field text,
  p_value text
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_org_id uuid;
  v_key text;
  v_digits text;
begin
  if p_field not in ('account_number', 'routing_number') then
    raise exception 'Unsupported field: %', p_field;
  end if;

  select organization_id into v_org_id from public.organization_bank_accounts where id = p_bank_account_id;
  if v_org_id is null or v_org_id <> public.current_org_id() then
    raise exception 'Bank account not found in your organization';
  end if;
  if not public.has_role(array['owner']::public.org_role[]) then
    raise exception 'Only the owner may set bank account numbers';
  end if;

  v_key := public.get_app_encryption_key('driver_pii_key');
  v_digits := right(regexp_replace(p_value, '[^0-9]', '', 'g'), 4);

  if p_field = 'account_number' then
    update public.organization_bank_accounts
    set account_number_encrypted = pgp_sym_encrypt(p_value, v_key), account_number_last4 = v_digits
    where id = p_bank_account_id;
  else
    update public.organization_bank_accounts
    set routing_number_encrypted = pgp_sym_encrypt(p_value, v_key), routing_number_last4 = v_digits
    where id = p_bank_account_id;
  end if;
end;
$$;

create or replace function public.reveal_bank_account_pii(
  p_bank_account_id uuid,
  p_field text,
  p_reason text default null
)
returns text
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_org_id uuid;
  v_key text;
  v_encrypted bytea;
begin
  if p_field not in ('account_number', 'routing_number') then
    raise exception 'Unsupported field: %', p_field;
  end if;

  select organization_id into v_org_id from public.organization_bank_accounts where id = p_bank_account_id;
  if v_org_id is null or v_org_id <> public.current_org_id() then
    raise exception 'Bank account not found in your organization';
  end if;
  if not public.has_role(array['owner']::public.org_role[]) then
    raise exception 'Only the owner may reveal bank account numbers';
  end if;

  if p_field = 'account_number' then
    select account_number_encrypted into v_encrypted from public.organization_bank_accounts where id = p_bank_account_id;
  else
    select routing_number_encrypted into v_encrypted from public.organization_bank_accounts where id = p_bank_account_id;
  end if;

  if v_encrypted is null then
    return null;
  end if;

  v_key := public.get_app_encryption_key('driver_pii_key');

  insert into public.bank_account_access_log (organization_id, bank_account_id, field_name, accessed_by, reason)
  values (v_org_id, p_bank_account_id, p_field, auth.uid(), p_reason);

  return pgp_sym_decrypt(v_encrypted, v_key);
end;
$$;

create or replace function public.set_driver_pii(
  p_driver_id uuid,
  p_field text,
  p_value text
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_org_id uuid;
  v_key text;
  v_digits text;
begin
  if p_field not in ('ssn', 'direct_deposit_account', 'direct_deposit_routing') then
    raise exception 'Unsupported PII field: %', p_field;
  end if;

  select organization_id into v_org_id from public.drivers where id = p_driver_id;
  if v_org_id is null or v_org_id <> public.current_org_id() then
    raise exception 'Driver not found in your organization';
  end if;
  if not public.has_role(array['owner', 'admin']::public.org_role[]) then
    raise exception 'Only owners and admins may set this field';
  end if;

  v_key := public.get_app_encryption_key('driver_pii_key');
  v_digits := right(regexp_replace(p_value, '[^0-9]', '', 'g'), 4);

  if p_field = 'ssn' then
    update public.drivers set ssn_encrypted = pgp_sym_encrypt(p_value, v_key), ssn_last4 = v_digits
    where id = p_driver_id;
  elsif p_field = 'direct_deposit_account' then
    update public.drivers set direct_deposit_account_encrypted = pgp_sym_encrypt(p_value, v_key), direct_deposit_account_last4 = v_digits
    where id = p_driver_id;
  else
    update public.drivers set direct_deposit_routing_encrypted = pgp_sym_encrypt(p_value, v_key)
    where id = p_driver_id;
  end if;
end;
$$;

create or replace function public.reveal_driver_pii(
  p_driver_id uuid,
  p_field text,
  p_reason text default null
)
returns text
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_org_id uuid;
  v_key text;
  v_encrypted bytea;
begin
  if p_field not in ('ssn', 'direct_deposit_account', 'direct_deposit_routing') then
    raise exception 'Unsupported PII field: %', p_field;
  end if;

  select organization_id into v_org_id from public.drivers where id = p_driver_id;
  if v_org_id is null or v_org_id <> public.current_org_id() then
    raise exception 'Driver not found in your organization';
  end if;
  if not public.has_role(array['owner', 'admin']::public.org_role[]) then
    raise exception 'Only owners and admins may reveal this field';
  end if;

  if p_field = 'ssn' then
    select ssn_encrypted into v_encrypted from public.drivers where id = p_driver_id;
  elsif p_field = 'direct_deposit_account' then
    select direct_deposit_account_encrypted into v_encrypted from public.drivers where id = p_driver_id;
  else
    select direct_deposit_routing_encrypted into v_encrypted from public.drivers where id = p_driver_id;
  end if;

  if v_encrypted is null then
    return null;
  end if;

  v_key := public.get_app_encryption_key('driver_pii_key');

  insert into public.driver_pii_access_log (organization_id, driver_id, field_name, accessed_by, reason)
  values (v_org_id, p_driver_id, p_field, auth.uid(), p_reason);

  return pgp_sym_decrypt(v_encrypted, v_key);
end;
$$;
