import Link from "next/link";
import { notFound } from "next/navigation";
import { FileText, Package, CheckCircle2, AlertTriangle } from "lucide-react";
import { createClient } from "@/lib/supabase/server";
import { RegisterDesktopActions } from "@/components/desktop/actions-context";
import { StatusBadge } from "@/components/ui/status-badge";
import { EmailCarrierButton } from "@/components/dispatch-fee-invoices/email-carrier-button";
import { CarrierInvoiceFactoringPanel } from "@/components/carrier-invoices/carrier-invoice-factoring-panel";
import { CarrierInvoiceLifecyclePanel } from "@/components/carrier-invoices/carrier-invoice-lifecycle-panel";
import { isCarrierInvoicePilotOperator, lifecycleActions, type IssuancePreview } from "@/lib/factoring/carrier-invoice-issuance";
import { DesktopWorkspaceTabs } from "@/components/desktop/workspace-tabs";
import { DocumentLinkButton } from "@/components/drivers/document-link-button";
import { computePodStatus } from "@/lib/documents/pod-status";
import { getLatestDocument } from "@/lib/documents/latest-document";
import { getPodSignedUrl } from "@/app/(app)/loads/pod-actions";
import { loadIssuedCarrierInvoice, factorPackageMissing } from "@/lib/carrier-invoices/pdf";
import { packageRecipient } from "@/lib/carrier-invoices/source";
import { getCarrierInvoiceFactoringPreview } from "../factoring-actions";
import { previewCarrierInvoiceIssuance, previewCarrierInvoiceReissue } from "../issuance-actions";


// Carrier invoice = the carrier's own invoice to the broker/customer (the one
// a factoring company buys), only for "broker pays the carrier" loads. Lifecycle
// (mark ready / issue / discard / reissue) and the formal factoring record come
// from the database; once issued, the factor package (invoice + POD + rate con
// + BOL) can be viewed, downloaded for a factor's website, or emailed to the
// factor / carrier / broker per the carrier's "Who sends the paperwork?" setting.
// Read through the caller's own RLS-scoped session.
export default async function CarrierInvoiceDetailPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const supabase = await createClient();
  const { data: invoice } = await supabase
    .from("carrier_invoices")
    .select("id, invoice_number, invoice_document_type, issuance_status, payment_status, currency, subtotal_amount, total_amount, amount_paid, balance_due, payment_terms_days, issued_at, due_date, carrier_id, updated_at, recipient_type, recipient_broker_id, recipient_customer_id, void_reason, carriers(legal_name, dba_name, email, factor_package_sent_by, factoring_mode), brokers:recipient_broker_id(company_name), customers:recipient_customer_id(company_name)")
    .eq("id", id)
    .maybeSingle();
  if (!invoice) notFound();
  const names = invoice as unknown as {
    carriers: { legal_name: string; dba_name: string | null; email: string | null; factor_package_sent_by: string | null; factoring_mode: string | null } | null;
    brokers: { company_name: string } | null;
    customers: { company_name: string } | null;
  };

  const {
    data: { user },
  } = await supabase.auth.getUser();
  const { data: profile } = user ? await supabase.from("profiles").select("role").eq("id", user.id).maybeSingle() : { data: null };
  const role = String(profile?.role ?? "");

  const { data: ledger } = await supabase.from("carrier_invoice_billable_ledger_0157").select("load_id, amount, loads(load_number)").eq("invoice_id", id).is("released_at", null);
  const { data: submissions } = await supabase.from("carrier_invoice_factoring_submissions_0157").select("id, status, submitted_at").eq("carrier_invoice_id", id).order("submitted_at", { ascending: false });
  const workflowDraft = (ledger ?? []).length > 0;
  const actions = lifecycleActions(
    { issuance_status: String(invoice.issuance_status), payment_status: String(invoice.payment_status), invoice_document_type: String(invoice.invoice_document_type) },
    role,
    { workflowDraft, hasSubmission: (submissions ?? []).length > 0 },
  );

  // what the server would issue for a draft / ready invoice; what a reissue would do for an issued one
  let issuePreview: IssuancePreview | null = null;
  if ((actions.markReady || actions.issue || actions.discard) && invoice.recipient_type) {
    issuePreview = await previewCarrierInvoiceIssuance({
      carrierId: String(invoice.carrier_id),
      loadIds: (ledger ?? []).map((l) => String(l.load_id)),
      recipientType: invoice.recipient_type === "customer" ? "customer" : "broker",
      recipientId: String(invoice.recipient_broker_id ?? invoice.recipient_customer_id ?? ""),
    });
  }
  const reissuePreview = actions.reissue ? await previewCarrierInvoiceReissue(id) : null;
  const factoringPreview = actions.factoringPanel ? await getCarrierInvoiceFactoringPreview(id) : null;

  const { data: feeLink } = await supabase.from("carrier_invoice_dispatch_fee_links_0157").select("dispatch_invoice_id, disposition").eq("freight_invoice_id", id).maybeSingle();
  const { data: reissuedTo } = await supabase.from("carrier_invoice_reissues_0157").select("replacement_invoice_id, reason").eq("original_invoice_id", id).maybeSingle();
  const { data: reissuedFrom } = await supabase.from("carrier_invoice_reissues_0157").select("original_invoice_id, reason").eq("replacement_invoice_id", id).maybeSingle();

  // factor package (issued freight invoices only)
  const issued = invoice.issuance_status === "issued" && invoice.invoice_document_type === "carrier_freight_invoice";
  const issuedInv = issued ? await loadIssuedCarrierInvoice(supabase, id) : null;
  const missing = issuedInv ? await factorPackageMissing(supabase, issuedInv) : [];
  const sender = names.carriers?.factor_package_sent_by === "carrier" ? "carrier" : "dispatcher";
  const dest = issuedInv ? packageRecipient(issuedInv.snapshot, sender, names.carriers?.email ?? null) : null;
  const { data: emailsRaw } = issued
    ? await supabase.from("email_send_log").select("recipient, status, sent_at, error").eq("entity_type", "carrier_invoice").eq("entity_id", id).order("sent_at", { ascending: false }).limit(5)
    : { data: [] as { recipient: string; status: string; sent_at: string; error: string | null }[] };
  const emails = (emailsRaw ?? []) as { recipient: string; status: string; sent_at: string; error: string | null }[];
  const lastSent = emails.find((e) => e.status === "sent");

  const carrierName = names.carriers?.dba_name || names.carriers?.legal_name || "--";
  const recipientName = names.brokers?.company_name ?? names.customers?.company_name ?? "--";
  const loads = (ledger ?? []) as unknown as { load_id: string; amount: number; loads: { load_number: string } | null }[];
  // An issued invoice keeps its loads in the snapshot (the ledger rows stay live).
  const freight = invoice.invoice_document_type === "carrier_freight_invoice";
  const payTo = issuedInv?.snapshot.factoring?.factoring_company_legal_name
    ? `${issuedInv.snapshot.factoring.factoring_company_legal_name} (factoring company)`
    : names.carriers?.factoring_mode === "factored"
      ? `${carrierName}'s factoring company`
      : carrierName;

  // Billing documents, per load -- same checks and wording as your own invoice page.
  const docRows = await Promise.all(
    loads.map(async (l) => {
      const [pod, rateCon, bol] = await Promise.all([
        getLatestDocument(supabase, "load", l.load_id, "pod"),
        getLatestDocument(supabase, "load", l.load_id, "rate_confirmation"),
        getLatestDocument(supabase, "load", l.load_id, "bol"),
      ]);
      return { loadId: l.load_id, loadNumber: l.loads?.load_number ?? "load", pod, podStatus: computePodStatus(pod), rateConReady: rateCon !== null, bolReady: bol !== null };
    })
  );
  const readyToSend = docRows.length > 0 && docRows.every((d) => d.podStatus === "verified");

  const total = Number(invoice.total_amount);
  const paid = Number(invoice.amount_paid ?? 0);
  const issuedDate = invoice.issued_at ? new Date(String(invoice.issued_at)) : null;
  const dueDate = invoice.due_date ? new Date(String(invoice.due_date) + "T00:00:00") : null;
  const terms = invoice.payment_terms_days != null ? Number(invoice.payment_terms_days) : issuedDate && dueDate ? Math.round((dueDate.getTime() - new Date(issuedDate.toDateString()).getTime()) / 86400000) : null;
  const statusLabel = invoice.issuance_status === "issued" ? String(invoice.payment_status) : String(invoice.issuance_status);
  const title = invoice.invoice_number ? String(invoice.invoice_number) : "Draft invoice";

  return (
    <div className="space-y-3">
      <DesktopWorkspaceTabs tabs={[{ label: "Invoices", href: "/invoices" }, { label: title, href: `/carrier-invoices/${id}` }]} />
      {issued && (
        <RegisterDesktopActions
          title={`Invoice ${invoice.invoice_number ?? ""}`}
          printHref={`/carrier-invoices/${id}/pdf`}
          exportOptions={[{ label: "Export PDF", href: `/carrier-invoices/${id}/pdf?download=1` }, { label: "Billing packet PDF", href: `/carrier-invoices/${id}/package?download=1` }]}
          email={{ entityType: "carrier_invoice", entityId: id }}
        />
      )}
      {issued && (
        <div className="flex justify-end">
          <Link
            href={`/carrier-invoices/${id}/pdf`}
            target="_blank"
            className="inline-flex items-center gap-1.5 rounded-lg border border-border bg-card px-3 py-1.5 text-sm font-medium transition-colors hover:bg-muted"
          >
            <FileText className="size-4" />
            Download PDF
          </Link>
        </div>
      )}

      <CarrierInvoiceLifecyclePanel invoiceId={id} updatedAt={String(invoice.updated_at)} actions={actions} canIssueDraft={actions.markReady && isCarrierInvoicePilotOperator(role)} issuePreview={issuePreview} reissuePreview={reissuePreview} />

      <div className="rounded-xl border border-border bg-card p-4 shadow-elevation-1">
        <div className="flex flex-wrap items-start justify-between gap-2">
          <div>
            <p className="text-base font-semibold">{title}</p>
            <p className="mt-0.5 text-xs text-muted-foreground">
              {freight
                ? `Carrier's invoice: the broker pays ${carrierName} for this load, so the invoice is in ${carrierName}'s name.`
                : `Dispatch-service invoice from ${carrierName} to ${recipientName}.`}
            </p>
          </div>
          <StatusBadge status={statusLabel} />
        </div>
        <div className="mt-3 grid grid-cols-1 gap-3 text-sm sm:grid-cols-2">
          <ReadOnly label="Invoice number" value={invoice.invoice_number ? String(invoice.invoice_number) : "Given when you issue it"} />
          <ReadOnly label="Status" value={statusLabel.replace(/_/g, " ")} capitalize />
          <div className="min-w-0 space-y-1 sm:col-span-2">
            <span className="text-[12px] font-medium text-desktop-text">Billing Party</span>
            <div className="flex flex-wrap items-center gap-x-2 gap-y-1 rounded-lg border border-border bg-muted px-3.5 py-2.5 text-sm">
              {loads.length === 0 ? (
                <span className="text-muted-foreground">No loads</span>
              ) : (
                loads.map((l, i) => (
                  <span key={l.load_id}>
                    {i > 0 ? ", " : ""}
                    <Link href={`/loads/${l.load_id}`} className="font-medium text-primary hover:underline">Load {l.loads?.load_number ?? "--"}</Link>
                  </span>
                ))
              )}
              <span className="text-muted-foreground">&middot;</span>
              <span className="text-muted-foreground">{invoice.recipient_type === "customer" ? "Customer" : "Broker"}: {recipientName}</span>
            </div>
          </div>
          <ReadOnly label="From (carrier)" value={carrierName} />
          <ReadOnly label="Payment goes to" value={payTo} />
        </div>
        <p className="mt-3 text-xs text-muted-foreground">
          {invoice.issuance_status === "issued"
            ? "This invoice is locked because it was issued (the factoring company relies on it matching). To fix a mistake, use Reissue below: it voids this one and issues a corrected copy."
            : "Details come from the load and the carrier. To change something, fix it on the load or carrier page, or discard this draft and create it again."}
        </p>
      </div>

      <div className="grid grid-cols-1 gap-4 md:grid-cols-3">
        <SummaryTile label="Subtotal" value={Number(invoice.subtotal_amount ?? total)} />
        <SummaryTile label="Total" value={total} />
        <SummaryTile label="Balance Due" value={Number(invoice.balance_due ?? total - paid)} highlight />
      </div>

      <div className="rounded-xl border border-border bg-card p-4 shadow-elevation-1">
        <p className="text-sm font-medium">Payment Terms</p>
        <div className="mt-2 grid grid-cols-2 gap-x-4 gap-y-2 text-sm sm:grid-cols-4">
          <div>
            <p className="text-xs text-muted-foreground">Invoice Date</p>
            <p className="font-medium">{issuedDate ? issuedDate.toLocaleDateString() : "When issued"}</p>
          </div>
          <div>
            <p className="text-xs text-muted-foreground">Terms</p>
            <p className="font-medium">{terms != null ? `Net ${terms}` : "--"}</p>
          </div>
          <div>
            <p className="text-xs text-muted-foreground">Payment Due Date</p>
            <p className="font-medium">{dueDate ? dueDate.toLocaleDateString() : "--"}</p>
          </div>
          <div>
            <p className="text-xs text-muted-foreground">Days Until Due / Past Due</p>
            <p className="font-medium">
              {dueDate && invoice.issuance_status === "issued"
                ? (() => {
                    const today = new Date();
                    today.setHours(0, 0, 0, 0);
                    const days = Math.round((dueDate.getTime() - today.getTime()) / 86400000);
                    return days < 0 ? `${Math.abs(days)}d past due` : days === 0 ? "Due today" : `${days}d until due`;
                  })()
                : "--"}
            </p>
          </div>
        </div>
      </div>

      {freight && docRows.length > 0 && (
        <div className="rounded-xl border border-border bg-card p-4 shadow-elevation-1">
          <div className="flex items-center justify-between">
            <p className="text-sm font-medium">Billing Documents</p>
            <span className={`inline-flex items-center gap-1.5 rounded-full px-2.5 py-1 text-xs font-medium ${readyToSend ? "bg-success/10 text-success" : "bg-danger/10 text-danger"}`}>
              {readyToSend ? <CheckCircle2 className="size-3.5" /> : <AlertTriangle className="size-3.5" />}
              {readyToSend ? "Ready to Send" : "Not Ready to Send"}
            </span>
          </div>
          <div className="mt-3 space-y-3 text-sm">
            {docRows.map((d) => (
              <div key={d.loadId} className="space-y-2">
                {docRows.length > 1 && <p className="text-xs font-semibold text-muted-foreground">Load {d.loadNumber}</p>}
                <div className="flex items-center justify-between">
                  <span className="flex items-center gap-1.5">
                    {d.podStatus === "verified" ? <CheckCircle2 className="size-4 text-success" /> : <AlertTriangle className="size-4 text-warning" />}
                    POD {d.podStatus === "verified" ? "Verified" : d.podStatus === "missing" ? "Missing" : d.podStatus === "rejected" ? "Rejected" : "Uploaded (not yet verified)"}
                  </span>
                  {d.pod ? (
                    <DocumentLinkButton label="View POD" getUrl={getPodSignedUrl.bind(null, d.pod.file_path, false)} />
                  ) : (
                    <Link href={`/loads/${d.loadId}`} className="text-xs font-medium text-primary hover:underline">Upload on load page &rarr;</Link>
                  )}
                </div>
                <div className="flex items-center justify-between">
                  <span className="flex items-center gap-1.5">
                    {d.rateConReady ? <CheckCircle2 className="size-4 text-success" /> : <AlertTriangle className="size-4 text-warning" />}
                    Rate Confirmation {d.rateConReady ? "On File" : "Missing"}
                  </span>
                  {!d.rateConReady && <Link href={`/loads/${d.loadId}`} className="text-xs font-medium text-primary hover:underline">Add on load page &rarr;</Link>}
                </div>
                <div className="flex items-center justify-between">
                  <span className="flex items-center gap-1.5">
                    {d.bolReady ? <CheckCircle2 className="size-4 text-success" /> : <AlertTriangle className="size-4 text-warning" />}
                    BOL {d.bolReady ? "On File" : "Missing"}
                  </span>
                  {!d.bolReady && <Link href={`/loads/${d.loadId}`} className="text-xs font-medium text-primary hover:underline">Add on load page &rarr;</Link>}
                </div>
              </div>
            ))}
          </div>
          {!readyToSend && (
            <p className="mt-3 text-xs text-muted-foreground">
              The billing packet can be sent once each load&apos;s Proof of Delivery is verified. (Rate Confirmation and BOL are included when on file.)
            </p>
          )}
        </div>
      )}

      {freight && (
        <div className="rounded-xl border border-border bg-card p-4 shadow-elevation-1">
          <p className="text-sm font-medium">Billing Packet</p>
          {!issuedInv ? (
            <p className="mt-2 text-[12.5px] text-muted-foreground">
              {invoice.issuance_status === "voided" ? "This invoice is void." : "Issue the invoice first. The billing packet is then the invoice plus the load's proof of delivery, rate confirmation and bill of lading."}
            </p>
          ) : (
            <div className="mt-2 space-y-2.5 text-[12.5px]">
              <p>
                Goes to: <span className="font-medium">{dest?.label}</span>
                <span className="text-muted-foreground">
                  {" "}(carrier setting: {sender === "carrier" ? "the carrier sends the paperwork" : "we send the paperwork"}{" "}
                  -- <Link href={`/carriers/${invoice.carrier_id}#broker-pays`} className="text-primary hover:underline">change</Link>)
                </span>
              </p>
              {missing.length > 0 && (
                <div className="rounded-sm border border-warning/30 bg-warning/5 px-3 py-2 text-warning">
                  Not ready -- missing: {missing.join("; ")}. Upload and verify it on the load, then come back.
                </div>
              )}
              <div className="flex flex-wrap items-center gap-2">
                <a href={`/carrier-invoices/${id}/pdf`} target="_blank" rel="noopener" className="inline-flex h-8 items-center gap-1.5 rounded-sm border border-desktop-border px-3 text-[13px] font-medium hover:bg-muted">
                  <FileText className="size-4" /> Invoice PDF
                </a>
                {missing.length === 0 && (
                  <>
                    <a href={`/carrier-invoices/${id}/package`} target="_blank" rel="noopener" className="inline-flex h-8 items-center gap-1.5 rounded-sm border border-desktop-border px-3 text-[13px] font-medium hover:bg-muted">
                      <Package className="size-4" /> View billing packet
                    </a>
                    <a href={`/carrier-invoices/${id}/package?download=1`} className="inline-flex h-8 items-center rounded-sm border border-desktop-border px-3 text-[13px] font-medium hover:bg-muted">
                      Download billing packet
                    </a>
                    <EmailCarrierButton label={lastSent ? "Email Again" : dest?.who === "factor_portal" ? "Email Billing Packet" : `Email to ${dest?.who === "factor" ? "Factor" : dest?.who === "broker" ? "Broker" : "Carrier"}`} />
                  </>
                )}
              </div>
              {dest?.who === "factor_portal" && <p className="text-muted-foreground">This factor takes uploads on its website: download the billing packet and upload it there (or email it to an address you type in).</p>}
              <p className="text-muted-foreground">
                {lastSent ? `Emailed to ${lastSent.recipient} on ${new Date(lastSent.sent_at).toLocaleString()}.` : "Not emailed yet."}
                {emails[0] && emails[0].status !== "sent" && <span className="text-danger"> Last attempt did not send: {emails[0].error ?? emails[0].status}.</span>}
              </p>
            </div>
          )}
        </div>
      )}

      <div className="rounded-xl border border-border bg-card p-4 text-[12.5px] shadow-elevation-1">
        {invoice.issuance_status === "voided" && reissuedTo ? (
          <p role="status" className="mb-2" data-testid="reissued-to">
            Voided and reissued: <Link className="underline" href={`/carrier-invoices/${reissuedTo.replacement_invoice_id}`}>replacement invoice</Link> (reason: {String(reissuedTo.reason)}). This original is preserved and can never be factored.
          </p>
        ) : null}
        {reissuedFrom ? (
          <p role="status" className="mb-2" data-testid="reissued-from">
            Reissued from <Link className="underline" href={`/carrier-invoices/${reissuedFrom.original_invoice_id}`}>the original invoice</Link> (reason: {String(reissuedFrom.reason)}).
          </p>
        ) : null}
        {feeLink ? (
          <p data-testid="dispatch-fee-link">
            Dispatch-service fee: a separate receivable ({String(feeLink.disposition).replace("_", " ")}) --{" "}
            <Link className="underline" href={`/carrier-invoices/${feeLink.dispatch_invoice_id}`}>view the dispatch-service invoice</Link>
            . It is not part of this invoice and is never factored.
          </p>
        ) : (
          <p className="text-muted-foreground">Your dispatch fee is a separate receivable: bill it to the carrier on a Dispatch Fee Invoice. It is never on this invoice and never factored.</p>
        )}
      </div>

      {actions.factoringPanel ? <CarrierInvoiceFactoringPanel carrierInvoiceId={id} preview={factoringPreview} /> : null}
      {(submissions ?? []).length > 0 ? (
        <section aria-labelledby="fs-heading" className="rounded-md border border-desktop-border bg-card p-3">
          <h2 id="fs-heading" className="text-[13px] font-semibold">Factoring submissions</h2>
          <ul className="mt-1 text-[12.5px]">
            {(submissions ?? []).map((s) => (
              <li key={s.id}>
                {String(s.status)} -- {new Date(String(s.submitted_at)).toLocaleString()}
              </li>
            ))}
          </ul>
        </section>
      ) : null}
    </div>
  );
}

function ReadOnly({ label, value, capitalize }: { label: string; value: string; capitalize?: boolean }) {
  return (
    <div className="space-y-1">
      <span className="text-[12px] font-medium text-desktop-text">{label}</span>
      <div className={"flex h-10 items-center rounded-lg border border-border bg-muted px-3.5 text-sm text-muted-foreground" + (capitalize ? " capitalize" : "")}>{value}</div>
    </div>
  );
}

function SummaryTile({ label, value, highlight }: { label: string; value: number; highlight?: boolean }) {
  return (
    <div className="rounded-md border border-desktop-border bg-card px-3 py-2 shadow-elevation-1">
      <p className="text-[10.5px] font-semibold uppercase tracking-wide text-muted-foreground">{label}</p>
      <p className={"mt-1 text-lg font-semibold tabular-nums " + (highlight ? "text-primary" : "")}>${Number(value).toLocaleString()}</p>
    </div>
  );
}
