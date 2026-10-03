-- ROTATE_KEYS_PREVIEW_READONLY.sql -- READ-ONLY. Run BEFORE ROTATE_ENCRYPTION_KEYS.sql.
-- Lists every encrypted value the rotation will re-encrypt, and checks that no
-- encrypted column exists that the rotation does not know about.
-- Expected: every row PASS or INFO; the last row RESULT | PASS.
with known(tbl, col, key_name) as (values
  ('organization_bank_accounts', 'routing_number_encrypted', 'driver_pii_key'),
  ('organization_bank_accounts', 'account_number_encrypted', 'driver_pii_key'),
  ('drivers', 'ssn_encrypted', 'driver_pii_key'),
  ('drivers', 'direct_deposit_account_encrypted', 'driver_pii_key'),
  ('drivers', 'direct_deposit_routing_encrypted', 'driver_pii_key'),
  ('driver_applications', 'ssn_encrypted', 'driver_pii_key'),
  ('driver_w9s', 'tin_encrypted', 'driver_pii_key'),
  ('carrier_onboarding_applications', 'ein_encrypted', 'carrier_pii_key'),
  ('carrier_w9s', 'tin_encrypted', 'carrier_pii_key'),
  ('quickbooks_connections', 'access_token_encrypted', 'quickbooks_token_key'),
  ('quickbooks_connections', 'refresh_token_encrypted', 'quickbooks_token_key')
),
rows as (
  select 10 as ord, 'keys present: driver_pii_key, carrier_pii_key, quickbooks_token_key' as item,
         case when (select count(*) from public.app_encryption_keys where key_name in ('driver_pii_key', 'carrier_pii_key', 'quickbooks_token_key')) = 3 then 'PASS' else 'FAIL' end as result,
         (select string_agg(key_name, ', ' order by key_name) from public.app_encryption_keys) as detail
  union all
  select 20, 'no unknown bytea column in public (anything encrypted must be on the list)',
         case when exists (select 1 from information_schema.columns c
                           where c.table_schema = 'public' and c.data_type = 'bytea'
                             and not exists (select 1 from known k where k.tbl = c.table_name and k.col = c.column_name)) then 'FAIL' else 'PASS' end,
         coalesce((select string_agg(c.table_name || '.' || c.column_name, ', ') from information_schema.columns c
                   where c.table_schema = 'public' and c.data_type = 'bytea'
                     and not exists (select 1 from known k where k.tbl = c.table_name and k.col = c.column_name)), 'none')
  union all
  select 30, 'every known encrypted column exists',
         case when (select count(*) from information_schema.columns c join known k on k.tbl = c.table_name and k.col = c.column_name
                    where c.table_schema = 'public' and c.data_type = 'bytea') = 11 then 'PASS' else 'FAIL' end, 'catalog'
  union all select 40, 'values to re-encrypt: bank accounts (routing / account)', 'INFO',
         (select count(routing_number_encrypted) || ' / ' || count(account_number_encrypted) from public.organization_bank_accounts)
  union all select 41, 'values to re-encrypt: drivers (ssn / deposit account / deposit routing)', 'INFO',
         (select count(ssn_encrypted) || ' / ' || count(direct_deposit_account_encrypted) || ' / ' || count(direct_deposit_routing_encrypted) from public.drivers)
  union all select 42, 'values to re-encrypt: driver applications ssn / driver W-9 tin', 'INFO',
         (select count(ssn_encrypted) from public.driver_applications) || ' / ' || (select count(tin_encrypted) from public.driver_w9s)
  union all select 43, 'values to re-encrypt: carrier onboarding ein / carrier W-9 tin', 'INFO',
         (select count(ein_encrypted) from public.carrier_onboarding_applications) || ' / ' || (select count(tin_encrypted) from public.carrier_w9s)
  union all select 44, 'values to re-encrypt: QuickBooks tokens (access / refresh)', 'INFO',
         (select count(access_token_encrypted) || ' / ' || count(refresh_token_encrypted) from public.quickbooks_connections)
)
select ord, item, result, detail from rows
union all
select 99, 'RESULT', case when exists (select 1 from rows where result = 'FAIL') then 'FAIL -- do not rotate; send this to Claude' else 'PASS' end, ''
order by 1;
