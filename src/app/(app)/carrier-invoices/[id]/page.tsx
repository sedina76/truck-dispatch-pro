import Link from "next/link";
import { notFound } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { CarrierInvoiceFactoringPanel } from "@/components/carrier-invoices/carrier-invoice-factoring-panel";
import { CarrierInvoiceLifecyclePanel } from "@/components/carrier-invoices/carrier-invoice-lifecycle-panel";
import { lifecycleActions, type IssuancePreview } from "@/lib/factoring/carrier-invoice-issuance";
import { getCarrierInvoiceFactoringPreview } from "../factoring-actions";
import { previewCarrierInvoiceIssuance, previewCarrierInvoiceReissue } from "../issuance-actions";

// Proposals 0157 (D-57): carrier-invoice detail with the lifecycle (mark ready / issue / discard / reissue) and the factoring section. Carrier invoices are a different table from the LEGACY `invoices` (which
// are never offered for factoring). The invoice is read through the caller's own RLS-scoped session; every preview comes from the database (organization, role, carrier grant, billing mode and relationship are all
// resolved there). The factoring panel exists ONLY for a correctly ISSUED freight invoice; drift directs the user to the controlled reissue workflow.
export default async function CarrierInvoiceDetailPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const supabase = await createClient();
  const { data: invoice } = await supabase
    .from("carrier_invoices")
    .select("id, invoice_number, invoice_document_type, issuance_status, payment_status, currency, total_amount, amount_paid, issued_at, due_date, carrier_id, updated_at, recipient_type, recipient_broker_id, recipient_customer_id, void_reason")
    .eq("id", id)
    .maybeSingle();
  if (!invoice) notFound();

  const {
    data: { user },
  } = await supabase.auth.getUser();
  const { data: profile } = user ? await supabase.from("profiles").select("role").eq("id", user.id).maybeSingle() : { data: null };
  const role = String(profile?.role ?? "");

  const { data: ledger } = await supabase.from("carrier_invoice_billable_ledger_0157").select("load_id").eq("invoice_id", id).is("released_at", null);
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

  return (
    <div className="mx-auto max-w-3xl space-y-4 p-4">
      <h1 className="text-xl font-semibold">Carrier invoice {invoice.invoice_number ?? "(draft)"}</h1>
      <dl className="grid grid-cols-[auto,1fr] gap-x-4 gap-y-1 text-sm">
        <dt className="text-muted-foreground">Type</dt>
        <dd>{String(invoice.invoice_document_type)}</dd>
        <dt className="text-muted-foreground">Status</dt>
        <dd>
          {String(invoice.issuance_status)} / {String(invoice.payment_status)}
        </dd>
        <dt className="text-muted-foreground">Total</dt>
        <dd>
          {String(invoice.currency)} {Number(invoice.total_amount).toFixed(2)} (paid {Number(invoice.amount_paid).toFixed(2)})
        </dd>
      </dl>
      {invoice.issuance_status === "voided" && reissuedTo ? (
        <p role="status" className="text-sm" data-testid="reissued-to">
          Voided and reissued: <Link className="underline" href={`/carrier-invoices/${reissuedTo.replacement_invoice_id}`}>replacement invoice</Link> (reason: {String(reissuedTo.reason)}). This original is preserved and can never be factored.
        </p>
      ) : null}
      {reissuedFrom ? (
        <p role="status" className="text-sm" data-testid="reissued-from">
          Reissued from <Link className="underline" href={`/carrier-invoices/${reissuedFrom.original_invoice_id}`}>the original invoice</Link> (reason: {String(reissuedFrom.reason)}).
        </p>
      ) : null}
      {feeLink ? (
        <p className="text-sm" data-testid="dispatch-fee-link">
          Dispatch-service fee: a separate receivable ({String(feeLink.disposition).replace("_", " ")}) --{" "}
          <Link className="underline" href={`/carrier-invoices/${feeLink.dispatch_invoice_id}`}>
            view the dispatch-service invoice
          </Link>
          . It is not part of this invoice and is never factored.
        </p>
      ) : null}
      <CarrierInvoiceLifecyclePanel invoiceId={id} updatedAt={String(invoice.updated_at)} actions={actions} issuePreview={issuePreview} reissuePreview={reissuePreview} />
      {actions.factoringPanel ? <CarrierInvoiceFactoringPanel carrierInvoiceId={id} preview={factoringPreview} /> : null}
      {(submissions ?? []).length > 0 ? (
        <section aria-labelledby="fs-heading">
          <h2 id="fs-heading" className="text-base font-semibold">
            Factoring submissions
          </h2>
          <ul className="text-sm">
            {(submissions ?? []).map((s) => (
              <li key={s.id}>
                {String(s.status)} -- {String(s.submitted_at)}
              </li>
            ))}
          </ul>
        </section>
      ) : null}
    </div>
  );
}
