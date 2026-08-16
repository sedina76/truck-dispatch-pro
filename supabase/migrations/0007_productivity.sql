-- =============================================================================
-- 0007_productivity.sql
-- Cross-cutting productivity tables: tasks/follow-ups, notes, an immutable
-- activity/audit log, and in-app notifications.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- tasks: follow-ups, optionally attached to any entity (a load, a carrier,
-- an expiring document, etc.) via the polymorphic entity_type/entity_id pair.
-- ---------------------------------------------------------------------------
create table public.tasks (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  entity_type public.entity_type,
  entity_id uuid,
  title text not null,
  description text,
  status public.task_status not null default 'open',
  priority public.task_priority not null default 'medium',
  due_at timestamptz,
  assigned_to uuid references public.profiles (id) on delete set null,
  created_by uuid references public.profiles (id) on delete set null,
  completed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- notes: free-text notes attached to any entity.
-- ---------------------------------------------------------------------------
create table public.notes (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  entity_type public.entity_type not null,
  entity_id uuid not null,
  body text not null,
  is_pinned boolean not null default false,
  created_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- activity_logs: append-only audit trail. Rows are written exclusively via
-- the log_activity() SECURITY DEFINER function (see 0009) -- there is no
-- direct insert/update/delete policy for authenticated users, so the trail
-- cannot be edited or backdated from the client.
-- ---------------------------------------------------------------------------
create table public.activity_logs (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  entity_type public.entity_type not null,
  entity_id uuid not null,
  action text not null,
  actor_id uuid references public.profiles (id) on delete set null,
  changes jsonb,
  created_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- notifications: in-app notifications for a single recipient profile.
-- ---------------------------------------------------------------------------
create table public.notifications (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  profile_id uuid not null references public.profiles (id) on delete cascade,
  type public.notification_type not null,
  title text not null,
  body text,
  entity_type public.entity_type,
  entity_id uuid,
  read_at timestamptz,
  created_at timestamptz not null default now()
);
