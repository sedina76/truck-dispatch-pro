-- =============================================================================
-- 0008_integrations.sql
-- Per-tenant integration configuration for third-party services: load
-- boards (DAT, Truckstop, 123Loadboard), accounting (QuickBooks), billing
-- (Stripe), comms (Twilio, SendGrid), telematics (Motive, Samsara), and
-- compliance/monitoring (RMIS, Highway, Carrier411).
-- =============================================================================

create table public.integration_settings (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  provider public.integration_provider not null,
  is_enabled boolean not null default false,
  -- NOTE: for production, do not store raw secrets in this jsonb column.
  -- Use Supabase Vault (or an equivalent KMS-backed secret store) and keep
  -- only opaque references (e.g. a vault secret id) here.
  credentials jsonb not null default '{}'::jsonb,
  config jsonb not null default '{}'::jsonb,
  last_synced_at timestamptz,
  last_sync_status text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organization_id, provider)
);

comment on table public.integration_settings is 'Per-org third-party integration config/credentials. Restricted to owner/admin via RLS (see 0010).';
