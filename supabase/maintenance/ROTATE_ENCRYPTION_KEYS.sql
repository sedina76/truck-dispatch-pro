-- =============================================================================
-- ROTATE_ENCRYPTION_KEYS.sql -- replace all three app encryption keys.
--
-- Why: until 0161, get_app_encryption_key() could be called by anyone, so the
-- current keys must be treated as exposed. This generates three new random
-- keys (driver_pii_key, carrier_pii_key, quickbooks_token_key), re-encrypts
-- every stored value with the new key, verifies that every value decrypts to
-- EXACTLY the same text as before, and only then stores the new keys.
--
-- Run ROTATE_KEYS_PREVIEW_READONLY.sql first (it must end RESULT | PASS).
-- Run this ONCE, in the Supabase SQL Editor. One transaction: if any value
-- cannot be decrypted or any check fails, NOTHING changes (old keys stay).
-- The keys are never printed. Running it again simply rotates again.
--
-- Notes:
--  * Plaintext never leaves the database and is never written anywhere.
--  * User triggers on the touched tables are disabled only for the duration of
--    the re-encryption UPDATE (completed W-9s are immutable by trigger, and
--    re-encryption must not bump updated_at). The plaintext is proven
--    unchanged, so those guards lose nothing. FK/constraint triggers stay on.
--  * QuickBooks: tokens are re-encrypted too, so an existing connection keeps
--    working without reconnecting.
-- =============================================================================
begin;
set local search_path = public, extensions, pg_catalog;
set local lock_timeout = '15s';

do $rot$
declare
  t record;
  v_old text;
  v_new text;
  v_fp_old text;
  v_fp_new text;
  v_set text;
  v_n bigint;
  v_rows bigint;
  v_values bigint;
  v_total bigint := 0;
begin
  create temp table _rot_known (tbl text, col text, key_name text) on commit drop;
  insert into _rot_known values
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
    ('quickbooks_connections', 'refresh_token_encrypted', 'quickbooks_token_key');

  -- Preconditions ------------------------------------------------------------
  if (select count(*) from public.app_encryption_keys where key_name in ('driver_pii_key', 'carrier_pii_key', 'quickbooks_token_key')) <> 3 then
    raise exception 'ROTATE: expected the three keys driver_pii_key, carrier_pii_key, quickbooks_token_key. STOP -- nothing changed.';
  end if;
  if exists (select 1 from information_schema.columns c
             where c.table_schema = 'public' and c.data_type = 'bytea'
               and not exists (select 1 from _rot_known k where k.tbl = c.table_name and k.col = c.column_name)) then
    raise exception 'ROTATE: a bytea column exists that this script does not know (%). STOP -- nothing changed.',
      (select string_agg(c.table_name || '.' || c.column_name, ', ') from information_schema.columns c
       where c.table_schema = 'public' and c.data_type = 'bytea'
         and not exists (select 1 from _rot_known k where k.tbl = c.table_name and k.col = c.column_name));
  end if;
  if (select count(*) from information_schema.columns c join _rot_known k on k.tbl = c.table_name and k.col = c.column_name
      where c.table_schema = 'public' and c.data_type = 'bytea') <> 11 then
    raise exception 'ROTATE: an expected encrypted column is missing. STOP -- nothing changed.';
  end if;

  create temp table _rot_keys on commit drop as
    select key_name, key_value as old_key, encode(gen_random_bytes(32), 'hex') as new_key
    from public.app_encryption_keys
    where key_name in ('driver_pii_key', 'carrier_pii_key', 'quickbooks_token_key');
  if exists (select 1 from _rot_keys where new_key = old_key or length(new_key) <> 64) then
    raise exception 'ROTATE: key generation failed. STOP -- nothing changed.';
  end if;

  lock table public.app_encryption_keys in exclusive mode;

  -- Re-encrypt, table by table ------------------------------------------------
  for t in select tbl, key_name, array_agg(col order by col) as cols from _rot_known group by tbl, key_name order by tbl loop
    select old_key, new_key into v_old, v_new from _rot_keys where key_name = t.key_name;

    -- plaintext fingerprint with the OLD key (fails loudly on any undecryptable value)
    begin
    execute format(
      'select count(*), md5(coalesce(string_agg(id::text || %L || %s, %L order by id), %L)) from public.%I',
      ':', (select string_agg(format('coalesce(pgp_sym_decrypt(%I, %L), %L)', c, v_old, '<null>'), ' || ''|'' || ') from unnest(t.cols) c),
      ',', '', t.tbl)
      into v_rows, v_fp_old;
    exception when others then
      raise exception 'ROTATE: % has a value that cannot be decrypted with the current % (%). STOP -- nothing changed; send this message to Claude.', t.tbl, t.key_name, sqlerrm;
    end;

    execute format('select %s from public.%I',
      (select string_agg(format('count(%I)', c), ' + ') from unnest(t.cols) c), t.tbl) into v_values;

    v_set := (select string_agg(format('%1$I = case when %1$I is null then null else pgp_sym_encrypt(pgp_sym_decrypt(%1$I, %2$L), %3$L) end', c, v_old, v_new), ', ')
              from unnest(t.cols) c);

    execute format('alter table public.%I disable trigger user', t.tbl);
    execute format('update public.%I set %s where %s', t.tbl, v_set,
      (select string_agg(format('%I is not null', c), ' or ') from unnest(t.cols) c));
    get diagnostics v_n = row_count;
    execute format('alter table public.%I enable trigger user', t.tbl);

    -- same plaintext with the NEW key
    execute format(
      'select md5(coalesce(string_agg(id::text || %L || %s, %L order by id), %L)) from public.%I',
      ':', (select string_agg(format('coalesce(pgp_sym_decrypt(%I, %L), %L)', c, v_new, '<null>'), ' || ''|'' || ') from unnest(t.cols) c),
      ',', '', t.tbl)
      into v_fp_new;
    if v_fp_new is distinct from v_fp_old then
      raise exception 'ROTATE: % -- values did not survive re-encryption. STOP -- nothing changed.', t.tbl;
    end if;

    v_total := v_total + v_values;
    raise notice 'ROTATE: % -- % value(s) in % row(s) re-encrypted with the new %, verified identical.', t.tbl, v_values, v_n, t.key_name;
  end loop;

  -- Store the new keys ---------------------------------------------------------
  update public.app_encryption_keys k set key_value = r.new_key from _rot_keys r where k.key_name = r.key_name;
  if exists (select 1 from public.app_encryption_keys k join _rot_keys r using (key_name) where k.key_value <> r.new_key) then
    raise exception 'ROTATE: new keys were not stored. STOP -- nothing changed.';
  end if;
  -- The functions the app uses read the key through get_app_encryption_key():
  if (select count(*) from _rot_keys r where public.get_app_encryption_key(r.key_name) = r.new_key) <> 3 then
    raise exception 'ROTATE: get_app_encryption_key does not return the new keys. STOP -- nothing changed.';
  end if;

  raise notice 'ROTATE: done -- 3 keys replaced, % encrypted value(s) re-encrypted and verified.', v_total;
end $rot$;

commit;
