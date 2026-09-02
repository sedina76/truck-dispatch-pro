import Link from "next/link";
import { notFound } from "next/navigation";
import { FileText, CheckCircle2, AlertTriangle } from "lucide-react";
import { createClient } from "@/lib/supabase/server";
import { deleteRecord, getCurrentOrgId } from "@/lib/actions/records";
import { FormCard } from "@/components/ui/form-card";
import { FormField, FormGrid, FormSelect, FormTextarea } from "@/components/ui/form-field";
import { Button } from "@/components/ui/button";
import { DocumentLinkButton } from "@/components/drivers/document-link-button";
import { computePodStatus } from "@/lib/documents/pod-status";
import { getLatestDocument } from "@/lib/documents/latest-document";
import { getPodSignedUrl } from "../../loads/pod-actions";
import { updateInvoice, addInvoiceLineItem } from "../actions";
import { QuickbooksInvoiceSync } from "@/components/integrations/quickbooks-invoice-sync";
import { QuickbooksInvoicePayments } from "@/components/integrations/quickbooks-invoice-payments";
import { getInvoiceQuickbooksSync, isPartyMappedToQuickbooks, isQuickbooksConnectedForOrg } from "@/lib/integrations/quickbooks/sync-reads";
import { getInvoicePaymentImports } from "@/lib/integrations/quickbooks/payment-reads";
import { deductAdvancesIntoInvoice } from "../../advances/actions";
import { BillingPacketSection } from "@/components/invoices/billing-packet-section";
import { isPacketOutdated } from "../billing-packet-actions";
import { PaymentHistorySection, type PaymentHistoryRow } from "@/components/invoices/payment-history-section";
import { invoiceEffectiveStatus } from "@/lib/invoices/effective-status";
import { CollectionsSection } from "@/components/collections/collections-section";
import { DesktopWorkspaceTabs } from "@/components/desktop/workspace-tabs";
import { RegisterDesktopActions } from "@/components/desktop/actions-context";
import { evaluateFactoringEligibility, isNonTerminalFactoredInvoiceStatus } from "@/lib/factoring/eligibility";
import { getDefaultFactoringRelationship } from "@/lib/factoring/default-relationship";
import { FactoringSection, type RelationshipOption, type FactoredInvoiceDisplay, type FactoringEventDisplay } from "@/components/invoices/factoring-section";

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

  // QuickBooks send MVP (owner/admin only). Reads degrade to null/false if
  // migration 0117 is not applied yet.
  const { data: qbRoleData } = await supabase.rpc("current_role");
  const canManageQuickbooks = ["owner", "admin"].includes((qbRoleData as string | null) ?? "");
  const qbPartyType: "broker" | "customer" | null = invoice.broker_id ? "broker" : invoice.customer_id ? "customer" : null;
  const qbPartyId: string | null = invoice.broker_id ?? invoice.customer_id ?? null;
  const [qbSync, qbCustomerMapped, qbConnected] = canManageQuickbooks
    ? await Promise.all([
        getInvoiceQuickbooksSync(id),
        qbPartyType && qbPartyId ? isPartyMappedToQuickbooks(qbPartyType, qbPartyId) : Promise.resolve(false),
        isQuickbooksConnectedForOrg(),
      ])
    : [null, false, false];
  const qbEligibleReason = !qbConnected
    ? "QuickBooks is not connected."
    : !["sent", "viewed", "partially_paid", "paid"].includes(invoice.status)
      ? "the invoice must be issued (Sent, Viewed, Partially Paid, or Paid)."
      : !(Number(invoice.total_amount) > 0)
        ? "the invoice total is zero."
        : !qbPartyType
          ? "the invoice has no customer or broker."
          : null;
  const qbPartyHref = qbPartyType === "broker" ? `/brokers/${qbPartyId}` : qbPartyType === "customer" ? `/customers/${qbPartyId}` : null;
  // Payment sync (owner/admin, and only once the invoice is synced). Reads
  // degrade to [] if migration 0118 is not applied yet.
  const qbPaymentImports =
    canManageQuickbooks && qbSync?.status === "synced" ? await getInvoicePaymentImports(id) : [];
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
  let linkedLoadNumber: string | null = null;
  if (invoice.load_id) {
    const [podResult, rateConResult, bolResult, loadResult] = await Promise.all([
      getLatestDocument(supabase, "load", invoice.load_id, "pod"),
      getLatestDocument(supabase, "load", invoice.load_id, "rate_confirmation"),
      getLatestDocument(supabase, "load", invoice.load_id, "bol"),
      supabase.from("loads").select("load_number").eq("id", invoice.load_id).maybeSingle(),
    ]);
    pod = podResult;
    rateConDoc = rateConResult;
    bolDoc = bolResult;
    linkedLoadNumber = loadResult.data?.load_number ?? null;
  }
  // Invoice edit UX repair (A1 completion): the invoice's own broker_id/
  // customer_id are, as of updateInvoice()'s server-side fix, always
  // re-derived from the linked load on every save -- never independently
  // choosable once load_id is set. Editable Broker/Customer selects for a
  // load-linked invoice would therefore visibly do nothing, which is worse
  // than not offering them; this just looks up the display name for
  // whichever party the load already determined, from the same brokers/
  // customers lists already fetched for the manual-invoice case below.
  const linkedPartyName = invoice.broker_id
    ? (brokers ?? []).find((b) => b.id === invoice.broker_id)?.company_name ?? null
    : invoice.customer_id
      ? (customers ?? []).find((c) => c.id === invoice.customer_id)?.company_name ?? null
      : null;
  const linkedPartyType = invoice.broker_id ? "Broker" : invoice.customer_id ? "Customer" : null;
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

  // ---------------------------------------------------------------------
  // Phase 2H.4 -- Factoring. eligibility here is a UI pre-check only
  // (src/lib/factoring/eligibility.ts); submit_invoice_to_factor() (0073)
  // is the sole authority and re-validates everything itself. Reading
  // factored_invoices/factoring_events goes through this page's normal
  // caller-scoped client (RLS-safe) the same as every other query above.
  // ---------------------------------------------------------------------
  const organizationId = await getCurrentOrgId();
  const eligibility = evaluateFactoringEligibility({ status: invoice.status, amountPaid: Number(invoice.amount_paid) });

  const { data: factoredInvoicesRaw } = await supabase
    .from("factored_invoices")
    .select("*, factoring_companies(name), factoring_relationships(relationship_name, recourse_type)")
    .eq("invoice_id", id)
    .order("created_at", { ascending: false });

  const factoredInvoices: FactoredInvoiceDisplay[] = (factoredInvoicesRaw ?? []).map((fi) => ({
    id: fi.id,
    status: fi.status,
    companyName: (fi.factoring_companies as unknown as { name: string } | null)?.name ?? "--",
    relationshipName: (fi.factoring_relationships as unknown as { relationship_name: string | null } | null)?.relationship_name ?? null,
    recourseType: (fi.factoring_relationships as unknown as { recourse_type: string | null } | null)?.recourse_type ?? null,
    submittedAt: fi.submitted_at,
    invoiceFaceValue: Number(fi.invoice_face_value),
    advancePercentage: Number(fi.advance_percentage),
    expectedAdvanceAmount: Number(fi.expected_advance_amount),
    factoringFeePercentage: Number(fi.factoring_fee_percentage),
    factoringFeeAmount: Number(fi.factoring_fee_amount),
    reservePercentage: Number(fi.reserve_percentage),
    reserveAmount: Number(fi.reserve_amount),
    feeTiming: fi.fee_timing,
    otherFees: Number(fi.other_fees),
    expectedFundingAmount: Number(fi.expected_funding_amount),
    actualFundedAmount: fi.actual_funded_amount !== null ? Number(fi.actual_funded_amount) : null,
    externalReference: fi.external_reference,
    rejectionReason: fi.rejection_reason,
    customerPaidFactorAmount: fi.customer_paid_factor_amount !== null ? Number(fi.customer_paid_factor_amount) : null,
    customerPaidFactorAt: fi.customer_paid_factor_at,
    reserveReleasedAmount: Number(fi.reserve_released_amount),
    outstandingReserve: Number(fi.outstanding_reserve),
    reconciliationStatus: fi.reconciliation_status,
    recourseAmount: Number(fi.recourse_amount),
    chargebackAmount: Number(fi.chargeback_amount),
    notes: fi.notes,
  }));

  // The most recent factored_invoices row (by created_at, already the
  // query's own order) is always the "primary" one shown in full via
  // FactoringStatusCard -- regardless of its status. A rejected/cancelled
  // row is still this invoice's current factoring state until a NEW
  // submission is made (Phase 2H.5: "rejected: read-only for this
  // phase"), so it must get the same full read-only detail view a
  // funded row does, not be silently demoted to the compact "Prior
  // Factoring Attempts" list -- only rows OLDER than the most recent one
  // belong there. Resubmission eligibility (spec section 10/Phase 2H.4)
  // is a SEPARATE question, handled by FactoringSection itself via
  // isNonTerminalFactoredInvoiceStatus() on the primary row's own status.
  const activeFactoredInvoice = factoredInvoices[0] ?? null;
  const historicalFactoredInvoices = factoredInvoices.slice(1);

  let factoringEvents: FactoringEventDisplay[] = [];
  if (activeFactoredInvoice) {
    const { data: eventsRaw } = await supabase
      .from("factoring_events")
      .select("*")
      .eq("factored_invoice_id", activeFactoredInvoice.id)
      .order("created_at", { ascending: false });

    const performerIds = [...new Set((eventsRaw ?? []).map((e) => e.performed_by).filter((v): v is string => !!v))];
    const { data: performers } = performerIds.length
      ? await supabase.from("profiles").select("id, full_name").in("id", performerIds)
      : { data: [] as { id: string; full_name: string }[] };
    const performerNameById = new Map((performers ?? []).map((p) => [p.id, p.full_name]));

    factoringEvents = (eventsRaw ?? []).map((e) => ({
      id: e.id,
      eventType: e.event_type,
      fromStatus: e.from_status,
      toStatus: e.to_status,
      amount: e.amount !== null ? Number(e.amount) : null,
      reference: e.reference,
      notes: e.notes,
      performedByName: e.performed_by ? (performerNameById.get(e.performed_by) ?? null) : null,
      createdAt: e.created_at,
    }));
  }

  // Resubmission is only offered when there is no row at all, or the
  // most recent row is terminal-for-resubmission (rejected/cancelled) --
  // the exact factored_invoices_one_active_per_invoice predicate (0071),
  // not a re-guess of it.
  const canResubmit = !activeFactoredInvoice || !isNonTerminalFactoredInvoiceStatus(activeFactoredInvoice.status);

  let relationshipOptions: RelationshipOption[] = [];
  let defaultRelationshipId: string | null = null;
  if (eligibility.eligible && canResubmit) {
    const today = new Date().toISOString().slice(0, 10);
    const { data: relRaw } = await supabase
      .from("factoring_relationships")
      .select(
        "id, relationship_name, default_advance_percentage, default_factoring_fee_percentage, default_reserve_percentage, fee_timing, recourse_type, effective_from, effective_to, factoring_companies!inner(id, name, is_active)"
      )
      .eq("is_active", true)
      .eq("factoring_companies.is_active", true)
      .lte("effective_from", today)
      .or(`effective_to.is.null,effective_to.gte.${today}`);

    relationshipOptions = (relRaw ?? []).map((r) => ({
      id: r.id,
      companyName: (r.factoring_companies as unknown as { name: string }).name,
      relationshipName: r.relationship_name,
      advancePercentage: Number(r.default_advance_percentage),
      factoringFeePercentage: Number(r.default_factoring_fee_percentage),
      reservePercentage: Number(r.default_reserve_percentage),
      feeTiming: r.fee_timing,
      recourseType: r.recourse_type,
    }));

    const defaultRel = await getDefaultFactoringRelationship(organizationId);
    defaultRelationshipId = defaultRel && relationshipOptions.some((r) => r.id === defaultRel.relationship.id) ? defaultRel.relationship.id : null;
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
          {invoice.load_id ? (
            // Load-linked invoice (A1 completion): no editable Broker/
            // Customer selects, no hidden load_id/broker_id/customer_id
            // input either -- none of the three is client-submittable at
            // all for this invoice, so there is nothing here for a forged
            // request to relink, unlink, or re-party even before migration
            // 0112's database-level backstop is applied. Read-only display
            // only; updateInvoice() derives the real values itself,
            // directly from the load, on every save.
            <div className="min-w-0 space-y-1 sm:col-span-2">
              <span className="text-[12px] font-medium text-desktop-text">Billing Party</span>
              <div className="flex flex-wrap items-center gap-x-2 gap-y-1 rounded-lg border border-border bg-muted px-3.5 py-2.5 text-sm">
                <Link href={`/loads/${invoice.load_id}`} className="font-medium text-primary hover:underline">
                  Load {linkedLoadNumber ?? "--"}
                </Link>
                <span className="text-muted-foreground">&middot;</span>
                <span className="text-muted-foreground">
                  {linkedPartyType && linkedPartyName ? `${linkedPartyType}: ${linkedPartyName}` : "No broker/customer on file for this load"}
                </span>
              </div>
              <p className="text-xs text-muted-foreground">
                Billing information comes from the linked load and cannot be changed here. To bill a different party, correct it on the load itself
                (if the load has not yet been invoiced elsewhere) or void this invoice and create a manual one.
              </p>
            </div>
          ) : (
            // Manual invoice (load_id is null and updateInvoice() keeps it
            // that way): Broker/Customer remain fully editable, exactly as
            // before this repair.
            <>
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
            </>
          )}
          <FormField label="Bill to name" name="bill_to_name" defaultValue={invoice.bill_to_name} required />
          <FormField label="Bill to email" name="bill_to_email" type="email" defaultValue={invoice.bill_to_email} />
          <FormField label="Due date" name="due_date" type="date" defaultValue={invoice.due_date} />
          <FormTextarea label="Notes" name="notes" defaultValue={invoice.notes} />
        </FormGrid>
      </FormCard>

      {canManageQuickbooks && (
        <QuickbooksInvoiceSync
          invoiceId={id}
          sync={qbSync}
          eligibleReason={qbEligibleReason}
          customerMapped={qbCustomerMapped}
          partyHref={qbPartyHref}
        />
      )}

      {canManageQuickbooks && qbSync?.status === "synced" && (
        <QuickbooksInvoicePayments invoiceId={id} initialImports={qbPaymentImports} />
      )}

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

      <FactoringSection
        invoiceId={id}
        eligible={eligibility.eligible}
        ineligibleReason={eligibility.eligible ? null : eligibility.reason}
        activeFactoredInvoice={activeFactoredInvoice}
        canResubmit={canResubmit}
        historicalFactoredInvoices={historicalFactoredInvoices}
        relationshipOptions={relationshipOptions}
        defaultRelationshipId={defaultRelationshipId}
        events={factoringEvents}
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
