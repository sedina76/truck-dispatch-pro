import Link from "next/link";
import { AlertTriangle } from "lucide-react";
import { createClient } from "@/lib/supabase/server";
import { FormCard } from "@/components/ui/form-card";
import { FormField, FormGrid, FormSelect, FormTextarea } from "@/components/ui/form-field";
import { DesktopPanel, DesktopPanelHeader, DesktopPanelBody } from "@/components/desktop/panel";
import { LoadPicker } from "@/components/invoices/load-picker";
import { resolveBillingPartyDisplay, suggestedDueDate } from "@/lib/billing/party";
import { createInvoice } from "../actions";

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
  const [{ data: candidateLoads }, { data: brokers }, { data: customers }, { count }] = await Promise.all([
    supabase
      .from("loads")
      .select("id, load_number, rate, invoices!left(id)")
      .in("status", ["delivered", "pod_received", "invoiced", "closed"])
      .is("invoices.id", null)
      .order("created_at", { ascending: false })
      .limit(100),
    supabase.from("brokers").select("id, company_name").order("company_name"),
    supabase.from("customers").select("id, company_name").order("company_name"),
    supabase.from("invoices").select("id", { count: "exact", head: true }),
  ]);

  const suggestedNumber = `INV-${String((count ?? 0) + 1).padStart(6, "0")}`;

  // No load selected: existing fully-manual workflow, unchanged, just with
  // the load picker added above it (spec 3's "If no load is selected,
  // allow the existing manual billing-party workflow").
  if (!load_id) {
    return (
      <div className="space-y-3">
        <DesktopPanel>
          <DesktopPanelBody>
            <LoadPicker loads={(candidateLoads ?? []).map((l) => ({ id: l.id, load_number: l.load_number, rate: Number(l.rate) }))} />
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
  const [{ data: load }, { data: org }] = await Promise.all([
    supabase
      .from("loads")
      .select(
        "id, load_number, rate, organization_id, broker_id, customer_id, " +
          "brokers(company_name, email, address_line1, city, state, postal_code, payment_terms_days), " +
          "customers(company_name, email, billing_address_line1, city, state, postal_code, payment_terms_days)"
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
    rate: number;
    broker_id: string | null;
    customer_id: string | null;
    brokers: { company_name: string; email: string | null; address_line1: string | null; city: string | null; state: string | null; postal_code: string | null; payment_terms_days: number | null } | null;
    customers: { company_name: string; email: string | null; billing_address_line1: string | null; city: string | null; state: string | null; postal_code: string | null; payment_terms_days: number | null } | null;
  };

  const display = resolveBillingPartyDisplay(loadRow, loadRow.brokers, loadRow.customers);
  const issueDate = new Date().toISOString().slice(0, 10);
  const dueDate = suggestedDueDate(issueDate, display.paymentTermsDays, org?.default_payment_terms_days ?? null);

  return (
    <div className="space-y-3">
      <DesktopPanel>
        <DesktopPanelHeader title={`Load ${loadRow.load_number}`} actions={<Link href="/invoices/new" className="text-[11px] text-desktop-header-text/80 hover:underline">Change load</Link>} />
        <DesktopPanelBody>
          {display.party.type === "none" ? (
            <p className="flex items-start gap-2 text-sm text-warning">
              <AlertTriangle className="mt-0.5 size-4 shrink-0" />
              This load has no broker or customer on file -- select one below before saving. Nothing is guessed automatically.
            </p>
          ) : (
            <div className="grid grid-cols-2 gap-x-4 gap-y-1 text-[13px] sm:grid-cols-4">
              <Field label="Bill To" value={`${display.billToName} (${display.party.type === "broker" ? "Broker" : "Customer"})`} />
              <Field label="Rate" value={`$${Number(loadRow.rate).toLocaleString()}`} />
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
          <FormSelect
            label="Broker (if brokered)"
            name="broker_id"
            defaultValue={display.party.type === "broker" ? display.party.id : undefined}
            options={(brokers ?? []).map((b) => ({ value: b.id, label: b.company_name }))}
          />
          <FormSelect
            label="Customer (if direct)"
            name="customer_id"
            defaultValue={display.party.type === "customer" ? display.party.id : undefined}
            options={(customers ?? []).map((c) => ({ value: c.id, label: c.company_name }))}
          />
          <FormField label="Bill to name" name="bill_to_name" required defaultValue={display.billToName} />
          <FormField label="Bill to email" name="bill_to_email" type="email" defaultValue={display.billToEmail ?? undefined} />
          <FormField label="Due date" name="due_date" type="date" defaultValue={dueDate} />
          <FormField label="Rate ($)" name="rate" type="number" step="0.01" defaultValue={Number(loadRow.rate)} />
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
