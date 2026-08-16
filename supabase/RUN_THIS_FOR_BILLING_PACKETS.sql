-- ---------------------------------------------------------------------------
-- Billing Packet workflow. Reuses public.documents for every supporting
-- document (POD, rate confirmation, BOL, accessorials) -- no competing
-- document table. Only the packet itself (a generated, merged PDF) needs
-- new metadata storage, since it isn't a document someone uploaded.
-- ---------------------------------------------------------------------------

alter type public.document_type add value if not exists 'lumper_receipt';
alter type public.document_type add value if not exists 'detention_document';
alter type public.document_type add value if not exists 'scale_ticket';

create type public.billing_packet_status as enum ('generated', 'outdated', 'sent');

-- ---------------------------------------------------------------------------
-- billing_packets: metadata for each generated packet PDF. A new row per
-- generation (version + 1), never edited in place -- same "append, don't
-- overwrite" pattern as documents.rejected_at/POD replacement, so packet
-- history is never lost. document_snapshot freezes exactly which document
-- rows (id + created_at) were included, which is what regeneration compares
-- against to decide whether a packet is stale -- never filenames alone.
-- ---------------------------------------------------------------------------
create table public.billing_packets (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  invoice_id uuid not null references public.invoices (id) on delete cascade,
  version integer not null,
  status public.billing_packet_status not null default 'generated',
  storage_path text not null,
  document_snapshot jsonb not null default '[]'::jsonb,
  generated_at timestamptz not null default now(),
  generated_by uuid references public.profiles (id) on delete set null,
  sent_at timestamptz,
  sent_by uuid references public.profiles (id) on delete set null,
  recipient_email text,
  created_at timestamptz not null default now(),
  unique (invoice_id, version)
);

comment on table public.billing_packets is
  'One row per generated packet PDF (a version), not one row per invoice -- regenerating never overwrites history. document_snapshot is an array of {document_id, document_type, created_at} for every source document included, used to detect staleness when a POD/rate-con/BOL is later replaced.';

create index idx_billing_packets_invoice_id on public.billing_packets (invoice_id, version desc);

alter table public.billing_packets enable row level security;

-- Same access tier as invoices themselves (0010_rls_policies.sql):
-- select any org member, write owner/admin/accountant.
create policy billing_packets_select on public.billing_packets
  for select using (organization_id = public.current_org_id());

create policy billing_packets_insert on public.billing_packets
  for insert with check (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin', 'accountant']::public.org_role[])
  );

create policy billing_packets_update on public.billing_packets
  for update using (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin', 'accountant']::public.org_role[])
  )
  with check (organization_id = public.current_org_id());

-- ---------------------------------------------------------------------------
-- Private storage bucket for generated packet PDFs.
-- ---------------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('billing-packets', 'billing-packets', false, 26214400, array['application/pdf'])
on conflict (id) do nothing;

create policy billing_packets_storage_select on storage.objects
  for select using (
    bucket_id = 'billing-packets'
    and (storage.foldername(name))[1] = public.current_org_id()::text
  );

create policy billing_packets_storage_insert on storage.objects
  for insert with check (
    bucket_id = 'billing-packets'
    and (storage.foldername(name))[1] = public.current_org_id()::text
    and public.has_role(array['owner', 'admin', 'accountant']::public.org_role[])
  );
