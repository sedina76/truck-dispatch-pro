-- =============================================================================
-- 0014_company_driver_compliance_expansion.sql
-- Three things:
--   1. Company module: authority/registration fields, mailing address,
--      invoice defaults, and a bank_accounts table.
--   2. Driver module expansion: full personnel profile, encrypted SSN and
--      direct-deposit account fields with an admin-only reveal path and a
--      permanent access log.
--   3. Compliance taxonomy expansion + a structured insurance_policies
--      table (GL / Cargo / Physical Damage / Workers Comp), replacing the
--      "everything is a generic compliance_item" approach for insurance.
-- =============================================================================

-- =============================================================================
-- PART 1: Company module
-- =============================================================================

create type public.authority_status as enum ('active', 'pending', 'inactive', 'revoked');

alter table public.organizations
  add column fax text,
  add column website text,
  add column ein text,
  add column usdot_authority_status public.authority_status,
  add column broker_authority_status public.authority_status,
  add column dispatch_authority_status public.authority_status,
  add column safety_rating text,
  add column safety_rating_date date,
  add column mailing_address_line1 text,
  add column mailing_address_line2 text,
  add column mailing_city text,
  add column mailing_state text,
  add column mailing_postal_code text,
  add column invoice_footer text,
  add column default_payment_terms_days integer not null default 30,
  add column default_invoice_notes text;

create table public.organization_bank_accounts (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  bank_name text not null,
  account_nickname text,
  account_type text not null default 'checking' check (account_type in ('checking', 'savings')),
  routing_number_last4 text,
  account_number_last4 text,
  routing_number_encrypted bytea,
  account_number_encrypted bytea,
  is_primary boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table public.organization_bank_accounts is
  'Company payment instructions for receiving factoring/broker payments. Routing/account numbers are encrypted the same way as driver SSNs -- see PART 2 for the shared key-handling pattern.';

create trigger set_updated_at
  before update on public.organization_bank_accounts
  for each row execute function public.set_updated_at();

alter table public.organization_bank_accounts enable row level security;

create policy organization_bank_accounts_select on public.organization_bank_accounts
  for select using (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin']::public.org_role[])
  );

create policy organization_bank_accounts_insert on public.organization_bank_accounts
  for insert with check (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin']::public.org_role[])
  );

create policy organization_bank_accounts_update on public.organization_bank_accounts
  for update using (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin']::public.org_role[])
  )
  with check (organization_id = public.current_org_id());

create policy organization_bank_accounts_delete on public.organization_bank_accounts
  for delete using (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin']::public.org_role[])
  );

-- Column-level lockdown: RLS governs *rows*, not columns, so a row-level
-- policy alone would still let any owner/admin SELECT the raw ciphertext
-- bytea through the normal REST API. Only the reveal function below (which
-- runs as the table owner via SECURITY DEFINER, bypassing column grants
-- entirely) may ever read the encrypted columns.
revoke select on public.organization_bank_accounts from authenticated;
grant select (
  id, organization_id, bank_name, account_nickname, account_type,
  routing_number_last4, account_number_last4, is_primary, created_at, updated_at
) on public.organization_bank_accounts to authenticated;
revoke insert, update on public.organization_bank_accounts from authenticated;
grant insert (organization_id, bank_name, account_nickname, account_type, is_primary)
  on public.organization_bank_accounts to authenticated;
grant update (bank_name, account_nickname, account_type, is_primary)
  on public.organization_bank_accounts to authenticated;

-- =============================================================================
-- PART 2: Encrypted PII infrastructure (shared by drivers' SSN and
-- direct-deposit numbers, and the company bank accounts above)
-- =============================================================================

-- Holds the symmetric key(s) used for pgp_sym_encrypt/decrypt. RLS is
-- enabled with *zero* policies defined -- that's deliberate, not an
-- oversight: it means there is no role, including authenticated or
-- service_role-via-PostgREST, that can read a row here through the normal
-- API. The only way in is a SECURITY DEFINER function owned by the table
-- owner, which bypasses RLS (and column grants) entirely by Postgres
-- design. This is the standard pre-Vault pattern for app-level secrets;
-- if this project later enables Supabase Vault, this table can be
-- retired in favor of it without changing the functions' external API.
create table public.app_encryption_keys (
  id uuid primary key default gen_random_uuid(),
  key_name text not null unique,
  key_value text not null,
  created_at timestamptz not null default now()
);

alter table public.app_encryption_keys enable row level security;

comment on table public.app_encryption_keys is
  'Symmetric keys for pgp_sym_encrypt/decrypt of driver SSNs and bank account numbers. No RLS policies exist on purpose -- unreachable via the API; only SECURITY DEFINER functions can read it.';

insert into public.app_encryption_keys (key_name, key_value)
values ('driver_pii_key', encode(gen_random_bytes(32), 'hex'))
on conflict (key_name) do nothing;

-- Not granted to authenticated. Callers reach this only by being another
-- SECURITY DEFINER function, which executes with the definer's privileges
-- (the table owner) for its whole body, including nested calls -- so the
-- lack of a grant here never blocks the legitimate call paths below.
create or replace function public.get_app_encryption_key(p_key_name text)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select key_value from public.app_encryption_keys where key_name = p_key_name;
$$;

-- Permanent audit trail: every single decryption of a driver's SSN or
-- direct-deposit numbers is recorded here and can never be deleted through
-- the normal API (no delete policy is defined).
create table public.driver_pii_access_log (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  driver_id uuid not null references public.drivers (id) on delete cascade,
  field_name text not null check (field_name in ('ssn', 'direct_deposit_account', 'direct_deposit_routing')),
  accessed_by uuid references public.profiles (id) on delete set null,
  reason text,
  accessed_at timestamptz not null default now()
);

comment on table public.driver_pii_access_log is
  'Immutable audit trail of every SSN / bank account reveal. Written exclusively by reveal_driver_pii(); no update/delete policy exists.';

alter table public.driver_pii_access_log enable row level security;

create index idx_driver_pii_access_log_driver on public.driver_pii_access_log (driver_id, accessed_at desc);

create policy driver_pii_access_log_select on public.driver_pii_access_log
  for select using (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin']::public.org_role[])
  );

-- Same audit-log pattern as driver_pii_access_log, scoped to the company's
-- own bank accounts instead of a driver.
create table public.bank_account_access_log (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  bank_account_id uuid not null references public.organization_bank_accounts (id) on delete cascade,
  field_name text not null check (field_name in ('account_number', 'routing_number')),
  accessed_by uuid references public.profiles (id) on delete set null,
  reason text,
  accessed_at timestamptz not null default now()
);

alter table public.bank_account_access_log enable row level security;

create policy bank_account_access_log_select on public.bank_account_access_log
  for select using (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin']::public.org_role[])
  );

-- Write/reveal pair for organization_bank_accounts, mirroring
-- set_driver_pii/reveal_driver_pii below but scoped to owner-only (a
-- company's own receiving-payment details are more sensitive than a
-- single driver's, since every invoice/factoring payment depends on them).
create or replace function public.set_bank_account_pii(
  p_bank_account_id uuid,
  p_field text,
  p_value text
)
returns void
language plpgsql
security definer
set search_path = public
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

grant execute on function public.set_bank_account_pii(uuid, text, text) to authenticated;

create or replace function public.reveal_bank_account_pii(
  p_bank_account_id uuid,
  p_field text,
  p_reason text default null
)
returns text
language plpgsql
security definer
set search_path = public
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

grant execute on function public.reveal_bank_account_pii(uuid, text, text) to authenticated;

-- =============================================================================
-- PART 3: Driver module expansion
-- =============================================================================

alter table public.drivers
  add column employee_number text,
  add column photo_url text,
  add column gender text,
  add column address_line1 text,
  add column city text,
  add column state text,
  add column postal_code text,
  add column emergency_contact_name text,
  add column emergency_contact_phone text,
  add column department text,
  add column cdl_class text check (cdl_class in ('A', 'B', 'C')),
  add column cdl_restrictions text,
  add column cdl_endorsements text,
  add column medical_card_number text,
  add column drug_test_date date,
  add column drug_test_expiry_date date,
  add column background_check_date date,
  add column background_check_status text check (background_check_status in ('pending', 'passed', 'failed')),
  add column mvr_date date,
  add column mvr_status text check (mvr_status in ('pending', 'passed', 'failed')),
  add column twic_expiry_date date,
  add column hazmat_endorsement_expiry_date date,
  add column passport_number text,
  add column passport_expiry_date date,
  add column work_authorization_status text check (work_authorization_status in ('citizen', 'permanent_resident', 'visa', 'ead', 'other')),
  add column work_authorization_expiry_date date,
  add column direct_deposit_bank_name text,
  add column direct_deposit_account_last4 text,
  add column direct_deposit_account_encrypted bytea,
  add column direct_deposit_routing_encrypted bytea,
  add column ssn_last4 text,
  add column ssn_encrypted bytea;

comment on column public.drivers.ssn_encrypted is
  'PGP-symmetric-encrypted (pgcrypto). Never selectable by authenticated directly -- see the column-level REVOKE below. Set via set_driver_pii(), read via reveal_driver_pii(), both owner/admin-only and the latter is logged.';
comment on column public.drivers.ssn_last4 is
  'Plaintext last 4 digits only, for the default masked ***-**-1234 display. Not sensitive enough on its own to warrant encryption or access logging.';

-- ---------------------------------------------------------------------------
-- PII write/reveal functions. Both are owner/admin-only regardless of the
-- caller's general driver-edit permissions (dispatchers can edit most
-- driver fields per the RLS policy below, but never these).
-- ---------------------------------------------------------------------------
create or replace function public.set_driver_pii(
  p_driver_id uuid,
  p_field text,
  p_value text
)
returns void
language plpgsql
security definer
set search_path = public
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

grant execute on function public.set_driver_pii(uuid, text, text) to authenticated;

create or replace function public.reveal_driver_pii(
  p_driver_id uuid,
  p_field text,
  p_reason text default null
)
returns text
language plpgsql
security definer
set search_path = public
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

grant execute on function public.reveal_driver_pii(uuid, text, text) to authenticated;

-- ---------------------------------------------------------------------------
-- Column-level lockdown on drivers, same rationale as organization_bank_accounts
-- above: RLS already scopes rows to the caller's org (drivers_select /
-- drivers_update policies from 0010), but that alone does not stop a
-- logged-in dispatcher or viewer from selecting the raw encrypted bytea
-- columns through the normal REST API. Every column except the three
-- encrypted ones is re-granted explicitly.
-- ---------------------------------------------------------------------------
revoke select on public.drivers from authenticated;
grant select (
  id, organization_id, carrier_id, first_name, last_name, phone, email,
  cdl_number, cdl_state, cdl_expiry_date, medical_card_expiry_date, hire_date,
  date_of_birth, status, home_terminal_city, home_terminal_state, pay_type,
  pay_rate, notes, created_at, updated_at,
  employee_number, photo_url, gender, address_line1, city, state, postal_code,
  emergency_contact_name, emergency_contact_phone, department, cdl_class,
  cdl_restrictions, cdl_endorsements, medical_card_number, drug_test_date,
  drug_test_expiry_date, background_check_date, background_check_status,
  mvr_date, mvr_status, twic_expiry_date, hazmat_endorsement_expiry_date,
  passport_number, passport_expiry_date, work_authorization_status,
  work_authorization_expiry_date, direct_deposit_bank_name,
  direct_deposit_account_last4, ssn_last4
) on public.drivers to authenticated;

revoke insert, update on public.drivers from authenticated;
grant insert (
  organization_id, carrier_id, first_name, last_name, phone, email,
  cdl_number, cdl_state, cdl_expiry_date, medical_card_expiry_date, hire_date,
  date_of_birth, status, home_terminal_city, home_terminal_state, pay_type,
  pay_rate, notes, employee_number, photo_url, gender, address_line1, city,
  state, postal_code, emergency_contact_name, emergency_contact_phone,
  department, cdl_class, cdl_restrictions, cdl_endorsements,
  medical_card_number, drug_test_date, drug_test_expiry_date,
  background_check_date, background_check_status, mvr_date, mvr_status,
  twic_expiry_date, hazmat_endorsement_expiry_date, passport_number,
  passport_expiry_date, work_authorization_status, work_authorization_expiry_date,
  direct_deposit_bank_name, direct_deposit_account_last4
) on public.drivers to authenticated;
grant update (
  carrier_id, first_name, last_name, phone, email, cdl_number, cdl_state,
  cdl_expiry_date, medical_card_expiry_date, hire_date, date_of_birth, status,
  home_terminal_city, home_terminal_state, pay_type, pay_rate, notes,
  employee_number, photo_url, gender, address_line1, city, state, postal_code,
  emergency_contact_name, emergency_contact_phone, department, cdl_class,
  cdl_restrictions, cdl_endorsements, medical_card_number, drug_test_date,
  drug_test_expiry_date, background_check_date, background_check_status,
  mvr_date, mvr_status, twic_expiry_date, hazmat_endorsement_expiry_date,
  passport_number, passport_expiry_date, work_authorization_status,
  work_authorization_expiry_date, direct_deposit_bank_name, direct_deposit_account_last4
) on public.drivers to authenticated;

-- =============================================================================
-- PART 4: Compliance taxonomy expansion + structured insurance policies
-- =============================================================================

alter type public.compliance_item_type add value if not exists 'dot_inspection';
alter type public.compliance_item_type add value if not exists 'twic_expiry';
alter type public.compliance_item_type add value if not exists 'hazmat_expiry';
alter type public.compliance_item_type add value if not exists 'passport_expiry';
alter type public.compliance_item_type add value if not exists 'work_authorization_expiry';
alter type public.compliance_item_type add value if not exists 'background_check';

create type public.insurance_policy_type as enum (
  'general_liability', 'cargo', 'physical_damage', 'workers_compensation'
);

create table public.insurance_policies (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  carrier_id uuid references public.carriers (id) on delete cascade,
  policy_type public.insurance_policy_type not null,
  insurer_name text not null,
  policy_number text,
  coverage_amount numeric(12, 2),
  premium_amount numeric(10, 2),
  effective_date date,
  expiry_date date,
  document_id uuid references public.documents (id) on delete set null,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table public.insurance_policies is
  'Structured insurance tracking (GL, Cargo, Physical Damage, Workers Comp). carrier_id null = the dispatch company''s own policy; set = a carrier''s policy on file.';

create index idx_insurance_policies_organization_id on public.insurance_policies (organization_id);
create index idx_insurance_policies_carrier on public.insurance_policies (carrier_id);
create index idx_insurance_policies_expiry on public.insurance_policies (expiry_date);

create trigger set_updated_at
  before update on public.insurance_policies
  for each row execute function public.set_updated_at();

alter table public.insurance_policies enable row level security;

create policy insurance_policies_select on public.insurance_policies
  for select using (organization_id = public.current_org_id());

create policy insurance_policies_insert on public.insurance_policies
  for insert with check (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin', 'accountant']::public.org_role[])
  );

create policy insurance_policies_update on public.insurance_policies
  for update using (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin', 'accountant']::public.org_role[])
  )
  with check (organization_id = public.current_org_id());

create policy insurance_policies_delete on public.insurance_policies
  for delete using (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin']::public.org_role[])
  );

-- =============================================================================
-- PART 5: DOT violations (safety history; starts empty, populated manually
-- or from a future FMCSA/SAFER integration)
-- =============================================================================

create table public.dot_violations (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  carrier_id uuid references public.carriers (id) on delete cascade,
  driver_id uuid references public.drivers (id) on delete set null,
  violation_date date not null default current_date,
  violation_type text not null,
  description text,
  severity text check (severity in ('low', 'medium', 'high', 'critical')) default 'medium',
  is_resolved boolean not null default false,
  resolved_date date,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index idx_dot_violations_organization_id on public.dot_violations (organization_id);
create index idx_dot_violations_carrier on public.dot_violations (carrier_id);

create trigger set_updated_at
  before update on public.dot_violations
  for each row execute function public.set_updated_at();

alter table public.dot_violations enable row level security;

create policy dot_violations_select on public.dot_violations
  for select using (organization_id = public.current_org_id());

create policy dot_violations_insert on public.dot_violations
  for insert with check (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin', 'dispatcher']::public.org_role[])
  );

create policy dot_violations_update on public.dot_violations
  for update using (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin', 'dispatcher']::public.org_role[])
  )
  with check (organization_id = public.current_org_id());

create policy dot_violations_delete on public.dot_violations
  for delete using (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin']::public.org_role[])
  );
