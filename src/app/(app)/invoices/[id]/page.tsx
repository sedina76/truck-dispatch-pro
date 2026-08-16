import Link from "next/link";
import { notFound } from "next/navigation";
import { FileText, CheckCircle2, AlertTriangle } from "lucide-react";
import { createClient } from "@/lib/supabase/server";
import { deleteRecord } from "@/lib/actions/records";
import { FormCard } from "@/components/ui/form-card";
import { FormField, FormGrid, FormSelect, FormTextarea } from "@/components/ui/form-field";
import { Button } from "@/components/ui/button";
import { DocumentLinkButton } from "@/components/drivers/document-link-button";
import { computePodStatus } from "@/lib/documents/pod-status";
import { getLatestDocument } from "@/lib/documents/latest-document";
import { getPodSignedUrl } from "../../loads/pod-actions";
import { updateInvoice, addInvoiceLineItem } from "../actions";
import { deductAdvancesIntoInvoice } from "../../advances/actions";
import { BillingPacketSection } from "@/components/invoices/billing-packet-section";
import { isPacketOutdated } from "../billing-packet-actions";
import { PaymentHistorySection, type PaymentHistoryRow } from "@/components/invoices/payment-history-section";
import { invoiceEffectiveStatus } from "@/lib/invoices/effective-status";
import { CollectionsSection } from "@/components/collections/collections-section";
import { DesktopWorkspaceTabs } from "@/components/desktop/workspace-tabs";
import { RegisterDesktopActions } from "@/components/desktop/actions-context";

export default async function InvoiceDetailPage({
  params,
}: {
  params: Promise<{ id: string }>;
}) {
  const { id } = await params;
  const supabase = await createClient();

  const [{ data: invoice }, { data: brokers }, { data: customers }, { data: lineItems }, { data: payments }] =
    await Promise.all([
      supabase.from("invoices").select("*").eq("id", id).single(),
      supabase.from("brokers").select("id, company_name").order("company_name"),
      supabase.from("customers").select("id, company_name").order("company_name"),
      supabase.from("invoice_line_items").select("*").eq("invoice_id", id).order("sort_order"),
      supabase
        .from("payments")
        .select("id, payment_number, received_at, method, reference_number, amount, status, recorded_by, notes")
        .eq("invoice_id", id)
        .order("received_at", { ascending: false }),
    ]);
  if (!invoice) notFound();

  const recorderIds = [...new Set((payments ?? []).map((p) => p.recorded_by).filter((v): v is string => !!v))];
  const { data: recorders } = recorderIds.length
    ? await supabase.from("profiles").select("id, full_name").in("id", recorderIds)
    : { data: [] as { id: string; full_name: string }[] };
  const recorderNameById = new Map((recorders ?? []).map((p) => [p.id, p.full_name]));
  const effectiveStatus = invoiceEffectiveStatus(invoice.status, invoice.due_date, Number(invoice.balance_due));
  const paymentRows: PaymentHistoryRow[] = (payments ?? []).map((p) => ({
    id: p.id,
    payment_number: p.payment_number,
    received_at: p.received_at,
    method: p.method,
    reference_number: p.reference_number,
    amount: Number(p.amount),
    status: p.status,
    recorded_by_name: p.recorded_by ? (recorderNameById.get(p.recorded_by) ?? null) : null,
    notes: p.notes,
  }));

  // Billing documents readiness: mirrors the DB-level gate in
  // check_invoice_ready_to_send() (0023_pod_workflow.sql) exactly, so this
  // never shows "ready" when the trigger would actually block sending.
  // Rate Confirmation/BOL/accessorials are informational checklist items
  // only -- not hard-blocking, since (unlike POD) there's no reliable
  // signal for when one is actually required for a given load.
  let pod = null as Awaited<ReturnType<typeof getLatestDocument>>;
  let rateConDoc = null as Awaited<ReturnType<typeof getLatestDocument>>;
  let bolDoc = null as Awaited<ReturnType<typeof getLatestDocument>>;
  if (invoice.load_id) {
    [pod, rateConDoc, bolDoc] = await Promise.all([
      getLatestDocument(supabase, "load", invoice.load_id, "pod"),
      getLatestDocument(supabase, "load", invoice.load_id, "rate_confirmation"),
      getLatestDocument(supabase, "load", invoice.load_id, "bol"),
    ]);
  }
  const podStatus = computePodStatus(pod);
  const readyToSend = podStatus === "verified";
  const rateConReady = rateConDoc !== null;

  const { data: packets } = await supabase
    .from("billing_packets")
    .select("*")
    .eq("invoice_id", id)
    .order("version", { ascending: false });
  const latestPacket = packets?.[0] ?? null;
  const packetOutdated = latestPacket ? await isPacketOutdated(invoice.load_id, latestPacket.document_snapshot) : false;

  let pendingCount = 0;
  let pendingTotal = 0;
  if (invoice.dispatch_id) {
    const { data: dispatch } = await supabase
      .from("dispatches")
      .select("carrier_id")
      .eq("id", invoice.dispatch_id)
      .single();
    if (dispatch?.carrier_id) {
      const { data: pending } = await supabase
        .from("dispatch_advances")
        .select("amount")
        .eq("carrier_id", dispatch.carrier_id)
        .eq("status", "pending");
      pendingCount = pending?.length ?? 0;
      pendingTotal = (pending ?? []).reduce((sum, a) => sum + Number(a.amount), 0);
    }
  }

  return (
    <div className="space-y-3">
      <DesktopWorkspaceTabs tabs={[{ label: "Invoices", href: "/invoices" }, { label: invoice.invoice_number, href: `/invoices/${id}` }]} />
      <RegisterDesktopActions
        title={`Invoice ${invoice.invoice_number}`}
        printHref={`/invoices/${id}/pdf`}
        exportOptions={[{ label: "Export PDF", href: `/invoices/${id}/pdf` }]}
        email={{ entityType: "invoice", entityId: id }}
      />
      <div className="flex justify-end">
        <Link
          href={`/invoices/${id}/pdf`}
          target="_blank"
          className="inline-flex items-center gap-1.5 rounded-lg border border-border bg-card px-3 py-1.5 text-sm font-medium transition-colors hover:bg-muted"
        >
          <FileText className="size-4" />
          Download PDF
        </Link>
      </div>

      <FormCard
        title={invoice.invoice_number}
        description="Invoice details. Changes save immediately."
        action={updateInvoice.bind(null, id)}
        cancelHref="/invoices"
        deleteAction={deleteRecord.bind(null, "invoices", id, "/invoices")}
      >
        <FormGrid>
          <FormField label="Invoice number" name="invoice_number" defaultValue={invoice.invoice_number} required />
          {["partially_paid", "paid", "overdue"].includes(effectiveStatus) ? (
            <div className="space-y-1.5">
              <label className="text-sm font-medium text-foreground">Status</label>
              {/* Payment-derived/overdue states aren't manually editable --
                  see guard_invoice_status() (0026_accounts_receivable.sql),
                  which rejects a manual status write that contradicts
                  amount_paid vs. total_amount at the DB level too. "Overdue"
                  is never actually stored (see invoiceEffectiveStatus) --
                  the hidden input preserves the REAL underlying stored
                  status (e.g. "sent") since this field is otherwise
                  omitted from the form. */}
              <input type="hidden" name="status" value={invoice.status} />
              <div className="flex h-10 items-center rounded-lg border border-border bg-muted px-3.5 text-sm capitalize text-muted-foreground">
                {effectiveStatus.replace(/_/g, " ")}
              </div>
              <p className="text-xs text-muted-foreground">
                Set automatically from recorded payments{effectiveStatus === "overdue" ? " and the due date" : ""} -- not
                manually editable.
              </p>
            </div>
          ) : (
            <FormSelect
              label="Status"
              name="status"
              defaultValue={invoice.status}
              options={[
                { value: "draft", label: "Draft" },
                { value: "sent", label: "Sent" },
                { value: "viewed", label: "Viewed" },
                { value: "void", label: "Void" },
                { value: "disputed", label: "Disputed" },
              ]}
            />
          )}
          <FormSelect
            label="Broker"
            name="broker_id"
            defaultValue={invoice.broker_id}
            options={(brokers ?? []).map((b) => ({ value: b.id, label: b.company_name }))}
          />
          <FormSelect
            label="Customer"
            name="customer_id"
            defaultValue={invoice.customer_id}
            options={(customers ?? []).map((c) => ({ value: c.id, label: c.company_name }))}
          />
          <FormField label="Bill to name" name="bill_to_name" defaultValue={invoice.bill_to_name} required />
          <FormField label="Bill to email" name="bill_to_email" type="email" defaultValue={invoice.bill_to_email} />
          <FormField label="Due date" name="due_date" type="date" defaultValue={invoice.due_date} />
          <FormTextarea label="Notes" name="notes" defaultValue={invoice.notes} />
        </FormGrid>
      </FormCard>

      <div className="grid grid-cols-1 gap-4 md:grid-cols-3">
        <SummaryTile label="Subtotal" value={invoice.subtotal_amount} />
        <SummaryTile label="Total" value={invoice.total_amount} />
        <SummaryTile label="Balance Due" value={invoice.balance_due} highlight />
      </div>

      <div className="rounded-xl border border-border bg-card p-4 shadow-elevation-1">
        <p className="text-sm font-medium">Payment Terms</p>
        <div className="mt-2 grid grid-cols-2 gap-x-4 gap-y-2 text-sm sm:grid-cols-4">
          <div>
            <p className="text-xs text-muted-foreground">Invoice Date</p>
            <p className="font-medium">{new Date(invoice.issue_date + "T00:00:00").toLocaleDateString()}</p>
          </div>
          <div>
            <p className="text-xs text-muted-foreground">Terms</p>
            {/* Derived display only, from the two dates frozen on this
                invoice at generation time -- never a live lookup of the
                broker/customer's current terms, so a later terms change
                can never silently alter an already-issued invoice (see
                0028_auto_invoice_dispatch_sync_fix.sql). */}
            <p className="font-medium">
              {invoice.due_date
                ? `Net ${Math.round((new Date(invoice.due_date).getTime() - new Date(invoice.issue_date).getTime()) / 86400000)}`
                : "--"}
            </p>
          </div>
          <div>
            <p className="text-xs text-muted-foreground">Payment Due Date</p>
            <p className="font-medium">{invoice.due_date ? new Date(invoice.due_date + "T00:00:00").toLocaleDateString() : "--"}</p>
          </div>
          <div>
            <p className="text-xs text-muted-foreground">Days Until Due / Past Due</p>
            <p className={"font-medium " + (effectiveStatus === "overdue" ? "text-danger" : "")}>
              {invoice.due_date
                ? (() => {
                    const days = Math.round((new Date(invoice.due_date + "T00:00:00").getTime() - startOfToday().getTime()) / 86400000);
                    return days < 0 ? `${Math.abs(days)}d past due` : days === 0 ? "Due today" : `${days}d until due`;
                  })()
                : "--"}
            </p>
          </div>
        </div>
      </div>

      {invoice.load_id && (
        <div className="rounded-xl border border-border bg-card p-4 shadow-elevation-1">
          <div className="flex items-center justify-between">
            <p className="text-sm font-medium">Billing Documents</p>
            <span
              className={`inline-flex items-center gap-1.5 rounded-full px-2.5 py-1 text-xs font-medium ${
                readyToSend ? "bg-success/10 text-success" : "bg-danger/10 text-danger"
              }`}
            >
              {readyToSend ? <CheckCircle2 className="size-3.5" /> : <AlertTriangle className="size-3.5" />}
              {readyToSend ? "Ready to Send" : "Not Ready to Send"}
            </span>
          </div>

          <div className="mt-3 space-y-2 text-sm">
            <div className="flex items-center justify-between">
              <span className="flex items-center gap-1.5">
                {podStatus === "verified" ? (
                  <CheckCircle2 className="size-4 text-success" />
                ) : (
                  <AlertTriangle className="size-4 text-warning" />
                )}
                POD {podStatus === "verified" ? "Verified" : podStatus === "missing" ? "Missing" : podStatus === "rejected" ? "Rejected" : "Uploaded (not yet verified)"}
              </span>
              {pod ? (
                <DocumentLinkButton label="View POD" getUrl={getPodSignedUrl.bind(null, pod.file_path, false)} />
              ) : (
                <Link href={`/loads/${invoice.load_id}`} className="text-xs font-medium text-primary hover:underline">
                  Upload on load page &rarr;
                </Link>
              )}
            </div>

            <div className="flex items-center justify-between">
              <span className="flex items-center gap-1.5">
                {rateConReady ? (
                  <CheckCircle2 className="size-4 text-success" />
                ) : (
                  <AlertTriangle className="size-4 text-warning" />
                )}
                Rate Confirmation {rateConReady ? "On File" : "Missing"}
              </span>
              {!rateConReady && (
                <Link href={`/loads/${invoice.load_id}`} className="text-xs font-medium text-primary hover:underline">
                  Add on load page &rarr;
                </Link>
              )}
            </div>
          </div>

          {!readyToSend && (
            <p className="mt-3 text-xs text-muted-foreground">
              Cannot send invoice: Proof of Delivery is required and must be verified before this invoice can move
              from Draft to Sent. (Rate Confirmation is shown for reference and does not block sending.)
            </p>
          )}
        </div>
      )}

      <BillingPacketSection
        invoiceId={id}
        readyToSend={readyToSend}
        podStatus={podStatus}
        rateConReady={rateConReady}
        bolReady={bolDoc !== null}
        packet={latestPacket}
        packetOutdated={packetOutdated}
        defaultRecipientEmail={invoice.bill_to_email}
        invoiceStatus={invoice.status}
      />

      {pendingCount > 0 && (
        <div className="flex items-center justify-between rounded-xl border border-warning/30 bg-warning/5 px-4 py-3">
          <p className="text-sm">
            The carrier on this dispatch has <span className="font-semibold">{pendingCount}</span> pending advance
            {pendingCount === 1 ? "" : "s"} totaling <span className="font-semibold">${pendingTotal.toLocaleString()}</span>.
            Deducting here reduces this invoice rather than their settlement -- use only if you bill this carrier directly.
          </p>
          <form action={deductAdvancesIntoInvoice.bind(null, id)}>
            <Button type="submit" size="sm" variant="outline" className="shrink-0">
              Deduct Pending Advances
            </Button>
          </form>
        </div>
      )}

      <div className="rounded-xl border border-border bg-card p-4 shadow-elevation-1">
        <p className="text-sm font-medium">Line items</p>
        {!lineItems || lineItems.length === 0 ? (
          <p className="mt-2 text-sm text-muted-foreground">No line items yet.</p>
        ) : (
          <table className="mt-3 w-full text-sm">
            <tbody>
              {lineItems.map((li) => (
                <tr key={li.id} className="border-b border-border last:border-0">
                  <td className="py-2">{li.description}</td>
                  <td className="py-2 text-right">{Number(li.quantity)}</td>
                  <td className="py-2 text-right">${Number(li.unit_price).toLocaleString()}</td>
                  <td className="py-2 text-right font-medium">${Number(li.line_total).toLocaleString()}</td>
                </tr>
              ))}
            </tbody>
          </table>
        )}

        <form action={addInvoiceLineItem.bind(null, id)} className="mt-4 flex flex-wrap items-end gap-2 border-t border-border pt-4">
          <div className="flex-1 space-y-1">
            <label className="text-xs font-medium">Description</label>
            <input name="description" required className="w-full rounded-lg border border-border bg-card px-2.5 py-1.5 text-sm shadow-elevation-1 outline-none focus-visible:border-primary focus-visible:ring-2 focus-visible:ring-primary/20" />
          </div>
          <div className="w-20 space-y-1">
            <label className="text-xs font-medium">Qty</label>
            <input name="quantity" type="number" step="0.01" defaultValue={1} className="w-full rounded-lg border border-border bg-card px-2.5 py-1.5 text-sm shadow-elevation-1 outline-none focus-visible:border-primary focus-visible:ring-2 focus-visible:ring-primary/20" />
          </div>
          <div className="w-32 space-y-1">
            <label className="text-xs font-medium">Unit price</label>
            <input name="unit_price" type="number" step="0.01" required className="w-full rounded-lg border border-border bg-card px-2.5 py-1.5 text-sm shadow-elevation-1 outline-none focus-visible:border-primary focus-visible:ring-2 focus-visible:ring-primary/20" />
          </div>
          <Button type="submit" size="sm">Add Line</Button>
        </form>
      </div>

      <PaymentHistorySection
        invoiceId={id}
        invoiceTotal={Number(invoice.total_amount)}
        totalPaid={Number(invoice.amount_paid)}
        balanceDue={Number(invoice.balance_due)}
        payments={paymentRows}
      />

      <CollectionsSection invoiceId={id} />
    </div>
  );
}

function SummaryTile({ label, value, highlight }: { label: string; value: number; highlight?: boolean }) {
  return (
    <div className="rounded-md border border-desktop-border bg-card px-3 py-2 shadow-elevation-1">
      <p className="text-[10.5px] font-semibold uppercase tracking-wide text-muted-foreground">{label}</p>
      <p className={"mt-1 text-lg font-semibold tabular-nums " + (highlight ? "text-primary" : "")}>
        ${Number(value).toLocaleString()}
      </p>
    </div>
  );
}

function startOfToday() {
  const d = new Date();
  d.setHours(0, 0, 0, 0);
  return d;
}
