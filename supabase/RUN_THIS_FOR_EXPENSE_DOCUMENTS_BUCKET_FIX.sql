-- =============================================================================
-- 0052_expense_documents_bucket_policies.sql
--
-- BUG FOUND (live, during Fuel Recovery Test P -- receipt security):
-- migration 0040_expense_cost_management.sql already contains the
-- `expense-documents` storage bucket + its two RLS policies
-- (expense_documents_select / expense_documents_insert), and this
-- migration's own header/comments describe them as already live. They
-- were NOT: a live probe (storage.listBuckets()) confirmed the bucket
-- itself did not exist at all, and after creating it via the Storage API
-- (a data-plane operation, not DDL -- the only part of this gap fixable
-- without a migration), a real upload attempt still failed with
-- "new row violates row-level security policy," confirming the two RLS
-- policies from 0040 were never applied either. This is a PRE-EXISTING
-- gap that predates this session's Fuel work -- it silently also broke
-- the already-shipped Expense receipt upload feature
-- (uploadExpenseReceipt, src/app/(app)/expenses/actions.ts), which uses
-- the exact same bucket. Not caused by, and not specific to, Fuel Logs.
--
-- This migration only re-asserts the bucket + policies from 0040, fully
-- idempotently (safe to run even where 0040's storage section DID
-- apply correctly) -- no other schema, table, or trigger changes.
-- =============================================================================

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('expense-documents', 'expense-documents', false, 15728640, array['application/pdf', 'image/jpeg', 'image/png'])
on conflict (id) do nothing;

drop policy if exists expense_documents_select on storage.objects;
create policy expense_documents_select on storage.objects
  for select using (
    bucket_id = 'expense-documents'
    and (storage.foldername(name))[1] = public.current_org_id()::text
  );

drop policy if exists expense_documents_insert on storage.objects;
create policy expense_documents_insert on storage.objects
  for insert with check (
    bucket_id = 'expense-documents'
    and (storage.foldername(name))[1] = public.current_org_id()::text
    and public.has_role(array['owner', 'admin', 'accountant', 'dispatcher']::public.org_role[])
  );

-- No update/delete policy -- a receipt is never edited in place; a
-- correction is a new upload (fuel_logs) or void-and-re-enter (expenses),
-- matching every other document type in this schema (unchanged from 0040).
