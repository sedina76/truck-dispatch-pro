-- =============================================================================
-- 0005_documents_compliance.sql
-- Polymorphic document storage (rate cons, BOL, POD, CDL, insurance, W9,
-- authority, registration, IFTA, factoring letters, etc.) and the compliance
-- tracker for expiring credentials.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- documents: polymorphic file attachment. entity_type + entity_id point at
-- the owning row (load, dispatch, carrier, driver, truck, trailer, ...).
-- file_path is a Supabase Storage object path, not the raw file.
-- ---------------------------------------------------------------------------
create table public.documents (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  entity_type public.entity_type not null,
  entity_id uuid not null,
  document_type public.document_type not null,
  file_name text not null,
  file_path text not null,
  file_size_bytes bigint,
  mime_type text,
  issued_date date,
  expiry_date date,
  is_verified boolean not null default false,
  verified_by uuid references public.profiles (id) on delete set null,
  verified_at timestamptz,
  uploaded_by uuid references public.profiles (id) on delete set null,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table public.documents is 'Polymorphic file registry. file_path references an object in the "documents" Supabase Storage bucket, namespaced by organization_id.';

-- ---------------------------------------------------------------------------
-- compliance_items: tracks credentials/requirements that expire (CDL,
-- insurance, medical card, registration, authority, inspection, IFTA,
-- drug tests). Optionally linked to the document that proves compliance.
-- status is kept current by the refresh_compliance_statuses() scheduled job.
-- ---------------------------------------------------------------------------
create table public.compliance_items (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  entity_type public.entity_type not null,
  entity_id uuid not null,
  item_type public.compliance_item_type not null,
  document_id uuid references public.documents (id) on delete set null,
  expiry_date date,
  status public.compliance_status not null default 'valid',
  reminder_sent_at timestamptz,
  resolved_at timestamptz,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table public.compliance_items is 'Expiring-credential tracker driving the Compliance dashboard and expiry notifications.';
