-- Run BEFORE applying 0119_stripe_subscription_foundation.sql.
--
-- 100% READ-ONLY. No BEGIN/ROLLBACK, no writes, no temp objects -- every
-- statement is a plain SELECT. Safe to run against production.
--
-- Purpose: prove that the three UNIQUE constraints 0119 adds
--   organization_subscriptions : UNIQUE (organization_id)
--   organization_subscriptions : UNIQUE (stripe_customer_id)      [nulls ok]
--   organization_subscriptions : UNIQUE (stripe_subscription_id)  [nulls ok]
--   billing_records            : UNIQUE (stripe_invoice_id)       [nulls ok]
-- can be added without a data conflict. If any "DUPLICATE" query below
-- returns rows, STOP and resolve manually -- 0119 must not ship an
-- automatic de-duplication.
--
-- Stripe identifiers are NEVER selected in cleartext here. Only booleans
-- (IS NULL), counts, and internal uuid primary keys are returned.

-- ============================================================================
-- A. Total organizations.
-- ============================================================================
select count(*) as total_organizations
from public.organizations;

-- ============================================================================
-- B. Total organization_subscriptions rows.
-- ============================================================================
select count(*) as total_organization_subscriptions
from public.organization_subscriptions;

-- ============================================================================
-- C. Organizations with ZERO subscription rows (informational -- these are
--    the grandfather candidates that 0120, NOT 0119, will handle).
-- ============================================================================
select
  count(*) as organizations_with_no_subscription_row
from public.organizations o
where not exists (
  select 1 from public.organization_subscriptions s
  where s.organization_id = o.id
);

-- Optional detail (id + name only) -- comment out if the list is long.
select o.id as organization_id, o.name as organization_name
from public.organizations o
where not exists (
  select 1 from public.organization_subscriptions s
  where s.organization_id = o.id
)
order by o.name;

-- ============================================================================
-- D. Organizations with MORE THAN ONE subscription row  --> BLOCKER for
--    UNIQUE (organization_id). Must return ZERO rows.
-- ============================================================================
select
  o.id                                   as organization_id,
  o.name                                 as organization_name,
  count(s.id)                            as subscription_row_count
from public.organization_subscriptions s
join public.organizations o on o.id = s.organization_id
group by o.id, o.name
having count(s.id) > 1
order by count(s.id) desc, o.name;

-- D2. Per-row safe detail for any duplicated organization above (no Stripe
--     identifiers -- only IS NULL booleans).
select
  s.organization_id,
  o.name                                  as organization_name,
  s.id                                    as subscription_row_id,
  p.tier                                  as plan_tier,
  p.name                                  as plan_name,
  s.status,
  s.billing_cycle,
  s.created_at,
  s.current_period_end,
  (s.stripe_customer_id     is null)      as stripe_customer_id_is_null,
  (s.stripe_subscription_id is null)      as stripe_subscription_id_is_null
from public.organization_subscriptions s
join public.organizations o on o.id = s.organization_id
left join public.subscription_plans p on p.id = s.plan_id
where s.organization_id in (
  select organization_id
  from public.organization_subscriptions
  group by organization_id
  having count(*) > 1
)
order by s.organization_id, s.created_at;

-- ============================================================================
-- E. Duplicate NON-NULL stripe_customer_id  --> BLOCKER for
--    UNIQUE (stripe_customer_id). Must return ZERO rows.
--    Reports only: how many rows share a value, and which internal ids.
--    The stripe_customer_id value itself is NOT selected.
-- ============================================================================
select
  count(*)                                as rows_sharing_a_stripe_customer_id,
  array_agg(distinct s.organization_id)   as affected_organization_ids,
  array_agg(s.id order by s.id)           as affected_subscription_row_ids
from public.organization_subscriptions s
where s.stripe_customer_id is not null
  and s.stripe_customer_id in (
    select stripe_customer_id
    from public.organization_subscriptions
    where stripe_customer_id is not null
    group by stripe_customer_id
    having count(*) > 1
  );

-- ============================================================================
-- F. Duplicate NON-NULL stripe_subscription_id  --> BLOCKER for
--    UNIQUE (stripe_subscription_id). Must return ZERO rows.
-- ============================================================================
select
  count(*)                                as rows_sharing_a_stripe_subscription_id,
  array_agg(distinct s.organization_id)   as affected_organization_ids,
  array_agg(s.id order by s.id)           as affected_subscription_row_ids
from public.organization_subscriptions s
where s.stripe_subscription_id is not null
  and s.stripe_subscription_id in (
    select stripe_subscription_id
    from public.organization_subscriptions
    where stripe_subscription_id is not null
    group by stripe_subscription_id
    having count(*) > 1
  );

-- ============================================================================
-- G. billing_records: duplicate NON-NULL stripe_invoice_id  --> BLOCKER for
--    UNIQUE (stripe_invoice_id). Must return ZERO rows.
--    Reports only counts + internal ids, never the Stripe invoice id.
-- ============================================================================
select count(*) as total_billing_records
from public.billing_records;

select
  count(*)                                as rows_sharing_a_stripe_invoice_id,
  array_agg(distinct b.organization_id)   as affected_organization_ids,
  array_agg(b.id order by b.id)           as affected_billing_record_ids
from public.billing_records b
where b.stripe_invoice_id is not null
  and b.stripe_invoice_id in (
    select stripe_invoice_id
    from public.billing_records
    where stripe_invoice_id is not null
    group by stripe_invoice_id
    having count(*) > 1
  );

-- ============================================================================
-- H. Current subscription_status enum values (confirm the additive set
--    0119 targets: it should ADD 'incomplete_expired' and 'unpaid' and
--    change nothing else).
-- ============================================================================
select e.enumsortorder, e.enumlabel
from pg_type t
join pg_enum e on e.enumtypid = t.oid
join pg_namespace n on n.oid = t.typnamespace
where n.nspname = 'public' and t.typname = 'subscription_status'
order by e.enumsortorder;
-- expect exactly: trialing, active, past_due, canceled, incomplete, paused.
