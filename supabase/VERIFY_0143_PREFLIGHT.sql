-- ============================================================================
-- 0143 PRE-APPLY VERIFICATION -- 100% READ-ONLY. SELECT + catalog only.
-- Run BEFORE applying 0143. Requires 0142 live. Every row must show ok = true.
-- ============================================================================
select * from ( values

  (1, '0142 landmark: carrier_invoice_lifecycle_idempotency exists',
      to_regclass('public.carrier_invoice_lifecycle_idempotency') is not null),
  (2, '0142 landmark: update_carrier_invoice_draft(uuid,jsonb,timestamptz,text,text) exists',
      to_regprocedure('public.update_carrier_invoice_draft(uuid,jsonb,timestamptz,text,text)') is not null),
  (3, 'pgcrypto is installed and its digest(text,text) function is reachable (public or extensions schema)',
      exists (select 1 from pg_extension where extname = 'pgcrypto')
      and (to_regprocedure('public.digest(text,text)') is not null or to_regprocedure('extensions.digest(text,text)') is not null)),

  -- ---- objects 0143 introduces do not exist yet ----
  (4, 'compute_financial_request_fingerprint(jsonb) does not exist yet',
      to_regprocedure('public.compute_financial_request_fingerprint(jsonb)') is null),
  (5, 'carrier_invoice_lifecycle_idempotency.fingerprint_version does not exist yet',
      not exists (select 1 from information_schema.columns where table_schema='public' and table_name='carrier_invoice_lifecycle_idempotency' and column_name='fingerprint_version')),
  (6, 'carrier_invoice_lifecycle_idempotency still has its ORIGINAL (organization_id, idempotency_key)-only unique constraint (0143 has not yet widened it)',
      exists (
        select 1 from pg_constraint c join pg_class t on t.oid = c.conrelid
        where t.relname = 'carrier_invoice_lifecycle_idempotency' and c.conname = 'civ_idempotency_unique'
          and (
            select array_agg(a.attname::text order by a.attname)
            from unnest(c.conkey) ck(attnum) join pg_attribute a on a.attrelid = t.oid and a.attnum = ck.attnum
          ) = array['idempotency_key','organization_id']
      )),
  (7, 'the current update_carrier_invoice_draft() still uses the 0142 MD5 fingerprint (confirms this preflight runs at the correct boundary)',
      (select prosrc from pg_proc where proname = 'update_carrier_invoice_draft' and pronamespace = 'public'::regnamespace) ilike '%md5(%')

) as t(check_no, label, ok)
order by check_no;

-- ============================================================================
-- Section C: the existing-row compatibility gate. This is NOT informational
-- -- migration 0143 itself re-runs this exact classification and REFUSES to
-- proceed if the table is non-empty (see its own Phase 1). This preflight
-- surfaces the same finding in advance, read-only, so an operator never
-- discovers the refusal only at apply time.
-- ============================================================================
select
  (select count(*) from public.carrier_invoice_lifecycle_idempotency) as total_existing_rows,
  (select count(*) from public.carrier_invoice_lifecycle_idempotency where request_fingerprint ~ '^[0-9a-f]{32}$') as legacy_md5_shaped_rows,
  (select count(*) from public.carrier_invoice_lifecycle_idempotency where request_fingerprint ~ '^[0-9a-f]{64}$') as sha256_shaped_rows,
  (select count(*) from public.carrier_invoice_lifecycle_idempotency where request_fingerprint !~ '^[0-9a-f]{32}$' and request_fingerprint !~ '^[0-9a-f]{64}$') as unrecognized_shaped_rows,
  case
    when (select count(*) from public.carrier_invoice_lifecycle_idempotency) = 0
      then 'SAFE: table is empty -- 0143 will apply cleanly with no compatibility mapping needed.'
    else 'UNSAFE: table is NOT empty -- 0142 is documented as never applied to production, so this is unexpected. 0143''s own Phase 1 will REFUSE to apply (raise + rollback) rather than guess a legacy-MD5-vs-SHA-256 classification or reinterpret any existing fingerprint. Resolve manually before attempting to apply 0143 -- see 0143''s own migration header, "EXISTING-ROW COMPATIBILITY POLICY".'
  end as migration_safety_report;
