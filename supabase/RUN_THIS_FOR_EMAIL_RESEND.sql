-- Wiring a real email provider (Resend) means email_send_log rows now need
-- to distinguish "we attempted this and it's still pending/failed" from
-- "Resend actually accepted it" -- sent_at was previously `not null default
-- now()`, so every row (including 'blocked'/'failed' ones) got a timestamp
-- at insert time regardless of outcome. That contradicts the audit contract
-- ("never write sent_at on failure"), so it's now nullable with no default;
-- the application sets it explicitly, only on a real 'sent' result.
-- Existing rows are untouched -- this only loosens the constraint, it never
-- rewrites data.
alter table public.email_send_log alter column sent_at drop not null;
alter table public.email_send_log alter column sent_at drop default;

-- Resend's message id, for support/debugging ("did this actually go out,
-- and which provider-side message is it"). Additive, nullable -- never
-- populated for blocked/failed attempts.
alter table public.email_send_log add column provider_message_id text;

comment on table public.email_send_log is
  'Every Print/Export/Email toolbar send attempt, including blocked ones (no email provider configured) and failed ones (provider rejected the send) -- status stays blocked/failed and sent_at stays null unless Resend actually accepted the send.';

comment on column public.email_send_log.sent_at is
  'Set only when status = sent (the real moment Resend accepted the send). Null for blocked/failed attempts.';

comment on column public.email_send_log.provider_message_id is
  'Resend message id from a successful send, for support/debugging. Null for blocked/failed attempts.';
