-- =============================================================================
-- 0056_integrations_center.sql
-- Upgrades integration_settings (0008) from a bare is_enabled boolean into
-- real per-org connection state, backing a real Integrations Center
-- (src/lib/integrations/registry.ts + status.ts). Provider-level STATIC
-- metadata (name, category, connection type, capabilities, requirements,
-- whether a real connector exists) intentionally stays in the TypeScript
-- registry, not duplicated into columns here -- this table only ever holds
-- per-org DYNAMIC state (is it enabled, has it been tested, when, with what
-- result). "Connected" is deliberately never a stored column: it's always
-- derived (registry.implemented && configured && last_test_status =
-- 'success' [&& not stale]), computed in src/lib/integrations/status.ts, so
-- there is no boolean anywhere that can lie about being "Active".
-- =============================================================================

-- log_activity() takes a closed entity_type enum; Integration
-- configure/test/enable/disable/disconnect events need their own value.
-- Additive only -- every existing value and every existing row is untouched.
alter type public.entity_type add value if not exists 'integration';

alter table public.integration_settings
  -- Human-meaningful label for whichever account got connected -- "ABC
  -- Logistics" for a QuickBooks company, the verified sender address for
  -- Resend, etc. Never a secret.
  add column if not exists account_label text,
  -- The provider's own identifier for the connected account/company/tenant
  -- (QuickBooks realm ID, etc.) -- an opaque reference, not a credential.
  add column if not exists external_account_id text,
  add column if not exists last_connected_at timestamptz,
  add column if not exists last_tested_at timestamptz,
  add column if not exists last_test_status text,
  add column if not exists last_test_message text,
  add column if not exists last_error_code text,
  add column if not exists last_error_message text,
  -- Distinct from is_enabled=false (Disable, spec section 34): set only by
  -- an explicit Disconnect, which also clears account_label/
  -- external_account_id below -- disabling never touches this.
  add column if not exists disconnected_at timestamptz,
  add column if not exists created_by uuid references public.profiles (id) on delete set null,
  add column if not exists updated_by uuid references public.profiles (id) on delete set null;

alter table public.integration_settings
  add constraint integration_settings_last_test_status_check
    check (last_test_status is null or last_test_status in ('success', 'failure'));

comment on table public.integration_settings is
  'Per-org third-party integration STATE (not metadata -- see src/lib/integrations/registry.ts for provider name/category/connection-type/capabilities). is_enabled alone never implies "connected"; see src/lib/integrations/status.ts for the real derivation. credentials jsonb is unused in production: no currently-implemented provider stores a per-org secret here (Resend''s credential is a platform-wide server env var). If a future provider needs one, use Supabase Vault or equivalent -- do not start writing raw secrets into this column.';

comment on column public.integration_settings.credentials is
  'Unused placeholder for a future per-org secret reference (a Vault secret id, never a raw value). No current code path writes to this column.';
