-- ---------------------------------------------------------------------------
-- Proof of Delivery (POD) workflow. Reuses the existing public.documents
-- table (entity_type = 'load', document_type = 'pod') rather than creating
-- a competing table -- both already exist. Only the rejection state is new.
-- ---------------------------------------------------------------------------

alter table public.documents
  add column rejected_at timestamptz,
  add column rejected_by uuid references public.profiles (id) on delete set null,
  add column rejection_reason text;

comment on column public.documents.rejected_at is
  'Set together with rejected_by/rejection_reason when a POD (or any document) is rejected. A row with rejected_at set and is_verified false is in the Rejected state; replacing it means uploading a new document row, not editing this one, so rejection history is never overwritten.';

-- Status for a given load's POD is a derived 4-state value computed from
-- documents rows, never stored redundantly:
--   no row                                -> Missing
--   row, rejected_at is null, not verified -> Uploaded
--   row, is_verified = true               -> Verified
--   row, rejected_at is not null          -> Rejected

-- ---------------------------------------------------------------------------
-- Private storage bucket for load documents (POD, and future load-linked
-- documents). No public access; every read goes through a signed URL with
-- an expiration, every write is checked by the policies below.
-- ---------------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('load-documents', 'load-documents', false, 15728640, array['application/pdf', 'image/jpeg', 'image/png'])
on conflict (id) do nothing;

-- Staff uploads/reads go through the authenticated Supabase client directly
-- (not a service-role route handler), so real Storage RLS policies are
-- needed here -- unlike the driver-application-documents bucket, where the
-- uploader has no Supabase Auth session at all and everything is mediated
-- by a trusted server-side route handler instead.
--
-- Objects are stored at {organization_id}/{load_id}/{filename}; policies
-- check the first path segment against the caller's own org.
create policy load_documents_select on storage.objects
  for select using (
    bucket_id = 'load-documents'
    and (storage.foldername(name))[1] = public.current_org_id()::text
  );

create policy load_documents_insert on storage.objects
  for insert with check (
    bucket_id = 'load-documents'
    and (storage.foldername(name))[1] = public.current_org_id()::text
    and public.has_role(array['owner', 'admin', 'dispatcher']::public.org_role[])
  );

-- No update/delete policy: a rejected or superseded POD is never edited or
-- removed in place (see the comment on documents.rejected_at) -- a
-- replacement is a new upload, new document row, new object path.

-- ---------------------------------------------------------------------------
-- Invoice send gate: a load's invoice cannot move from draft to sent
-- without a verified POD on file. Enforced here (not just in the UI) so it
-- holds regardless of which code path attempts the status change.
-- ---------------------------------------------------------------------------
create or replace function public.check_invoice_ready_to_send()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_has_verified_pod boolean;
begin
  if NEW.status is distinct from 'sent' or OLD.status = 'sent' then
    return NEW;
  end if;
  if NEW.load_id is null then
    -- Not tied to a load (a manually created invoice with no POD concept)
    -- -- nothing to gate.
    return NEW;
  end if;

  select exists (
    select 1 from public.documents
    where entity_type = 'load'
      and entity_id = NEW.load_id
      and document_type = 'pod'
      and is_verified = true
  ) into v_has_verified_pod;

  if not v_has_verified_pod then
    raise exception 'Cannot send invoice: Proof of Delivery is required and must be verified first.'
      using errcode = 'P0001';
  end if;

  return NEW;
end;
$$;

create trigger invoice_requires_verified_pod_to_send
  before update on public.invoices
  for each row execute function public.check_invoice_ready_to_send();
