-- ============================================================================
-- 0131 PRE-APPLY VERIFICATION  --  100% READ-ONLY. SELECT + catalog only.
-- No DO block, no transaction control, no RPC execution. Safe on production.
--
-- Run BEFORE applying 0131_carrier_party_relationships.sql. Requires 0130 live.
-- Every row of the matrix must show ok = true.
-- ============================================================================
select * from ( values

  (1,  'public.carriers exists',   to_regclass('public.carriers')   is not null),
  (2,  'public.brokers exists',    to_regclass('public.brokers')    is not null),
  (3,  'public.customers exists',  to_regclass('public.customers')  is not null),
  (4,  'public.profiles exists',   to_regclass('public.profiles')   is not null),
  (5,  'public.current_org_id() exists',         to_regprocedure('public.current_org_id()') is not null),
  (6,  'public.has_role(org_role[]) exists',     to_regprocedure('public.has_role(public.org_role[])') is not null),
  (7,  'public.set_updated_at() exists',         to_regprocedure('public.set_updated_at()') is not null),
  (8,  'enum public.document_type exists',
       exists (select 1 from pg_type t join pg_namespace n on n.oid=t.typnamespace where n.nspname='public' and t.typname='document_type')),

  -- ---- 0130 landmark ----
  (9,  '0130 landmark: public.carrier_remittance_profiles present', to_regclass('public.carrier_remittance_profiles') is not null),
  (10, '0130 landmark: type public.unresolved_record_status present',
       exists (select 1 from pg_type t join pg_namespace n on n.oid=t.typnamespace where n.nspname='public' and t.typname='unresolved_record_status')),

  -- ---- objects 0131 CREATES must be ABSENT ----
  (11, 'type public.carrier_party_status does NOT exist yet',
       not exists (select 1 from pg_type t join pg_namespace n on n.oid=t.typnamespace where n.nspname='public' and t.typname='carrier_party_status')),
  (12, 'table public.carrier_brokers does NOT exist yet',   to_regclass('public.carrier_brokers')   is null),
  (13, 'table public.carrier_customers does NOT exist yet', to_regclass('public.carrier_customers') is null),
  (14, 'function public.guard_carrier_party_org() does NOT exist yet',
       to_regprocedure('public.guard_carrier_party_org()') is null),
  (15, 'function public.activate_carrier_party(uuid,uuid,uuid,jsonb) does NOT exist yet',
       to_regprocedure('public.activate_carrier_party(uuid,uuid,uuid,jsonb)') is null)

) as t(check_no, label, ok)
order by check_no;
