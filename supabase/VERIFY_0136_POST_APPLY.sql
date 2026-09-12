-- ============================================================================
-- 0136 POST-APPLY VERIFICATION -- 100% READ-ONLY. Run immediately after
-- applying 0136. Every row must show ok = true.
-- ============================================================================
select * from ( values

  (1, 'carriers.factoring_mode present, NOT NULL, default unconfigured',
      exists (select 1 from information_schema.columns
              where table_schema='public' and table_name='carriers' and column_name='factoring_mode'
                and is_nullable='NO')),
  (2, 'every existing carrier defaulted to factoring_mode=unconfigured (never silently direct or factored)',
      (select count(*) from public.carriers where factoring_mode <> 'unconfigured') = 0),
  (2.1, 'carrier_factoring_mode enum is exactly {unconfigured, direct, factored}',
      (select array_agg(enumlabel::text order by enumsortorder) from pg_enum e join pg_type t on t.oid=e.enumtypid where t.typname='carrier_factoring_mode')
      = array['unconfigured','direct','factored']::text[]),

  (3, 'factoring_relationships.carrier_id present and NULLABLE',
      exists (select 1 from information_schema.columns
              where table_schema='public' and table_name='factoring_relationships' and column_name='carrier_id'
                and is_nullable='YES')),
  (4, 'this migration populated NO carrier_id values (0137''s job)',
      (select count(*) from public.factoring_relationships where carrier_id is not null) = 0),

  (5, 'factoring_relationships gained remittance + NOA + submission columns',
      (select count(*) from information_schema.columns
       where table_schema='public' and table_name='factoring_relationships'
         and column_name in ('remittance_instructions','remittance_reference','noa_template_text','noa_document_id',
                              'noa_reference','noa_effective_date','noa_approved','noa_approved_by','noa_approved_at',
                              'submission_method','submission_destination_email','submission_integration_id','submission_notes')) = 13),

  (6, 'integration_provider gained factoring_api',
      'factoring_api' = any(enum_range(null::public.integration_provider)::text[])),

  (7, 'factoring_relationships_guard_org fires on INSERT and UPDATE',
      (select array_agg(distinct event_manipulation::text order by event_manipulation::text) from information_schema.triggers
       where event_object_schema='public' and event_object_table='factoring_relationships' and trigger_name='factoring_relationships_guard_org')
      = array['INSERT','UPDATE']::text[]),
  (8, 'factoring_relationships_guard_protected_fields present on INSERT and UPDATE',
      (select array_agg(distinct event_manipulation::text order by event_manipulation::text) from information_schema.triggers
       where event_object_schema='public' and event_object_table='factoring_relationships' and trigger_name='factoring_relationships_guard_protected_fields')
      = array['INSERT','UPDATE']::text[]),

  (9, 'NOA-approval-complete CHECK constraint present',
      exists (select 1 from pg_constraint where conname='factoring_relationships_noa_approval_complete')),
  (10, 'submission-email-present CHECK constraint present',
      exists (select 1 from pg_constraint where conname='factoring_relationships_submission_email_present')),
  (11, 'submission-integration-present CHECK constraint present',
      exists (select 1 from pg_constraint where conname='factoring_relationships_submission_integration_present')),

  -- ---- untouched: 0071's org-level default index + 0072's RPC still present ----
  (12, '0071 factoring_relationships_one_default_per_org index still present (0138 cuts over, not this migration)',
      exists (select 1 from pg_indexes where schemaname='public' and tablename='factoring_relationships' and indexname='factoring_relationships_one_default_per_org')),
  (13, '0072 set_default_factoring_relationship(uuid) still present',
      to_regprocedure('public.set_default_factoring_relationship(uuid)') is not null),
  (14, '0071 factored_invoices / factoring_events untouched (still present)',
      to_regclass('public.factored_invoices') is not null and to_regclass('public.factoring_events') is not null)

) as t(check_no, label, ok)
order by check_no;
