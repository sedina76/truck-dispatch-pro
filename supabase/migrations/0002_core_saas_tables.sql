-- =============================================================================
-- 0002_core_saas_tables.sql
-- Tenancy root (organizations), identity (profiles), and platform-level
-- SaaS subscription/billing tables (Starter / Professional / Enterprise).
-- =============================================================================

-- ---------------------------------------------------------------------------
-- organizations: the tenant root. Every business table hangs off this via
-- organization_id, either directly or transitively.
-- ---------------------------------------------------------------------------
create table public.organizations (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  slug text not null unique,
  dba_name text,
  mc_number text,
  dot_number text,
  business_phone text,
  business_email text,
  address_line1 text,
  address_line2 text,
  city text,
  state text,
  postal_code text,
  country text not null default 'US',
  timezone text not null default 'America/Chicago',
  logo_url text,
  is_active boolean not null default true,
  trial_ends_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table public.organizations is 'Tenant root. One row per dispatch company.';

-- ---------------------------------------------------------------------------
-- profiles: application-level user record, 1:1 with auth.users. Created
-- automatically by the handle_new_user() trigger (see 0009).
-- ---------------------------------------------------------------------------
create table public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  organization_id uuid references public.organizations (id) on delete cascade,
  full_name text not null,
  email text not null,
  phone text,
  avatar_url text,
  role public.org_role not null default 'dispatcher',
  is_active boolean not null default true,
  last_seen_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table public.profiles is 'App-level user profile + org membership + role. organization_id is null until onboarding assigns/creates an org.';
comment on column public.profiles.role is 'Coarse-grained RBAC. See docs/PLAN.md for the full permission matrix per role.';

-- ---------------------------------------------------------------------------
-- Tenant-scoping helper functions. Defined here (rather than in 0001 with
-- the other helpers) because they read from `profiles`, which must exist
-- first -- LANGUAGE SQL functions are parse-analyzed against real catalog
-- objects at CREATE FUNCTION time. All RLS policies (0010) build on these.
-- SECURITY DEFINER + fixed search_path: lets them read `profiles` even when
-- the calling role's own RLS would otherwise block that read, and prevents
-- search_path hijacking.
-- ---------------------------------------------------------------------------

-- Returns the organization_id of the currently authenticated user.
create or replace function public.current_org_id()
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select organization_id from public.profiles where id = auth.uid();
$$;

-- Returns the org_role of the currently authenticated user.
create or replace function public.current_role()
returns public.org_role
language sql
stable
security definer
set search_path = public
as $$
  select role from public.profiles where id = auth.uid();
$$;

-- True if the current user's role is one of the given roles. Used as the
-- standard building block for RLS write policies, e.g.:
--   public.has_role(array['owner','admin']::public.org_role[])
create or replace function public.has_role(p_roles public.org_role[])
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select public.current_role() = any(p_roles);
$$;

grant execute on function public.current_org_id() to authenticated;
grant execute on function public.current_role() to authenticated;
grant execute on function public.has_role(public.org_role[]) to authenticated;

-- ---------------------------------------------------------------------------
-- subscription_plans: global catalog (NOT tenant-scoped). Seeded with
-- Starter / Professional / Enterprise; managed by the platform operator.
-- ---------------------------------------------------------------------------
create table public.subscription_plans (
  id uuid primary key default gen_random_uuid(),
  tier public.subscription_tier not null unique,
  name text not null,
  description text,
  monthly_price_cents integer not null,
  annual_price_cents integer,
  max_users integer,
  max_trucks integer,
  max_active_loads integer,
  features jsonb not null default '[]'::jsonb,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table public.subscription_plans is 'Global plan catalog. Not org-scoped; writable only by service_role.';

-- ---------------------------------------------------------------------------
-- organization_subscriptions: which plan a tenant is on, mirrored from Stripe.
-- ---------------------------------------------------------------------------
create table public.organization_subscriptions (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  plan_id uuid not null references public.subscription_plans (id),
  status public.subscription_status not null default 'trialing',
  billing_cycle text not null default 'monthly' check (billing_cycle in ('monthly', 'annual')),
  stripe_customer_id text,
  stripe_subscription_id text,
  current_period_start timestamptz,
  current_period_end timestamptz,
  cancel_at_period_end boolean not null default false,
  canceled_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table public.organization_subscriptions is 'Tenant subscription state, kept in sync with Stripe via webhooks (service_role writes only).';

-- ---------------------------------------------------------------------------
-- billing_records: platform invoices issued to a tenant for their SaaS
-- subscription (distinct from freight `invoices`, which bill brokers/customers).
-- ---------------------------------------------------------------------------
create table public.billing_records (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  organization_subscription_id uuid references public.organization_subscriptions (id) on delete set null,
  stripe_invoice_id text,
  amount_cents integer not null,
  currency text not null default 'usd',
  status text not null default 'open' check (status in ('open', 'paid', 'void', 'uncollectible')),
  invoice_pdf_url text,
  period_start timestamptz,
  period_end timestamptz,
  paid_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table public.billing_records is 'Platform SaaS billing history (Stripe invoices for the tenant''s own subscription).';
