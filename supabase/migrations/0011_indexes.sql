-- =============================================================================
-- 0011_indexes.sql
-- Performance indexes. Every organization_id column gets a btree index
-- automatically (critical: it's the column every RLS policy filters on).
-- Beyond that, add targeted indexes for the query patterns the app actually
-- runs (status filters, dashboard widgets, FK lookups).
-- =============================================================================

-- ---------------------------------------------------------------------------
-- organization_id on every tenant table (auto-discovered; idempotent).
-- ---------------------------------------------------------------------------
do $$
declare
  t record;
begin
  for t in
    select table_name from information_schema.columns
    where table_schema = 'public' and column_name = 'organization_id'
  loop
    execute format(
      'create index if not exists idx_%s_organization_id on public.%I (organization_id);',
      t.table_name, t.table_name
    );
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- Loads / dispatches / tracking
-- ---------------------------------------------------------------------------
create index if not exists idx_loads_status on public.loads (organization_id, status);
create index if not exists idx_loads_broker on public.loads (broker_id);
create index if not exists idx_loads_customer on public.loads (customer_id);

create index if not exists idx_load_stops_load on public.load_stops (load_id, stop_sequence);

create index if not exists idx_dispatches_load on public.dispatches (load_id);
create index if not exists idx_dispatches_status on public.dispatches (organization_id, status);
create index if not exists idx_dispatches_carrier on public.dispatches (carrier_id);
create index if not exists idx_dispatches_truck on public.dispatches (truck_id);
create index if not exists idx_dispatches_driver on public.dispatches (driver_id);

create index if not exists idx_load_tracking_load on public.load_tracking_events (load_id, occurred_at desc);

-- ---------------------------------------------------------------------------
-- Fleet & partners
-- ---------------------------------------------------------------------------
create index if not exists idx_drivers_carrier on public.drivers (carrier_id);
create index if not exists idx_trucks_carrier on public.trucks (carrier_id);
create index if not exists idx_trailers_carrier on public.trailers (carrier_id);
create index if not exists idx_truck_driver_assignments_driver on public.truck_driver_assignments (driver_id);

-- ---------------------------------------------------------------------------
-- Documents & compliance -- expiry lookups drive the Compliance dashboard.
-- ---------------------------------------------------------------------------
create index if not exists idx_documents_entity on public.documents (entity_type, entity_id);
create index if not exists idx_documents_expiry on public.documents (expiry_date) where expiry_date is not null;

create index if not exists idx_compliance_entity on public.compliance_items (entity_type, entity_id);
create index if not exists idx_compliance_expiry on public.compliance_items (expiry_date) where status <> 'waived';
create index if not exists idx_compliance_status on public.compliance_items (organization_id, status);

-- ---------------------------------------------------------------------------
-- Financial
-- ---------------------------------------------------------------------------
create index if not exists idx_invoices_status on public.invoices (organization_id, status);
create index if not exists idx_invoices_dispatch on public.invoices (dispatch_id);
create index if not exists idx_invoice_line_items_invoice on public.invoice_line_items (invoice_id);
create index if not exists idx_payments_invoice on public.payments (invoice_id);

create index if not exists idx_settlements_carrier on public.settlements (carrier_id);
create index if not exists idx_settlements_status on public.settlements (organization_id, status);
create index if not exists idx_settlement_line_items_settlement on public.settlement_line_items (settlement_id);

create index if not exists idx_expenses_date on public.expenses (organization_id, expense_date desc);
create index if not exists idx_fuel_logs_truck on public.fuel_logs (truck_id, purchased_at desc);
create index if not exists idx_maintenance_truck on public.maintenance_records (truck_id, service_date desc);
create index if not exists idx_maintenance_trailer on public.maintenance_records (trailer_id, service_date desc);

-- ---------------------------------------------------------------------------
-- Productivity
-- ---------------------------------------------------------------------------
create index if not exists idx_tasks_assigned_open on public.tasks (assigned_to) where status not in ('completed', 'cancelled');
create index if not exists idx_notes_entity on public.notes (entity_type, entity_id);
create index if not exists idx_activity_logs_entity on public.activity_logs (entity_type, entity_id, created_at desc);
create index if not exists idx_notifications_unread on public.notifications (profile_id) where read_at is null;
