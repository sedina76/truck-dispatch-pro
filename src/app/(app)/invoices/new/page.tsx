import Link from "next/link";
import { AlertTriangle } from "lucide-react";
import { createClient } from "@/lib/supabase/server";
import { FormCard } from "@/components/ui/form-card";
import { FormField, FormGrid, FormSelect, FormTextarea } from "@/components/ui/form-field";
import { DesktopPanel, DesktopPanelHeader, DesktopPanelBody } from "@/components/desktop/panel";
import { LoadPicker, type InvoiceLoadCandidate } from "@/components/invoices/load-picker";
import { INVOICEABLE_LOAD_STATUSES, resolveBillingPartyDisplay, suggestedDueDate } from "@/lib/billing/party";
import { getCurrentOrgId } from "@/lib/actions/records";
import { createInvoice } from "../actions";

// Shape of one candidateLoads row per the enriched select() above --
// broker_id/customer_id determine which embed (if either) is populated,
// exactly like getBillingParty()'s own broker-wins-over-customer rule
// (src/lib/billing/party.ts), and load_stops carries every stop so the
// delivery one can be picked out here rather than trusting stop order.
type CandidateLoadRow = {
  id: string;
  load_number: string;
  broker_id: string | null;
  customer_id: string | null;
  brokers: { company_name: string } | null;
  customers: { company_name: string } | null;
  load_stops: { stop_type: "pickup" | "delivery"; stop_sequence: number; arrived_at: string | null; scheduled_at: string | null }[] | null;
};

// Display-only resolution for the load picker (Section C/J): picks the
// LAST delivery stop (multi-stop loads may have more than one; the final
// one is the one that actually matters for "when was this delivered"),
// preferring its real arrived_at over its scheduled_at -- a load already
// in an invoiceable status (delivered/pod_received/invoiced/closed) should
// normally have arrived_at set, but scheduled_at is a safe fallback for an
// edge case where a load was moved straight to a terminal status without
// ever logging an arrival.
function resolveLoadCandidate(row: CandidateLoadRow, rate: number): InvoiceLoadCandidate {
  const deliveryStops = (row.load_stops ?? []).filter((s) => s.stop_type === "delivery").sort((a, b) => b.stop_sequence - a.stop_sequence);
  const lastDelivery = deliveryStops[0];
  const deliveredAt = lastDelivery ? (lastDelivery.arrived_at ?? lastDelivery.scheduled_at)?.slice(0, 10) ?? null : null;
  const partyName = row.broker_id ? (row.brokers?.company_name ?? null) : row.customer_id ? (row.customers?.company_name ?? null) : null;
  return { id: row.id, load_number: row.load_number, rate, partyName, deliveredAt };
}

export default async function NewInvoicePage({
  searchParams,
}: {
  searchParams: Promise<{ load_id?: string }>;
}) {
  const { load_id } = await searchParams;
  const supabase = await createClient();

  // "Select Load first" (spec section 3) needs a pool of loads that could
  // plausibly still want a manual invoice -- delivered-or-later loads that
  // don't already have one. Loads earlier in their lifecycle are still
  // findable via manual entry (no load selected) for an edge case like
  // pre-billing, but aren't offered here to keep the list relevant.
  const organizationId = await getCurrentOrgId();

  // Phase 2G.12: `rate` dropped from the candidateLoads select --
  // load_financials is authoritative now (0068 writer cutover). This
  // whole route is already layout-guarded to FINANCIAL_ROLES (see
  // invoices/layout.tsx), so no additional role gating is needed.
  // Invoice eligibility repair (Section C): candidateLoads already excluded
  // ineligible/already-invoiced/foreign-org loads (RLS + the .in()/.is()
  // filters below) before this repair -- what was missing was enough
  // context in the rendered option to make that filtering visible/trusted
  // (see LoadPicker's own header comment). broker_id/customer_id and their
  // company names, plus each load's delivery stop, are now selected so the
  // picker can show "Load # -- Broker/Customer -- Amount -- Delivered
  // <date>" instead of just "Load # -- Amount".
  const [{ data: candidateLoads }, { data: brokers }, { data: customers }, { data: suggestedNumberData }] = await Promise.all([
    supabase
      .from("loads")
      .select(
        "id, load_number, broker_id, customer_id, " +
          "brokers(company_name), customers(company_name), " +
          "load_stops(stop_type, stop_sequence, arrived_at, scheduled_at), " +
          "invoices!left(id)"
      )
      .in("status", INVOICEABLE_LOAD_STATUSES)
      .is("invoices.id", null)
      .order("created_at", { ascending: false })
      .limit(100),
    supabase.from("brokers").select("id, company_name").order("company_name"),
    supabase.from("customers").select("id, company_name").order("company_name"),
    // Atomic, year-scoped, per-organization counter (0065_billing_readiness.sql)
    // -- replaces the old `count(*) + 1` suggestion, which raced under
    // concurrent invoice creation and could hand two dispatchers the same
    // number. Like the existing payment_number_seq (0026), a value is
    // consumed here purely by visiting this page even if the invoice is
    // never saved (e.g. the user navigates away) -- an accepted,
    // precedented trade-off for numbering that can never collide; the
    // field below remains a plain editable text input either way.
    supabase.rpc("generate_invoice_number", { p_organization_id: organizationId }),
  ]);

  const suggestedNumber = suggestedNumberData ?? "";

  // Supabase's select-string type inference can't fully resolve this many
  // combined embeds (two singular relations plus a one-to-many) -- cast
  // once, immediately, to the shape this route actually reads, same as
  // this file's own `loadRow` cast further down for its single-load query.
  const candidateLoadRows = (candidateLoads ?? []) as unknown as CandidateLoadRow[];

  // No load selected: existing fully-manual workflow, unchanged, just with
  // the load picker added above it (spec 3's "If no load is selected,
  // allow the existing manual billing-party workflow").
  if (!load_id) {
    const candidateLoadIds = candidateLoadRows.map((l) => l.id);
    const { data: candidateLoadFinancials } = candidateLoadIds.length > 0
      ? await supabase.from("load_financials").select("load_id, rate").in("load_id", candidateLoadIds)
      : { data: [] as { load_id: string; rate: number }[] };
    const rateByLoadId = new Map((candidateLoadFinancials ?? []).map((r) => [r.load_id, Number(r.rate)]));

    const pickerLoads: InvoiceLoadCandidate[] = candidateLoadRows.map((l) => resolveLoadCandidate(l, rateByLoadId.get(l.id) ?? 0));

    return (
      <div className="space-y-3">
        <DesktopPanel>
          <DesktopPanelBody>
            <LoadPicker loads={pickerLoads} />
          </DesktopPanelBody>
        </DesktopPanel>

        <FormCard
          title="New Invoice"
          description="Create an invoice, then add line items from its detail page."
          action={createInvoice}
          cancelHref="/invoices"
          submitLabel="Create Invoice"
        >
          <FormGrid>
            <FormField label="Invoice number" name="invoice_number" required defaultValue={suggestedNumber} />
            <FormSelect
              label="Status"
              name="status"
              defaultValue="draft"
              options={[
                { value: "draft", label: "Draft" },
                { value: "sent", label: "Sent" },
                { value: "viewed", label: "Viewed" },
              ]}
            />
            <FormSelect
              label="Broker (if brokered)"
              name="broker_id"
              options={(brokers ?? []).map((b) => ({ value: b.id, label: b.company_name }))}
            />
            <FormSelect
              label="Customer (if direct)"
              name="customer_id"
              options={(customers ?? []).map((c) => ({ value: c.id, label: c.company_name }))}
            />
            <FormField label="Bill to name" name="bill_to_name" required />
            <FormField label="Bill to email" name="bill_to_email" type="email" />
            <FormField label="Due date" name="due_date" type="date" />
            <FormTextarea label="Notes" name="notes" />
          </FormGrid>
        </FormCard>
      </div>
    );
  }

  // A load WAS selected -- resolve everything server-side.
  // Phase 2G.12: `rate` dropped from the loads select, and the nested
  // brokers()/customers() embeds no longer carry payment_terms_days --
  // load_financials/broker_financials/customer_financials are
  // authoritative now (0068/2G.10/2G.12 writer cutovers). This is the
  // SAME rule auto_generate_invoice_from_delivered_load() (0068) already
  // enforces at automatic-invoice time -- this manual path was the one
  // remaining place still reading the old columns for it.
  const [{ data: load }, { data: org }] = await Promise.all([
    supabase
      .from("loads")
      .select(
        "id, load_number, organization_id, broker_id, customer_id, " +
          "brokers(company_name, email, address_line1, city, state, postal_code), " +
          "customers(company_name, email, billing_address_line1, city, state, postal_code)"
      )
      .eq("id", load_id)
      .single(),
    supabase.from("organizations").select("default_payment_terms_days").single(),
  ]);

  if (!load) {
    return (
      <DesktopPanel>
        <DesktopPanelBody>
          <p className="text-sm text-muted-foreground">
            That load could not be found. <Link href="/invoices/new" className="text-primary hover:underline">Start over</Link>.
          </p>
        </DesktopPanelBody>
      </DesktopPanel>
    );
  }

  // Duplicate protection (spec section 3): the DB already guarantees this
  // via the partial unique index on invoices.load_id
  // (0022_auto_invoice_on_delivery.sql) -- this is the friendly UI-side
  // check so the user sees "already exists" instead of a raw 409.
  const { data: existingInvoice } = await supabase
    .from("invoices")
    .select("id, invoice_number")
    .eq("load_id", load_id)
    .maybeSingle();

  if (existingInvoice) {
    return (
      <DesktopPanel>
        <DesktopPanelHeader title="Invoice Already Exists" />
        <DesktopPanelBody className="space-y-3">
          <p className="flex items-start gap-2 text-sm text-desktop-text">
            <AlertTriangle className="mt-0.5 size-4 shrink-0 text-warning" />
            Invoice already exists for this load: <span className="font-semibold">{existingInvoice.invoice_number}</span>
          </p>
          <div className="flex gap-2">
            <Link
              href={`/invoices/${existingInvoice.id}`}
              className="inline-flex h-8 items-center rounded-sm bg-primary px-3 text-[13px] font-medium text-primary-foreground hover:bg-primary-hover"
            >
              View Invoice
            </Link>
            <Link
              href="/invoices/new"
              className="inline-flex h-8 items-center rounded-sm border border-desktop-border px-3 text-[13px] font-medium hover:bg-muted"
            >
              Choose a different load
            </Link>
          </div>
        </DesktopPanelBody>
      </DesktopPanel>
    );
  }

  const loadRow = load as unknown as {
    id: string;
    load_number: string;
    broker_id: string | null;
    customer_id: string | null;
    brokers: { company_name: string; email: string | null; address_line1: string | null; city: string | null; state: string | null; postal_code: string | null } | null;
    customers: { company_name: string; email: string | null; billing_address_line1: string | null; city: string | null; state: string | null; postal_code: string | null } | null;
  };

  const [{ data: loadFinancialsRow }, { data: brokerFinancialsRow }, { data: customerFinancialsRow }] = await Promise.all([
    supabase.from("load_financials").select("rate").eq("load_id", loadRow.id).maybeSingle(),
    loadRow.broker_id
      ? supabase.from("broker_financials").select("payment_terms_days").eq("broker_id", loadRow.broker_id).maybeSingle()
      : Promise.resolve({ data: null }),
    loadRow.customer_id
      ? supabase.from("customer_financials").select("payment_terms_days").eq("customer_id", loadRow.customer_id).maybeSingle()
      : Promise.resolve({ data: null }),
  ]);
  const loadRate = Number(loadFinancialsRow?.rate ?? 0);
  const brokerWithTerms = loadRow.brokers ? { ...loadRow.brokers, payment_terms_days: brokerFinancialsRow?.payment_terms_days ?? null } : null;
  const customerWithTerms = loadRow.customers ? { ...loadRow.customers, payment_terms_days: customerFinancialsRow?.payment_terms_days ?? null } : null;

  const display = resolveBillingPartyDisplay(loadRow, brokerWithTerms, customerWithTerms);
  const issueDate = new Date().toISOString().slice(0, 10);
  const dueDate = suggestedDueDate(issueDate, display.paymentTermsDays, org?.default_payment_terms_days ?? null);

  return (
    <div className="space-y-3">
      <DesktopPanel>
        {/* Compact summary card + Change button (Section 10): this panel
            IS that summary once a load is selected -- rendered instead of
            the picker, not alongside it, since selecting a load navigates
            to this same route with ?load_id set, replacing the "no load"
            branch's UI entirely. */}
        <DesktopPanelHeader
          title={`Load ${loadRow.load_number}`}
          actions={
            <Link
              href="/invoices/new"
              className="rounded border border-desktop-header-text/30 px-2 py-0.5 text-[11px] text-desktop-header-text/90 hover:bg-desktop-header-text/10"
            >
              Change
            </Link>
          }
        />
        <DesktopPanelBody>
          {display.party.type === "none" ? (
            <p className="flex items-start gap-2 text-sm text-warning">
              <AlertTriangle className="mt-0.5 size-4 shrink-0" />
              This load has no broker or customer on file -- select one below before saving. Nothing is guessed automatically.
            </p>
          ) : (
            <div className="grid grid-cols-2 gap-x-4 gap-y-1 text-[13px] sm:grid-cols-4">
              <Field label="Bill To" value={`${display.billToName} (${display.party.type === "broker" ? "Broker" : "Customer"})`} />
              <Field label="Rate" value={`$${loadRate.toLocaleString()}`} />
              <Field label="Terms" value={display.paymentTermsDays != null ? `Net ${display.paymentTermsDays}` : `Net ${org?.default_payment_terms_days ?? 30} (org default)`} />
              <Field label="Due Date" value={new Date(dueDate + "T00:00:00").toLocaleDateString()} />
            </div>
          )}
        </DesktopPanelBody>
      </DesktopPanel>

      <FormCard
        title="New Invoice"
        description="Prefilled from the selected load -- review before saving."
        action={createInvoice}
        cancelHref="/invoices"
        submitLabel="Create Invoice"
      >
        <FormGrid>
          <input type="hidden" name="load_id" value={loadRow.id} />
          <input type="hidden" name="bill_to_address" value={display.billToAddress ?? ""} />
          <FormField label="Invoice number" name="invoice_number" required defaultValue={suggestedNumber} />
          <FormSelect
            label="Status"
            name="status"
            defaultValue="draft"
            options={[
              { value: "draft", label: "Draft" },
              { value: "sent", label: "Sent" },
              { value: "viewed", label: "Viewed" },
            ]}
          />
          {/* Party-integrity repair (follow-up audit): no editable Broker/
              Customer selects here anymore -- broker_id/customer_id are the
              load's own authoritative fields (public.loads.broker_id/
              customer_id, the exact ones auto_generate_invoice_from_
              delivered_load() (0022/0028) copies onto an automatic
              invoice); createInvoice() now derives them from the load
              server-side and ignores whatever a form submits, so an
              editable dropdown here would have silently done nothing while
              looking like it worked. The resolved party is already shown
              above in the "Bill To" summary panel -- this is not a second,
              separate confirmation, it IS the value that will be saved. */}
          <FormField label="Bill to name" name="bill_to_name" required defaultValue={display.billToName} />
          <FormField label="Bill to email" name="bill_to_email" type="email" defaultValue={display.billToEmail ?? undefined} />
          <FormField label="Due date" name="due_date" type="date" defaultValue={dueDate} />
          {/* Financial data source repair (Section F): this used to be a
              plain editable input whose submitted value became the
              invoice's starting line-item rate verbatim -- createInvoice()
              now always re-derives the rate from load_financials server-
              side when a load is selected, so this is disabled (a disabled
              input never appears in FormData at all) rather than left
              editable-but-ignored, which would silently mislead whoever
              edits it. The rate can still be adjusted afterward from the
              invoice detail page's own line-item editor, unchanged. */}
          <FormField label="Rate ($) -- from load, add line items after to adjust" name="rate" type="number" step="0.01" defaultValue={loadRate} disabled />
          <FormTextarea label="Notes" name="notes" />
        </FormGrid>
      </FormCard>
    </div>
  );
}

function Field({ label, value }: { label: string; value: string }) {
  return (
    <div>
      <p className="text-[10.5px] font-medium uppercase tracking-wide text-muted-foreground">{label}</p>
      <p className="font-medium text-desktop-text">{value}</p>
    </div>
  );
}
