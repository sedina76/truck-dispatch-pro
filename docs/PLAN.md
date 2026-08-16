# Truck Dispatch SaaS — Product & Implementation Plan

Companion doc to `supabase/migrations/`. The schema is the source of truth for
data shape; this doc covers everything around it: frontend structure, module
list, roles, dashboard metrics, roadmap, and integration notes.

## 1. Frontend folder structure (Next.js App Router + Supabase)

```
app/
  (auth)/
    login/page.tsx
    signup/page.tsx
    invite/[token]/page.tsx
  (app)/                          # authenticated, org-scoped shell
    layout.tsx                    # sidebar nav + org/role context
    dashboard/page.tsx
    carriers/
      page.tsx                    # list
      new/page.tsx
      [id]/page.tsx               # detail: drivers, trucks, trailers, docs
    brokers/
      page.tsx
      [id]/page.tsx
    customers/
      page.tsx
      [id]/page.tsx
    drivers/
      page.tsx
      [id]/page.tsx               # compliance status, assignment history
    trucks/
      page.tsx
      [id]/page.tsx               # current driver, maintenance, fuel history
    trailers/
      page.tsx
      [id]/page.tsx
    loads/
      page.tsx                    # list + filters
      new/page.tsx
      [id]/page.tsx               # stops, tracking timeline, documents
    dispatch/
      board/page.tsx              # kanban-style dispatch board (by status)
      [id]/page.tsx               # dispatch detail
    documents/page.tsx            # global document library + filters
    invoices/
      page.tsx
      new/page.tsx
      [id]/page.tsx
    payments/page.tsx
    settlements/
      page.tsx
      [id]/page.tsx
    compliance/page.tsx           # expiring/expired credential dashboard
    reports/
      page.tsx
      revenue/page.tsx
      carrier-performance/page.tsx
      broker-performance/page.tsx
    settings/
      profile/page.tsx
      organization/page.tsx
      users/page.tsx              # roles & invites
      integrations/page.tsx
      subscription/page.tsx
components/
  ui/                             # shadcn/ui primitives
  data-table/                     # shared table (sort/filter/paginate)
  forms/                          # react-hook-form + zod schemas per entity
  dispatch-board/                 # kanban columns, drag-and-drop cards
  charts/                         # dashboard/report visualizations
lib/
  supabase/
    client.ts                     # browser client
    server.ts                     # server component / route handler client
    middleware.ts                 # session refresh
  queries/                        # typed data-access functions per module
  validations/                    # zod schemas mirroring DB constraints
  permissions.ts                  # role -> allowed-actions map (mirrors RLS)
  utils/
types/
  supabase.ts                     # generated via `supabase gen types typescript`
```

**Stack recommendation:** Next.js (App Router) + TypeScript, Supabase JS
client, shadcn/ui + Tailwind, react-hook-form + zod, TanStack Table/Query.
Generate `types/supabase.ts` from the live schema so query results are typed
end-to-end — regenerate after every migration.

## 2. Full module list

| Module | Core tables |
|---|---|
| Organizations & Settings | `organizations`, `integration_settings` |
| Users / Profiles / Roles | `profiles` |
| Carriers | `carriers` |
| Brokers | `brokers` |
| Customers | `customers` |
| Drivers | `drivers`, `truck_driver_assignments` |
| Trucks | `trucks` |
| Trailers | `trailers` |
| Loads | `loads`, `load_stops` |
| Dispatch | `dispatches` |
| Load Tracking | `load_tracking_events` |
| Documents | `documents` |
| Compliance | `compliance_items` |
| Invoices | `invoices`, `invoice_line_items` |
| Payments | `payments` |
| Settlements | `settlements`, `settlement_line_items` |
| Expenses | `expenses` |
| Fuel | `fuel_logs` |
| Maintenance | `maintenance_records` |
| Tasks / Follow-ups | `tasks` |
| Notes | `notes` |
| Activity Logs | `activity_logs` |
| Notifications | `notifications` |
| Subscription Plans | `subscription_plans` |
| Org Subscriptions & Billing | `organization_subscriptions`, `billing_records` |
| Integration Settings | `integration_settings` |

## 3. Dashboard metrics

**Top-line KPI tiles**
- Active loads (by status: booked / dispatched / in transit)
- Loads delivered this week / this month
- Revenue booked this month (`sum(loads.rate)` for non-cancelled loads)
- Outstanding receivables (`sum(invoices.balance_due)` where status not in paid/void)
- Outstanding payables to carriers (`sum(settlements.net_amount)` where status = pending/approved)
- Average dispatch fee % and $ this month
- Fleet utilization: active dispatches / total active trucks

**Operational widgets**
- Dispatch board snapshot (counts per `dispatch_status`)
- Compliance alerts: items expiring in 7 / 30 days (`get_expiring_compliance_items`)
- Overdue invoices (`due_date < now()` and not paid)
- Open tasks due this week, grouped by assignee
- Recent activity feed (`activity_logs`, last 20)
- Top brokers by volume / avg days to pay
- Fuel spend and maintenance spend trend (last 6 months)

## 4. User roles & permissions

Role enum: `owner`, `admin`, `dispatcher`, `accountant`, `driver`, `viewer`.
This mirrors the RLS tiers in `0010_rls_policies.sql` exactly — `lib/permissions.ts`
should encode the same matrix so the UI hides actions it can't perform,
while RLS remains the actual enforcement layer.

| Capability | owner | admin | dispatcher | accountant | driver | viewer |
|---|:---:|:---:|:---:|:---:|:---:|:---:|
| View all org data | ✅ | ✅ | ✅ | ✅ | own dispatches only* | ✅ |
| Manage carriers/brokers/customers/drivers/trucks/trailers | ✅ | ✅ | ✅ | – | – | – |
| Create/edit loads & dispatches | ✅ | ✅ | ✅ | – | – | – |
| Upload/verify documents, manage compliance | ✅ | ✅ | ✅ | – | – | – |
| Create/edit invoices, payments, settlements | ✅ | ✅ | – | ✅ | – | – |
| Log expenses / fuel / maintenance | ✅ | ✅ | ✅ | ✅ | – | – |
| Delete records | ✅ | ✅ | – | financial only | – | – |
| Manage users & roles | ✅ | ✅ | – | – | – | – |
| Manage integrations & billing | ✅ | ✅ | – | – | – | – |
| Manage organization profile | ✅ | – | – | – | – | – |

\* `driver` role has no dedicated RLS carve-out to "own records only" in the
v1 schema (all policies key off `organization_id`, not `assigned driver`).
Ship v1 with `driver` effectively read-only at the org level via the app UI
gating; add a proper `driver_id = (select id from drivers where profile_id
= auth.uid())` policy in a later migration once drivers get real login
accounts (their own driver-app view of assigned loads).

## 5. MVP roadmap

**Week 1 — Foundation (done / this deliverable)**
- Supabase project, auth, and full schema (`0001`–`0011` migrations)
- RLS on every tenant table, seed data
- Next.js scaffold, Supabase client setup, auth pages (login/signup/invite)
- Org onboarding flow (create org -> assign owner) as a SECURITY DEFINER RPC

**Week 2 — Core fleet & operations**
- Carriers, Brokers, Customers, Drivers, Trucks, Trailers CRUD (list/detail/forms)
- Truck<->driver assignment UI (respecting `truck_driver_assignments` history)
- Loads CRUD with multi-stop editor
- Dispatch creation flow (load -> carrier/truck/driver/trailer), dispatch fee preview
- Dispatch board (kanban by `dispatch_status`)

**Week 3 — Money & compliance**
- Document upload (Supabase Storage) + document library, linked to any entity
- Compliance dashboard (expiring/expired), `refresh_compliance_statuses` cron wired via pg_cron
- Invoices (generate from dispatch, line items, PDF export), Payments recording
- Settlements (generate from dispatch, line items, approve/pay workflow)
- Expenses / Fuel / Maintenance logging screens

**Week 4 — Polish, reporting, billing**
- Reports: revenue, carrier performance, broker performance, aging receivables
- Tasks/Notes/Activity feed/Notifications wired across entity detail pages
- Subscription/Billing settings page (Stripe Checkout + customer portal), plan gating (max_users/max_trucks/max_active_loads)
- Settings: org profile, user management/invites, integrations (stubbed connectors)
- QA pass: RLS penetration test (try cross-tenant access with two seeded orgs), empty states, loading/error states, mobile responsiveness for dispatch board

## 6. Future integration notes

Each integration should be modeled as a row in `integration_settings`
(`provider` enum already includes all of these) with a corresponding
backend adapter — keep provider-specific logic behind a common interface
(`fetchLoads()`, `syncInvoice()`, etc.) so swapping/adding providers doesn't
touch core domain code.

- **DAT / Truckstop / 123Loadboard** — load board search + auto-import into `loads` (status `posted`); post-your-truck for empty capacity.
- **QuickBooks** — two-way sync of `invoices`/`payments` to QuickBooks Online invoices; carriers/brokers as vendors/customers.
- **Stripe** — platform subscription billing (`organization_subscriptions`, `billing_records`) via Checkout + webhooks; keep entirely separate from freight invoicing.
- **Twilio** — SMS check-calls to drivers, load-status alerts to dispatchers, appointment reminders.
- **SendGrid** — invoice delivery, compliance-expiry email digests, rate confirmations.
- **Motive / Samsara** — ELD/telematics: auto-populate `load_tracking_events` (GPS pings), `trucks.current_odometer`, HOS-based compliance checks.
- **RMIS / Highway / Carrier411** — carrier onboarding/monitoring: pull authority status, insurance verification, and fraud/risk scores into `carriers` and `compliance_items` automatically.

Store only opaque secret references in `integration_settings.credentials`
(Supabase Vault-backed) — never raw API keys in the row itself.
