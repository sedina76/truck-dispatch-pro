-- =============================================================================
-- 0039_print_export_email.sql
-- Toolbar Print/Export/Email module. Print (window.print()/existing PDF
-- routes) and Export (CSV, server-side RLS-scoped queries) need no schema
-- changes at all. Email needs exactly one thing: a place to honestly
-- record send attempts (including BLOCKED ones -- no provider is
-- configured anywhere in this project, confirmed by inspecting package.json
-- and every .env* file: no Resend/SendGrid/Postmark/SES/SMTP/nodemailer
-- dependency or credential exists). No equivalent audit table existed
-- (checked: no reminder_log/email_log/collection_reminders table anywhere
-- in prior migrations) so a minimal one is added here, matching the exact
-- field list from the chat spec.
--
-- Never SECURITY DEFINER -- selects/inserts run under the caller's own
-- RLS, same canonical pattern as every other table this session.
-- =============================================================================

create type public.email_send_status as enum ('sent', 'blocked', 'failed');

create table public.email_send_log (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  entity_type text not null,
  entity_id uuid not null,
  recipient text not null,
  cc text,
  subject text not null,
  attachment_type text,
  status public.email_send_status not null,
  error text,
  sent_by uuid references public.profiles (id) on delete set null,
  sent_at timestamptz not null default now(),
  constraint email_send_log_failure_requires_error check (status = 'sent' or error is not null)
);

comment on table public.email_send_log is
  'Every Print/Export/Email toolbar send attempt, including blocked ones (no email provider configured -- status stays blocked/failed, never sent, until a real provider exists). Never written to on a merely-opened compose dialog, only on an actual Send click.';

create index idx_email_send_log_entity on public.email_send_log (organization_id, entity_type, entity_id, sent_at desc);

alter table public.email_send_log enable row level security;

create policy email_send_log_select on public.email_send_log
  for select using (organization_id = public.current_org_id());

create policy email_send_log_insert on public.email_send_log
  for insert with check (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin', 'accountant', 'dispatcher']::public.org_role[])
  );

-- No update/delete policy -- append-only audit trail, matching every other
-- audit-style table in this codebase (driver_pii_access_log, etc).
