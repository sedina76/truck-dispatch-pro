-- ============================================================================
-- 0143 POST-APPLY VERIFICATION -- 100% READ-ONLY. Run immediately after
-- applying 0143. Every row must show ok = true.
-- ============================================================================
select * from ( values

  (1, 'compute_financial_request_fingerprint(jsonb) exists, is IMMUTABLE, and EXECUTE is revoked from public/anon/authenticated (Phase 3B.3B.1 Section B -- internal primitive, no client role calls it directly)',
      to_regprocedure('public.compute_financial_request_fingerprint(jsonb)') is not null
      and (select provolatile from pg_proc where proname = 'compute_financial_request_fingerprint' and pronamespace = 'public'::regnamespace) = 'i'
      and not has_function_privilege('public', 'public.compute_financial_request_fingerprint(jsonb)', 'EXECUTE')
      and not has_function_privilege('anon', 'public.compute_financial_request_fingerprint(jsonb)', 'EXECUTE')
      and not has_function_privilege('authenticated', 'public.compute_financial_request_fingerprint(jsonb)', 'EXECUTE')),

  (2, 'compute_financial_request_fingerprint produces a genuine 64-lowercase-hex SHA-256 digest',
      public.compute_financial_request_fingerprint('{"a":1}'::jsonb) ~ '^[0-9a-f]{64}$'),

  (3, 'compute_financial_request_fingerprint is order-insensitive to JSON key ordering at every nesting level',
      public.compute_financial_request_fingerprint('{"b":1,"a":{"y":2,"z":1}}'::jsonb)
      = public.compute_financial_request_fingerprint('{"a":{"z":1,"y":2},"b":1}'::jsonb)),

  (4, 'update_carrier_invoice_draft() no longer references md5() anywhere in its source',
      (select prosrc from pg_proc where proname = 'update_carrier_invoice_draft' and pronamespace = 'public'::regnamespace) not ilike '%md5(%'),

  (5, 'update_carrier_invoice_draft() calls compute_financial_request_fingerprint()',
      (select prosrc from pg_proc where proname = 'update_carrier_invoice_draft' and pronamespace = 'public'::regnamespace) ilike '%compute_financial_request_fingerprint%'),

  (6, 'carrier_invoice_lifecycle_idempotency: action renamed to operation (action no longer exists)',
      exists (select 1 from information_schema.columns where table_schema='public' and table_name='carrier_invoice_lifecycle_idempotency' and column_name='operation')
      and not exists (select 1 from information_schema.columns where table_schema='public' and table_name='carrier_invoice_lifecycle_idempotency' and column_name='action')),

  (7, 'carrier_invoice_lifecycle_idempotency: fingerprint_version/state/created_by/updated_at all present, fingerprint_version and state NOT NULL with the documented defaults',
      exists (select 1 from information_schema.columns where table_schema='public' and table_name='carrier_invoice_lifecycle_idempotency' and column_name='fingerprint_version' and is_nullable='NO' and column_default = '1')
      and exists (select 1 from information_schema.columns where table_schema='public' and table_name='carrier_invoice_lifecycle_idempotency' and column_name='state' and is_nullable='NO' and column_default = '''completed''::text')
      and exists (select 1 from information_schema.columns where table_schema='public' and table_name='carrier_invoice_lifecycle_idempotency' and column_name='created_by')
      and exists (select 1 from information_schema.columns where table_schema='public' and table_name='carrier_invoice_lifecycle_idempotency' and column_name='updated_at' and is_nullable='NO')),

  (8, 'civ_idempotency_unique is scoped to EXACTLY (organization_id, operation, idempotency_key)',
      exists (
        select 1 from pg_constraint c join pg_class t on t.oid = c.conrelid
        where t.relname = 'carrier_invoice_lifecycle_idempotency' and c.conname = 'civ_idempotency_unique'
          and (
            select array_agg(a.attname::text order by a.attname)
            from unnest(c.conkey) ck(attnum) join pg_attribute a on a.attrelid = t.oid and a.attnum = ck.attnum
          ) = array['idempotency_key','operation','organization_id']
      )),

  (9, 'carrier_invoice_lifecycle_idempotency remains empty (0143 never writes data)',
      (select count(*) from public.carrier_invoice_lifecycle_idempotency) = 0),

  (10, 'carrier_invoice_lifecycle_idempotency still has zero client INSERT/UPDATE/DELETE grant -- only a SECURITY DEFINER RPC can ever write to it',
      not has_table_privilege('authenticated', 'public.carrier_invoice_lifecycle_idempotency', 'INSERT')
      and not has_table_privilege('authenticated', 'public.carrier_invoice_lifecycle_idempotency', 'UPDATE')
      and not has_table_privilege('authenticated', 'public.carrier_invoice_lifecycle_idempotency', 'DELETE')),

  (11, 'update_carrier_invoice_draft() keeps its exact 0142 public signature and is still EXECUTE-able by authenticated',
      to_regprocedure('public.update_carrier_invoice_draft(uuid,jsonb,timestamptz,text,text)') is not null
      and has_function_privilege('authenticated', 'public.update_carrier_invoice_draft(uuid,jsonb,timestamptz,text,text)', 'EXECUTE')),

  (12, 'no OTHER function in this schema references carrier_invoice_lifecycle_idempotency -- it remains, today, permanently dedicated to update_carrier_invoice_draft() alone',
      (select count(*) from pg_proc where prosrc ilike '%carrier_invoice_lifecycle_idempotency%' and pronamespace = 'public'::regnamespace) = 1
      and (select proname from pg_proc where prosrc ilike '%carrier_invoice_lifecycle_idempotency%' and pronamespace = 'public'::regnamespace limit 1) = 'update_carrier_invoice_draft'),

  (13, 'update_carrier_invoice_draft() still has zero column grant on carrier_invoices for authenticated beyond notes (Phase 3B.3A.2 column-privilege model untouched)',
      not has_column_privilege('authenticated', 'public.carrier_invoices', 'issuance_status', 'UPDATE')
      and not has_column_privilege('authenticated', 'public.carrier_invoices', 'carrier_id', 'UPDATE')
      and has_column_privilege('authenticated', 'public.carrier_invoices', 'notes', 'UPDATE')),

  (14, 'update_carrier_invoice_draft() does not use service_role anywhere in its source',
      (select prosrc from pg_proc where proname = 'update_carrier_invoice_draft' and pronamespace = 'public'::regnamespace) not ilike '%service_role%'),

  (15, 'update_carrier_invoice_draft() fingerprints the NORMALIZED patch (v_normalized_patch), never raw p_patch, and still calls compute_financial_request_fingerprint() despite its own EXECUTE revoke (ownership + SECURITY DEFINER carry it through -- proven live by TEST_0143/the RPC tests, not just here)',
      (select prosrc from pg_proc where proname = 'update_carrier_invoice_draft' and pronamespace = 'public'::regnamespace) ilike '%''patch'', v_normalized_patch%'
      and (select prosrc from pg_proc where proname = 'update_carrier_invoice_draft' and pronamespace = 'public'::regnamespace) not ilike '%''patch'', p_patch%'
      and (select prosrc from pg_proc where proname = 'update_carrier_invoice_draft' and pronamespace = 'public'::regnamespace) ilike '%compute_financial_request_fingerprint%'),

  (16, 'update_carrier_invoice_draft() rejects unknown patch keys (the master-key allowlist check) BEFORE it ever computes a fingerprint',
      position('v_master_keys' in (select prosrc from pg_proc where proname = 'update_carrier_invoice_draft' and pronamespace = 'public'::regnamespace))
      < position('compute_financial_request_fingerprint(' in (select prosrc from pg_proc where proname = 'update_carrier_invoice_draft' and pronamespace = 'public'::regnamespace))),

  (17, 'no client-facing result path (JSON literal keys returned to the caller) ever includes a raw fingerprint or canonical-payload field',
      (select prosrc from pg_proc where proname = 'update_carrier_invoice_draft' and pronamespace = 'public'::regnamespace) not ilike '%''request_fingerprint''%'
      and (select prosrc from pg_proc where proname = 'update_carrier_invoice_draft' and pronamespace = 'public'::regnamespace) not ilike '%''fingerprint'', v_fingerprint%'
      and (select prosrc from pg_proc where proname = 'update_carrier_invoice_draft' and pronamespace = 'public'::regnamespace) not ilike '%''canonical_payload''%')

) as t(check_no, label, ok)
order by check_no;
