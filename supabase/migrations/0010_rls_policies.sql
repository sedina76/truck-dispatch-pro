-- =============================================================================
-- 0010_rls_policies.sql
-- Row Level Security for every tenant table. Baseline rule: a row is only
-- visible/writable if its organization_id matches public.current_org_id()
-- (see 0001). Sensitive tables (billing, integrations, audit log) add
-- role-based restrictions on top via public.has_role().
--
-- Role tiers used below:
--   operational_write := owner, admin, dispatcher      (day-to-day fleet/load ops)
--   financial_write   := owner, admin, accountant       (money-adjacent records)
--   admin_only        := owner, admin                   (destructive/sensitive)
--   owner_only        := owner                           (org-level settings)
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Base table grants. RLS policies only ever narrow what a row-owning grant
-- already permits -- without this, `authenticated` has zero access and
-- every policy below is moot. (On Supabase's hosted platform this is
-- pre-configured for you via default privileges; it is included here
-- explicitly so this schema is portable to any plain Postgres instance.)
-- No grants to `anon`: this product has no unauthenticated read surface.
-- ---------------------------------------------------------------------------
grant usage on schema public to authenticated;
grant select, insert, update, delete on all tables in schema public to authenticated;
alter default privileges in schema public grant select, insert, update, delete on tables to authenticated;

-- ---------------------------------------------------------------------------
-- organizations
-- ---------------------------------------------------------------------------
alter table public.organizations enable row level security;

create policy organizations_select on public.organizations
  for select using (id = public.current_org_id());

-- Any authenticated user may create a brand-new organization during
-- onboarding; the app must immediately assign the creator as 'owner' via a
-- follow-up profile update (a SECURITY DEFINER RPC is recommended so the
-- two steps happen atomically).
create policy organizations_insert on public.organizations
  for insert with check (auth.uid() is not null);

create policy organizations_update on public.organizations
  for update using (id = public.current_org_id() and public.has_role(array['owner']::public.org_role[]))
  with check (id = public.current_org_id());

create policy organizations_delete on public.organizations
  for delete using (id = public.current_org_id() and public.has_role(array['owner']::public.org_role[]));

-- ---------------------------------------------------------------------------
-- profiles
-- No insert policy: rows are created exclusively by the handle_new_user()
-- trigger, which is SECURITY DEFINER and bypasses RLS.
-- ---------------------------------------------------------------------------
alter table public.profiles enable row level security;

create policy profiles_select on public.profiles
  for select using (organization_id = public.current_org_id() or id = auth.uid());

create policy profiles_update_self on public.profiles
  for update using (id = auth.uid())
  with check (id = auth.uid());

create policy profiles_update_admin on public.profiles
  for update using (organization_id = public.current_org_id() and public.has_role(array['owner', 'admin']::public.org_role[]))
  with check (organization_id = public.current_org_id());

create policy profiles_delete on public.profiles
  for delete using (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin']::public.org_role[])
    and id <> auth.uid()
  );

-- ---------------------------------------------------------------------------
-- subscription_plans: global read-only catalog. No write policy for
-- authenticated users -- only service_role (which bypasses RLS) manages it.
-- ---------------------------------------------------------------------------
alter table public.subscription_plans enable row level security;

create policy subscription_plans_select on public.subscription_plans
  for select using (true);

-- ---------------------------------------------------------------------------
-- organization_subscriptions / billing_records: owner/admin read-only.
-- Writes happen exclusively via service_role from Stripe webhook handlers.
-- ---------------------------------------------------------------------------
alter table public.organization_subscriptions enable row level security;

create policy organization_subscriptions_select on public.organization_subscriptions
  for select using (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin']::public.org_role[])
  );

alter table public.billing_records enable row level security;

create policy billing_records_select on public.billing_records
  for select using (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin']::public.org_role[])
  );

-- ---------------------------------------------------------------------------
-- Fleet & partners: standard operational CRUD.
-- select: any org member. write: owner/admin/dispatcher. delete: owner/admin.
-- ---------------------------------------------------------------------------
do $$
declare
  t text;
  standard_tables text[] := array[
    'carriers', 'brokers', 'customers', 'drivers', 'trucks', 'trailers',
    'loads', 'load_stops', 'dispatches', 'load_tracking_events',
    'documents', 'compliance_items'
  ];
begin
  foreach t in array standard_tables loop
    execute format('alter table public.%I enable row level security;', t);

    execute format($p$
      create policy %1$I_select on public.%1$I
        for select using (organization_id = public.current_org_id());
    $p$, t);

    execute format($p$
      create policy %1$I_insert on public.%1$I
        for insert with check (
          organization_id = public.current_org_id()
          and public.has_role(array['owner','admin','dispatcher']::public.org_role[])
        );
    $p$, t);

    execute format($p$
      create policy %1$I_update on public.%1$I
        for update using (
          organization_id = public.current_org_id()
          and public.has_role(array['owner','admin','dispatcher']::public.org_role[])
        )
        with check (organization_id = public.current_org_id());
    $p$, t);

    execute format($p$
      create policy %1$I_delete on public.%1$I
        for delete using (
          organization_id = public.current_org_id()
          and public.has_role(array['owner','admin']::public.org_role[])
        );
    $p$, t);
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- truck_driver_assignments: same operational tier as fleet tables above.
-- ---------------------------------------------------------------------------
alter table public.truck_driver_assignments enable row level security;

create policy truck_driver_assignments_select on public.truck_driver_assignments
  for select using (organization_id = public.current_org_id());

create policy truck_driver_assignments_insert on public.truck_driver_assignments
  for insert with check (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin', 'dispatcher']::public.org_role[])
  );

create policy truck_driver_assignments_update on public.truck_driver_assignments
  for update using (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin', 'dispatcher']::public.org_role[])
  )
  with check (organization_id = public.current_org_id());

create policy truck_driver_assignments_delete on public.truck_driver_assignments
  for delete using (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin']::public.org_role[])
  );

-- ---------------------------------------------------------------------------
-- Financial: invoices, payments, settlements, expenses, fuel, maintenance.
-- select: any org member. write: owner/admin/accountant (+ dispatcher for
-- the operational cost tables: expenses/fuel_logs/maintenance_records).
-- delete: owner/admin/accountant.
-- ---------------------------------------------------------------------------
do $$
declare
  t text;
  financial_tables text[] := array['invoices', 'settlements'];
  ops_cost_tables text[] := array['expenses', 'fuel_logs', 'maintenance_records'];
  child_tables text[] := array['invoice_line_items', 'payments', 'settlement_line_items'];
begin
  foreach t in array financial_tables || ops_cost_tables loop
    execute format('alter table public.%I enable row level security;', t);

    execute format($p$
      create policy %1$I_select on public.%1$I
        for select using (organization_id = public.current_org_id());
    $p$, t);

    execute format($p$
      create policy %1$I_delete on public.%1$I
        for delete using (
          organization_id = public.current_org_id()
          and public.has_role(array['owner','admin','accountant']::public.org_role[])
        );
    $p$, t);
  end loop;

  -- invoices / settlements: owner/admin/accountant only
  foreach t in array financial_tables loop
    execute format($p$
      create policy %1$I_insert on public.%1$I
        for insert with check (
          organization_id = public.current_org_id()
          and public.has_role(array['owner','admin','accountant']::public.org_role[])
        );
    $p$, t);

    execute format($p$
      create policy %1$I_update on public.%1$I
        for update using (
          organization_id = public.current_org_id()
          and public.has_role(array['owner','admin','accountant']::public.org_role[])
        )
        with check (organization_id = public.current_org_id());
    $p$, t);
  end loop;

  -- expenses / fuel_logs / maintenance_records: dispatchers can log these too
  foreach t in array ops_cost_tables loop
    execute format($p$
      create policy %1$I_insert on public.%1$I
        for insert with check (
          organization_id = public.current_org_id()
          and public.has_role(array['owner','admin','accountant','dispatcher']::public.org_role[])
        );
    $p$, t);

    execute format($p$
      create policy %1$I_update on public.%1$I
        for update using (
          organization_id = public.current_org_id()
          and public.has_role(array['owner','admin','accountant','dispatcher']::public.org_role[])
        )
        with check (organization_id = public.current_org_id());
    $p$, t);
  end loop;

  -- child line-item tables inherit the parent's write tier
  foreach t in array child_tables loop
    execute format('alter table public.%I enable row level security;', t);

    execute format($p$
      create policy %1$I_select on public.%1$I
        for select using (organization_id = public.current_org_id());
    $p$, t);

    execute format($p$
      create policy %1$I_insert on public.%1$I
        for insert with check (
          organization_id = public.current_org_id()
          and public.has_role(array['owner','admin','accountant']::public.org_role[])
        );
    $p$, t);

    execute format($p$
      create policy %1$I_update on public.%1$I
        for update using (
          organization_id = public.current_org_id()
          and public.has_role(array['owner','admin','accountant']::public.org_role[])
        )
        with check (organization_id = public.current_org_id());
    $p$, t);

    execute format($p$
      create policy %1$I_delete on public.%1$I
        for delete using (
          organization_id = public.current_org_id()
          and public.has_role(array['owner','admin','accountant']::public.org_role[])
        );
    $p$, t);
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- tasks / notes: any org member (except viewer) can create; owner/admin or
-- the original author can delete.
-- ---------------------------------------------------------------------------
do $$
declare
  t text;
  collab_tables text[] := array['tasks', 'notes'];
begin
  foreach t in array collab_tables loop
    execute format('alter table public.%I enable row level security;', t);

    execute format($p$
      create policy %1$I_select on public.%1$I
        for select using (organization_id = public.current_org_id());
    $p$, t);

    execute format($p$
      create policy %1$I_insert on public.%1$I
        for insert with check (
          organization_id = public.current_org_id()
          and public.has_role(array['owner','admin','dispatcher','accountant']::public.org_role[])
        );
    $p$, t);

    execute format($p$
      create policy %1$I_update on public.%1$I
        for update using (organization_id = public.current_org_id())
        with check (organization_id = public.current_org_id());
    $p$, t);
  end loop;
end $$;

create policy tasks_delete on public.tasks
  for delete using (
    organization_id = public.current_org_id()
    and (public.has_role(array['owner', 'admin']::public.org_role[]) or created_by = auth.uid())
  );

create policy notes_delete on public.notes
  for delete using (
    organization_id = public.current_org_id()
    and (public.has_role(array['owner', 'admin']::public.org_role[]) or created_by = auth.uid())
  );

-- ---------------------------------------------------------------------------
-- activity_logs: immutable audit trail. Readable by org members; writable
-- only through the log_activity() SECURITY DEFINER function (0009) -- no
-- insert/update/delete policy is granted to authenticated users.
-- ---------------------------------------------------------------------------
alter table public.activity_logs enable row level security;

create policy activity_logs_select on public.activity_logs
  for select using (organization_id = public.current_org_id());

-- ---------------------------------------------------------------------------
-- notifications: strictly per-recipient. Delivery (insert) happens via
-- backend/service_role or SECURITY DEFINER RPCs, not direct client insert.
-- ---------------------------------------------------------------------------
alter table public.notifications enable row level security;

create policy notifications_select on public.notifications
  for select using (profile_id = auth.uid());

create policy notifications_update on public.notifications
  for update using (profile_id = auth.uid())
  with check (profile_id = auth.uid());

create policy notifications_delete on public.notifications
  for delete using (profile_id = auth.uid());

-- ---------------------------------------------------------------------------
-- integration_settings: owner/admin only, in every direction (holds
-- third-party credentials).
-- ---------------------------------------------------------------------------
alter table public.integration_settings enable row level security;

create policy integration_settings_select on public.integration_settings
  for select using (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin']::public.org_role[])
  );

create policy integration_settings_insert on public.integration_settings
  for insert with check (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin']::public.org_role[])
  );

create policy integration_settings_update on public.integration_settings
  for update using (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin']::public.org_role[])
  )
  with check (organization_id = public.current_org_id());

create policy integration_settings_delete on public.integration_settings
  for delete using (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin']::public.org_role[])
  );
