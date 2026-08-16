-- =============================================================================
-- 0001_extensions_enums_helpers.sql
-- Extensions, enumerated types, and reusable helper functions.
-- Everything downstream (tables, RLS, triggers) depends on this file.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Extensions
-- ---------------------------------------------------------------------------
create extension if not exists pgcrypto;   -- gen_random_uuid()
create extension if not exists pg_cron;    -- scheduled jobs (compliance status refresh, etc.)

-- ---------------------------------------------------------------------------
-- Enumerated types
-- ---------------------------------------------------------------------------

-- Tenancy / identity
create type public.org_role as enum (
  'owner', 'admin', 'dispatcher', 'accountant', 'driver', 'viewer'
);

-- Billing / subscriptions (platform-level SaaS billing, not freight billing)
create type public.subscription_tier as enum ('starter', 'professional', 'enterprise');
create type public.subscription_status as enum (
  'trialing', 'active', 'past_due', 'canceled', 'incomplete', 'paused'
);

-- Generic polymorphic entity reference (used by documents, compliance_items,
-- notes, tasks, activity_logs, notifications)
create type public.entity_type as enum (
  'organization', 'load', 'dispatch', 'carrier', 'broker', 'customer',
  'driver', 'truck', 'trailer', 'invoice', 'settlement', 'expense'
);

-- Fleet / partners
create type public.equipment_status as enum ('active', 'in_maintenance', 'out_of_service', 'inactive');
create type public.driver_status as enum ('active', 'inactive', 'on_leave', 'terminated', 'applicant');

-- Operations
create type public.load_status as enum (
  'draft', 'posted', 'booked', 'dispatched', 'in_transit', 'at_pickup',
  'at_delivery', 'delivered', 'pod_received', 'invoiced', 'closed',
  'cancelled', 'problem'
);
create type public.stop_type as enum ('pickup', 'delivery');
create type public.dispatch_status as enum (
  'assigned', 'accepted', 'en_route_to_pickup', 'at_pickup', 'loaded',
  'en_route_to_delivery', 'at_delivery', 'delivered', 'completed', 'cancelled'
);

-- Documents / compliance
create type public.document_type as enum (
  'rate_confirmation', 'bol', 'pod', 'cdl', 'insurance_certificate', 'w9',
  'motor_carrier_authority', 'vehicle_registration', 'ifta_credential',
  'factoring_notice', 'medical_card', 'inspection_report',
  'notice_of_assignment', 'other'
);
create type public.compliance_item_type as enum (
  'cdl_expiry', 'medical_card_expiry', 'insurance_expiry',
  'registration_expiry', 'authority_expiry', 'annual_inspection',
  'drug_test', 'ifta_renewal', 'other'
);
create type public.compliance_status as enum ('valid', 'expiring_soon', 'expired', 'missing', 'waived');

-- Financial
create type public.invoice_status as enum (
  'draft', 'sent', 'viewed', 'partially_paid', 'paid', 'overdue', 'void', 'disputed'
);
create type public.payment_method as enum ('ach', 'wire', 'check', 'credit_card', 'cash', 'factoring', 'other');
create type public.settlement_status as enum ('pending', 'approved', 'paid', 'on_hold', 'disputed', 'cancelled');
create type public.expense_category as enum (
  'fuel', 'maintenance', 'tolls', 'permits_and_licenses', 'insurance',
  'payroll', 'office', 'lease_or_loan', 'other'
);

-- Productivity
create type public.task_status as enum ('open', 'in_progress', 'completed', 'cancelled');
create type public.task_priority as enum ('low', 'medium', 'high', 'urgent');
create type public.notification_type as enum (
  'load_status_change', 'dispatch_assigned', 'document_expiring', 'document_expired',
  'invoice_overdue', 'payment_received', 'settlement_ready', 'task_due', 'system', 'mention'
);

-- Integrations
create type public.integration_provider as enum (
  'dat', 'truckstop', 'loadboard_123', 'quickbooks', 'stripe', 'twilio',
  'sendgrid', 'motive', 'samsara', 'rmis', 'highway', 'carrier411'
);

-- ---------------------------------------------------------------------------
-- Helper functions (used pervasively by RLS policies and triggers)
--
-- NOTE: public.current_org_id() / current_role() / has_role() are NOT
-- defined here even though they conceptually belong with these helpers --
-- they read from public.profiles, which does not exist until
-- 0002_core_saas_tables.sql. LANGUAGE SQL functions are parse-analyzed
-- against real catalog objects at CREATE FUNCTION time, so defining them
-- before their target table exists fails migration application. They are
-- defined at the bottom of 0002, immediately after `profiles` is created.
-- ---------------------------------------------------------------------------

-- Generic updated_at maintenance trigger, attached to every table that has
-- an `updated_at` column (wired up automatically in 0009_functions_triggers.sql).
create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;
