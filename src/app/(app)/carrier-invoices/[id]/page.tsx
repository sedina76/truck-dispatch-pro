import Link from "next/link";
import { notFound } from "next/navigation";
import { FileText, Package } from "lucide-react";
import { createClient } from "@/lib/supabase/server";
import { DesktopPanel, DesktopPanelHeader, DesktopPanelBody } from "@/components/desktop/panel";
import { RegisterDesktopActions } from "@/components/desktop/actions-context";
import { StatusBadge } from "@/components/ui/status-badge";
import { EmailCarrierButton } from "@/components/dispatch-fee-invoices/email-carrier-button";
import { CarrierInvoiceFactoringPanel } from "@/components/carrier-invoices/carrier-invoice-factoring-panel";
import { CarrierInvoiceLifecyclePanel } from "@/components/carrier-invoices/carrier-invoice-lifecycle-panel";
import { lifecycleActions, type IssuancePreview } from "@/lib/factoring/carrier-invoice-issuance";
import { loadIssuedCarrierInvoice, factorPackageMissing } from "@/lib/carrier-invoices/pdf";
import { packageRecipient } from "@/lib/carrier-invoices/source";
import { getCarrierInvoiceFactoringPreview } from "../factoring-actions";
import { previewCarrierInvoiceIssuance, previewCarrierInvoiceReissue } from "../issuance-actions";

function money(n: number | string): string {
  return `$${Number(n).toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
}

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
    .select("id, invoice_number, invoice_document_type, issuance_status, payment_status, currency, total_amount, amount_paid, issued_at, due_date, carrier_id, updated_at, recipient_type, recipient_broker_id, recipient_customer_id, void_reason, carriers(legal_name, dba_name, email, factor_package_sent_by), brokers:recipient_broker_id(company_name), customers:recipient_customer_id(company_name)")
    .eq("id", id)
    .maybeSingle();
  if (!invoice) notFound();
  const names = invoice as unknown as {
    carriers: { legal_name: string; dba_name: string | null; email: string | null; factor_package_sent_by: string | null } | null;
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

  return (
    <div className="space-y-3">
      {issued && (
        <RegisterDesktopActions
          title={`Invoice ${invoice.invoice_number ?? ""}`}
          printHref={`/carrier-invoices/${id}/pdf`}
          exportOptions={[{ label: "Invoice PDF", href: `/carrier-invoices/${id}/pdf?download=1` }, { label: "Invoice package PDF", href: `/carrier-invoices/${id}/package?download=1` }]}
          email={{ entityType: "carrier_invoice", entityId: id }}
        />
      )}
      <div className="flex flex-wrap items-center justify-between gap-2">
        <div>
          <h1 className="text-[15px] font-semibold tracking-tight text-desktop-text">Carrier Invoice {invoice.invoice_number ?? "(draft)"}</h1>
          <p className="mt-0.5 text-xs text-muted-foreground">
            From {carrierName} to {recipientName}
            {invoice.invoice_document_type !== "carrier_freight_invoice" ? " -- dispatch-service invoice" : ""}
          </p>
        </div>
        <div className="flex items-center gap-2">
          <StatusBadge status={String(invoice.issuance_status)} />
          <StatusBadge status={String(invoice.payment_status)} />
          <Link href="/carrier-invoices" className="inline-flex h-8 items-center rounded-sm border border-desktop-border px-3 text-[13px] font-medium hover:bg-muted">Back</Link>
        </div>
      </div>

      <DesktopPanel>
        <DesktopPanelHeader title="Invoice" />
        <DesktopPanelBody>
          <dl className="grid grid-cols-[auto,1fr] gap-x-6 gap-y-1 text-[13px]">
            <dt className="text-muted-foreground">Total</dt>
            <dd className="font-medium tabular-nums">{money(invoice.total_amount)} {String(invoice.currency)} (paid {money(invoice.amount_paid)})</dd>
            {invoice.issued_at && (<><dt className="text-muted-foreground">Issued</dt><dd>{new Date(String(invoice.issued_at)).toLocaleDateString()}</dd></>)}
            {invoice.due_date && (<><dt className="text-muted-foreground">Due</dt><dd>{new Date(String(invoice.due_date) + "T00:00:00").toLocaleDateString()}</dd></>)}
            <dt className="text-muted-foreground">Loads</dt>
            <dd>
              {loads.length === 0 ? "--" : loads.map((l, i) => (
                <span key={l.load_id}>{i > 0 ? ", " : ""}<Link href={`/loads/${l.load_id}`} className="hover:underline">{l.loads?.load_number ?? "load"}</Link> ({money(l.amount)})</span>
              ))}
            </dd>
          </dl>
          {invoice.issuance_status === "voided" && reissuedTo ? (
            <p role="status" className="mt-3 text-[12.5px]" data-testid="reissued-to">
              Voided and reissued: <Link className="underline" href={`/carrier-invoices/${reissuedTo.replacement_invoice_id}`}>replacement invoice</Link> (reason: {String(reissuedTo.reason)}). This original is preserved and can never be factored.
            </p>
          ) : null}
          {reissuedFrom ? (
            <p role="status" className="mt-3 text-[12.5px]" data-testid="reissued-from">
              Reissued from <Link className="underline" href={`/carrier-invoices/${reissuedFrom.original_invoice_id}`}>the original invoice</Link> (reason: {String(reissuedFrom.reason)}).
            </p>
          ) : null}
          {feeLink ? (
            <p className="mt-3 text-[12.5px]" data-testid="dispatch-fee-link">
              Dispatch-service fee: a separate receivable ({String(feeLink.disposition).replace("_", " ")}) --{" "}
              <Link className="underline" href={`/carrier-invoices/${feeLink.dispatch_invoice_id}`}>view the dispatch-service invoice</Link>
              . It is not part of this invoice and is never factored.
            </p>
          ) : (
            <p className="mt-3 text-[11.5px] text-muted-foreground">Your dispatch fee is a separate receivable: bill it to the carrier on a Dispatch Fee Invoice. It is never on this invoice and never factored.</p>
          )}
        </DesktopPanelBody>
      </DesktopPanel>

      <CarrierInvoiceLifecyclePanel invoiceId={id} updatedAt={String(invoice.updated_at)} actions={actions} issuePreview={issuePreview} reissuePreview={reissuePreview} />

      {invoice.invoice_document_type === "carrier_freight_invoice" && (
        <DesktopPanel>
          <DesktopPanelHeader title="Invoice package (for the factor)" />
          <DesktopPanelBody>
            {!issuedInv ? (
              <p className="text-[12.5px] text-muted-foreground">
                {invoice.issuance_status === "voided" ? "This invoice is void." : "Issue the invoice first. The package then contains the invoice plus each load's proof of delivery, rate confirmation and bill of lading."}
              </p>
            ) : (
              <div className="space-y-2.5 text-[12.5px]">
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
                        <Package className="size-4" /> View package
                      </a>
                      <a href={`/carrier-invoices/${id}/package?download=1`} className="inline-flex h-8 items-center rounded-sm border border-desktop-border px-3 text-[13px] font-medium hover:bg-muted">
                        Download package
                      </a>
                      <EmailCarrierButton label={lastSent ? "Email Again" : dest?.who === "factor_portal" ? "Email Package" : `Email to ${dest?.who === "factor" ? "Factor" : dest?.who === "broker" ? "Broker" : "Carrier"}`} />
                    </>
                  )}
                </div>
                {dest?.who === "factor_portal" && <p className="text-muted-foreground">This factor takes uploads on its website: download the package and upload it there (or email it to an address you type in).</p>}
                <p className="text-muted-foreground">
                  {lastSent ? `Emailed to ${lastSent.recipient} on ${new Date(lastSent.sent_at).toLocaleString()}.` : "Not emailed yet."}
                  {emails[0] && emails[0].status !== "sent" && <span className="text-danger"> Last attempt did not send: {emails[0].error ?? emails[0].status}.</span>}
                </p>
              </div>
            )}
          </DesktopPanelBody>
        </DesktopPanel>
      )}

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
