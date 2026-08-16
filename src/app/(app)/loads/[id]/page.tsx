import Link from "next/link";
import { notFound } from "next/navigation";
import { CheckCircle2, AlertTriangle } from "lucide-react";
import { createClient } from "@/lib/supabase/server";
import { deleteRecord } from "@/lib/actions/records";
import { FormCard } from "@/components/ui/form-card";
import { FormField, FormGrid, FormSelect, FormTextarea } from "@/components/ui/form-field";
import { StatusBadge } from "@/components/ui/status-badge";
import { Button } from "@/components/ui/button";
import { DocumentLinkButton } from "@/components/drivers/document-link-button";
import { RejectPodForm } from "@/components/loads/reject-pod-form";
import { SimpleDocumentSlot } from "@/components/loads/simple-document-slot";
import { LoadProfitabilitySection } from "@/components/loads/load-profitability-section";
import { LoadExpensesSection } from "@/components/loads/load-expenses-section";
import { LoadProfileSharingSection } from "@/components/loads/load-profile-sharing-section";
import { computePodStatus } from "@/lib/documents/pod-status";
import { getLatestDocument } from "@/lib/documents/latest-document";
import { updateLoad } from "../actions";
import { DesktopWorkspaceTabs } from "@/components/desktop/workspace-tabs";
import { DesktopCollapsibleSection, CollapsibleSectionsProvider, CollapsibleSectionsToolbar } from "@/components/desktop/collapsible-section";
import { uploadPod, verifyPod, getPodSignedUrl } from "../pod-actions";

// Load Information/Stops/Dispatch are the most operationally important --
// open by default. Everything else (documents, financials, sharing,
// history) starts collapsed. Purely a display preference: every section's
// underlying data is still fetched exactly as before (spec section 18 --
// no new queries, no lazy-fetch). Section ids are also the localStorage
// persistence keys (see CollapsibleSectionsProvider's storageKey below) --
// keep them stable if this list ever changes.
const SECTION_DEFAULTS: Record<string, boolean> = {
  load_info: true,
  stops: true,
  dispatch: true,
  pod: false,
  billing_documents: false,
  profitability: false,
  expenses: false,
  profile_sharing: false,
  invoice: false,
};

const POD_BADGE_LABEL: Record<string, string> = {
  missing: "Missing",
  uploaded: "Uploaded",
  verified: "Verified",
  rejected: "Rejected",
};

export default async function LoadDetailPage({
  params,
  searchParams,
}: {
  params: Promise<{ id: string }>;
  searchParams: Promise<{ delivered?: string; rate_con_upload_failed?: string }>;
}) {
  const { id } = await params;
  const { delivered, rate_con_upload_failed } = await searchParams;
  const supabase = await createClient();

  const [{ data: load }, { data: brokers }, { data: customers }, { data: stops }, { data: dispatch }, { data: invoice }] =
    await Promise.all([
      supabase.from("loads").select("*").eq("id", id).single(),
      supabase.from("brokers").select("id, company_name").order("company_name"),
      supabase.from("customers").select("id, company_name").order("company_name"),
      supabase
        .from("load_stops")
        .select("id, stop_type, stop_sequence, facility_name, city, state, scheduled_at")
        .eq("load_id", id)
        .order("stop_sequence"),
      supabase
        .from("dispatches")
        .select("id, status, carriers(legal_name), trucks(unit_number), drivers(first_name, last_name)")
        .eq("load_id", id)
        .maybeSingle(),
      // Auto-generated on delivery by the auto_generate_invoice_on_delivery
      // trigger (0022_auto_invoice_on_delivery.sql) -- at most one per load,
      // enforced by a partial unique index on invoices.load_id.
      supabase
        .from("invoices")
        .select("id, invoice_number, status, total_amount, amount_paid, balance_due, issue_date, due_date")
        .eq("load_id", id)
        .maybeSingle(),
    ]);
  if (!load) notFound();

  // POD status is always derived from this row (or its absence) -- see
  // src/lib/documents/pod-status.ts. Most recent one wins if a rejected POD
  // was replaced (the old row is kept for history, never edited in place).
  const [pod, rateConDoc, bolDoc, lumperDoc, detentionDoc, scaleTicketDoc, otherDoc] = await Promise.all([
    getLatestDocument(supabase, "load", id, "pod"),
    getLatestDocument(supabase, "load", id, "rate_confirmation"),
    getLatestDocument(supabase, "load", id, "bol"),
    getLatestDocument(supabase, "load", id, "lumper_receipt"),
    getLatestDocument(supabase, "load", id, "detention_document"),
    getLatestDocument(supabase, "load", id, "scale_ticket"),
    getLatestDocument(supabase, "load", id, "other"),
  ]);
  const podStatus = computePodStatus(pod);

  let uploadedByName: string | null = null;
  if (pod?.uploaded_by) {
    const { data: uploader } = await supabase.from("profiles").select("full_name").eq("id", pod.uploaded_by).maybeSingle();
    uploadedByName = uploader?.full_name ?? null;
  }

  const dispatchInfo = dispatch as unknown as
    | {
        id: string;
        status: string;
        carriers: { legal_name: string } | null;
        trucks: { unit_number: string } | null;
        drivers: { first_name: string; last_name: string } | null;
      }
    | null;

  // Header-only summary values (spec section 10) -- every one of these
  // reads data already fetched above; nothing here computes a new business
  // value or re-derives something a canonical source (e.g. profitability
  // RPCs) already owns.
  const billingDocsOnFile = [rateConDoc, bolDoc, lumperDoc, detentionDoc, scaleTicketDoc, otherDoc].filter(Boolean).length;

  return (
    <div className="space-y-3">
      <DesktopWorkspaceTabs tabs={[{ label: "Loads", href: "/loads" }, { label: load.load_number, href: `/loads/${id}` }]} />
      {rate_con_upload_failed === "1" && (
        <div className="flex items-center gap-2 rounded-xl border border-warning/30 bg-warning/5 px-4 py-3 text-sm">
          <AlertTriangle className="size-4 shrink-0 text-warning" />
          Load created successfully, but the Rate Confirmation file did not upload. Try again below in Billing Documents.
        </div>
      )}
      {delivered === "1" && (
        <div className="flex flex-wrap items-center justify-between gap-3 rounded-xl border border-success/30 bg-success/5 px-4 py-3">
          <p className="flex items-center gap-2 text-sm">
            <CheckCircle2 className="size-4 shrink-0 text-success" />
            {invoice ? (
              <>
                Load marked delivered. Invoice <span className="font-semibold">{invoice.invoice_number}</span> has been created.
              </>
            ) : (
              "Load marked delivered. No invoice was created automatically -- add a broker or customer to this load, then create one manually."
            )}
          </p>
          {invoice && (
            <div className="flex shrink-0 items-center gap-2">
              <Link
                href={`/invoices/${invoice.id}`}
                className="rounded-lg bg-primary px-3 py-1.5 text-xs font-medium text-primary-foreground hover:bg-primary-hover"
              >
                View Invoice
              </Link>
              <Link
                href={`/invoices/${invoice.id}/pdf`}
                target="_blank"
                className="rounded-lg border border-border bg-card px-3 py-1.5 text-xs font-medium hover:bg-muted"
              >
                Download PDF
              </Link>
              <Link href={`/loads/${id}`} className="rounded-lg px-3 py-1.5 text-xs font-medium text-muted-foreground hover:bg-muted">
                Back to Load
              </Link>
            </div>
          )}
        </div>
      )}

      <CollapsibleSectionsProvider defaults={SECTION_DEFAULTS} storageKey="load-detail-section-state">
        <div className="flex justify-end">
          <CollapsibleSectionsToolbar />
        </div>

        <div className="space-y-3">
          <DesktopCollapsibleSection id="load_info" title={`${load.load_number} / Load Information`}>
            <FormCard
              title={load.load_number}
              description="Load profile. Changes save immediately."
              action={updateLoad.bind(null, id)}
              cancelHref="/loads"
              deleteAction={deleteRecord.bind(null, "loads", id, "/loads")}
            >
              <FormGrid>
                <FormField label="Load number" name="load_number" defaultValue={load.load_number} required />
                <FormSelect
                  label="Status"
                  name="status"
                  defaultValue={load.status}
                  options={[
                    { value: "draft", label: "Draft" },
                    { value: "posted", label: "Posted" },
                    { value: "booked", label: "Booked" },
                    { value: "dispatched", label: "Dispatched" },
                    { value: "in_transit", label: "In Transit" },
                    { value: "delivered", label: "Delivered" },
                    { value: "invoiced", label: "Invoiced" },
                    { value: "closed", label: "Closed" },
                    { value: "cancelled", label: "Cancelled" },
                    { value: "problem", label: "Problem" },
                  ]}
                />
                <FormSelect
                  label="Broker"
                  name="broker_id"
                  defaultValue={load.broker_id}
                  options={(brokers ?? []).map((b) => ({ value: b.id, label: b.company_name }))}
                />
                <FormSelect
                  label="Customer"
                  name="customer_id"
                  defaultValue={load.customer_id}
                  options={(customers ?? []).map((c) => ({ value: c.id, label: c.company_name }))}
                />
                <FormField label="Commodity" name="commodity" defaultValue={load.commodity} />
                <FormField label="Weight (lbs)" name="weight_lbs" type="number" defaultValue={load.weight_lbs} />
                <FormSelect
                  label="Equipment type"
                  name="equipment_type"
                  defaultValue={load.equipment_type}
                  options={[
                    { value: "dry_van", label: "Dry Van" },
                    { value: "reefer", label: "Reefer" },
                    { value: "flatbed", label: "Flatbed" },
                    { value: "step_deck", label: "Step Deck" },
                    { value: "lowboy", label: "Lowboy" },
                    { value: "tanker", label: "Tanker" },
                    { value: "other", label: "Other" },
                  ]}
                />
                <FormField label="Total miles" name="total_miles" type="number" step="0.1" defaultValue={load.total_miles} />
                <FormField label="Rate ($)" name="rate" type="number" step="0.01" defaultValue={load.rate} required />
                <FormField label="Rate confirmation #" name="rate_confirmation_number" defaultValue={load.rate_confirmation_number} />
                <FormTextarea label="Special instructions" name="special_instructions" defaultValue={load.special_instructions} />
              </FormGrid>
            </FormCard>
          </DesktopCollapsibleSection>

          <div className="grid grid-cols-1 gap-3 md:grid-cols-2">
            <DesktopCollapsibleSection id="stops" title="Stops" badge={stops && stops.length > 0 ? stops.length : undefined}>
              {!stops || stops.length === 0 ? (
                <p className="text-sm text-[var(--color-text-muted)]">No stops added yet.</p>
              ) : (
                <ul className="space-y-2">
                  {stops.map((stop) => (
                    <li key={stop.id} className="flex items-center justify-between text-sm">
                      <span className="flex items-center gap-2">
                        <span
                          className={`rounded-sm px-1.5 py-0.5 text-[10px] font-semibold uppercase tracking-wide ${
                            stop.stop_type === "pickup" ? "bg-primary/10 text-primary" : "bg-desktop-success/15 text-desktop-success"
                          }`}
                        >
                          {stop.stop_type} {stop.stop_sequence}
                        </span>
                        {stop.facility_name ?? "Unnamed facility"}
                      </span>
                      <span className="text-right text-[var(--color-text-muted)]">
                        <span className="block">{stop.city}, {stop.state}</span>
                        {stop.scheduled_at && <span className="block text-xs">{new Date(stop.scheduled_at).toLocaleString(undefined, { dateStyle: "medium", timeStyle: "short" })}</span>}
                      </span>
                    </li>
                  ))}
                </ul>
              )}
            </DesktopCollapsibleSection>

            <DesktopCollapsibleSection id="dispatch" title="Dispatch" badge={dispatchInfo ? dispatchInfo.status.replace(/_/g, " ") : undefined}>
              {!dispatchInfo ? (
                <div className="space-y-2">
                  <p className="text-sm text-[var(--color-text-muted)]">Not yet dispatched.</p>
                  <Link
                    href={`/dispatch/new?load_id=${load.id}`}
                    className="inline-flex items-center gap-1.5 rounded-lg bg-primary px-3 py-1.5 text-sm font-medium text-primary-foreground hover:bg-primary-hover"
                  >
                    Create Dispatch
                  </Link>
                </div>
              ) : (
                <div className="space-y-1 text-sm">
                  <p>Carrier: {dispatchInfo.carriers?.legal_name ?? "--"}</p>
                  <p>Truck: {dispatchInfo.trucks?.unit_number ?? "--"}</p>
                  <p>
                    Driver:{" "}
                    {dispatchInfo.drivers
                      ? `${dispatchInfo.drivers.first_name} ${dispatchInfo.drivers.last_name}`
                      : "--"}
                  </p>
                  <p className="flex items-center gap-2">
                    Status: <StatusBadge status={dispatchInfo.status} />
                  </p>
                  <Link href={`/dispatch/${dispatchInfo.id}`} className="inline-block text-xs font-medium text-[var(--color-brand)]">
                    View dispatch &rarr;
                  </Link>
                </div>
              )}
            </DesktopCollapsibleSection>
          </div>

          <DesktopCollapsibleSection
            id="pod"
            title="Proof of Delivery"
            badge={POD_BADGE_LABEL[podStatus]}
            badgeTone={podStatus === "missing" || podStatus === "rejected" ? "warning" : "neutral"}
          >
            {podStatus === "missing" && (
              <div className="space-y-2">
                <p className="flex items-center gap-2 text-sm">
                  <StatusBadge status="missing" /> No POD on file yet.
                </p>
                <form action={uploadPod.bind(null, id)} className="flex flex-wrap items-center gap-2">
                  <input
                    type="file"
                    name="file"
                    accept=".pdf,.jpg,.jpeg,.png"
                    required
                    className="text-xs text-[var(--color-text-muted)] file:mr-2 file:rounded-md file:border-0 file:bg-primary file:px-3 file:py-1.5 file:text-xs file:font-medium file:text-primary-foreground"
                  />
                  <Button type="submit" size="sm">
                    Upload POD
                  </Button>
                </form>
              </div>
            )}

            {pod && podStatus !== "missing" && (
              <div className="space-y-2">
                <p className="flex items-center gap-2 text-sm">
                  <StatusBadge status={podStatus} />
                  <span className="text-[var(--color-text-muted)]">{pod.file_name}</span>
                </p>
                <p className="text-xs text-[var(--color-text-muted)]">
                  Uploaded {new Date(pod.created_at).toLocaleString()}
                  {uploadedByName && ` by ${uploadedByName}`}
                </p>

                {podStatus === "rejected" && pod.rejection_reason && (
                  <p className="flex items-start gap-1.5 rounded-md border border-danger/30 bg-danger/5 px-2.5 py-1.5 text-xs text-danger">
                    <AlertTriangle className="mt-0.5 size-3.5 shrink-0" />
                    Rejected: {pod.rejection_reason}
                  </p>
                )}

                <div className="flex flex-wrap items-center gap-2">
                  <DocumentLinkButton label="View" getUrl={getPodSignedUrl.bind(null, pod.file_path, false)} />
                  <DocumentLinkButton label="Download" getUrl={getPodSignedUrl.bind(null, pod.file_path, true)} />

                  {podStatus === "uploaded" && (
                    <>
                      <form action={verifyPod.bind(null, pod.id, id)}>
                        <Button type="submit" size="sm" variant="success">
                          Verify
                        </Button>
                      </form>
                      <RejectPodForm documentId={pod.id} loadId={id} />
                    </>
                  )}
                </div>

                {podStatus === "rejected" && (
                  <form action={uploadPod.bind(null, id)} className="flex flex-wrap items-center gap-2 border-t border-[var(--color-border)] pt-2">
                    <input
                      type="file"
                      name="file"
                      accept=".pdf,.jpg,.jpeg,.png"
                      required
                      className="text-xs text-[var(--color-text-muted)] file:mr-2 file:rounded-md file:border-0 file:bg-primary file:px-3 file:py-1.5 file:text-xs file:font-medium file:text-primary-foreground"
                    />
                    <Button type="submit" size="sm">
                      Replace POD
                    </Button>
                  </form>
                )}
              </div>
            )}
          </DesktopCollapsibleSection>

          <DesktopCollapsibleSection id="billing_documents" title="Billing Documents" badge={billingDocsOnFile > 0 ? `${billingDocsOnFile} on file` : undefined}>
            <p className="text-xs text-[var(--color-text-muted)]">
              Optional supporting documents for the billing packet. POD is managed separately above and is the only one
              that requires verification.
            </p>
            <div className="mt-3">
              <SimpleDocumentSlot loadId={id} documentType="rate_confirmation" label="Rate Confirmation" doc={rateConDoc} />
              <SimpleDocumentSlot loadId={id} documentType="bol" label="Bill of Lading" doc={bolDoc} />
              <SimpleDocumentSlot loadId={id} documentType="lumper_receipt" label="Lumper Receipt" doc={lumperDoc} />
              <SimpleDocumentSlot loadId={id} documentType="detention_document" label="Detention Documentation" doc={detentionDoc} />
              <SimpleDocumentSlot loadId={id} documentType="scale_ticket" label="Scale Ticket" doc={scaleTicketDoc} />
              <SimpleDocumentSlot loadId={id} documentType="other" label="Other" doc={otherDoc} />
            </div>
          </DesktopCollapsibleSection>

          <LoadProfitabilitySection loadId={id} />
          <LoadExpensesSection loadId={id} />
          <LoadProfileSharingSection loadId={id} />

          <DesktopCollapsibleSection
            id="invoice"
            title="Invoice"
            badge={invoice ? `${invoice.invoice_number} · ${invoice.status.replace(/_/g, " ")}` : undefined}
          >
            {!invoice ? (
              <div className="space-y-2">
                <p className="text-sm text-[var(--color-text-muted)]">
                  {load.status === "delivered"
                    ? "No invoice on file -- this load has no broker or customer set, so one couldn't be generated automatically. Set one, or create an invoice manually."
                    : "An invoice is created automatically once this load is marked Delivered. You can also create one manually now."}
                </p>
                <Link
                  href={`/invoices/new?load_id=${id}`}
                  className="inline-flex h-7 items-center rounded-sm bg-primary px-2.5 text-xs font-medium text-primary-foreground hover:bg-primary-hover"
                >
                  Create Invoice
                </Link>
              </div>
            ) : (
              <div className="space-y-2">
                {podStatus !== "verified" && invoice.status === "draft" && (
                  <p className="flex items-start gap-1.5 rounded-md border border-warning/30 bg-warning/5 px-2.5 py-1.5 text-xs text-warning">
                    <AlertTriangle className="mt-0.5 size-3.5 shrink-0" />
                    Proof of Delivery required before invoice can be sent.
                  </p>
                )}
                {invoice.status !== "draft" && (
                  <p className="flex items-start gap-1.5 rounded-md border border-warning/30 bg-warning/5 px-2.5 py-1.5 text-xs text-warning">
                    <AlertTriangle className="mt-0.5 size-3.5 shrink-0" />
                    This invoice has already been {invoice.status.replace(/_/g, " ")}. Changing this load&apos;s rate will
                    not update it automatically -- edit the invoice directly if it needs correcting.
                  </p>
                )}
                <div className="grid grid-cols-2 gap-x-3 gap-y-1 text-sm">
                  <span className="text-[var(--color-text-muted)]">Invoice #</span>
                  <span className="text-right font-medium">{invoice.invoice_number}</span>
                  <span className="text-[var(--color-text-muted)]">Total</span>
                  <span className="text-right">${Number(invoice.total_amount).toLocaleString()}</span>
                  <span className="text-[var(--color-text-muted)]">Status</span>
                  <span className="text-right">
                    <StatusBadge status={invoice.status} />
                  </span>
                  <span className="text-[var(--color-text-muted)]">Balance</span>
                  <span className="text-right font-medium">${Number(invoice.balance_due).toLocaleString()}</span>
                  <span className="text-[var(--color-text-muted)]">Due Date</span>
                  <span className="text-right">{invoice.due_date ? new Date(invoice.due_date + "T00:00:00").toLocaleDateString() : "--"}</span>
                  <span className="text-[var(--color-text-muted)]">Payment Terms</span>
                  {/* Derived display only, from the two dates already frozen on
                      the invoice at generation time -- never a live lookup of
                      the broker/customer's CURRENT terms, so this can never
                      silently change if their terms are edited later. */}
                  <span className="text-right">
                    {invoice.issue_date && invoice.due_date
                      ? `Net ${Math.round((new Date(invoice.due_date).getTime() - new Date(invoice.issue_date).getTime()) / 86400000)}`
                      : "--"}
                  </span>
                </div>
                <Link href={`/invoices/${invoice.id}`} className="inline-block text-xs font-medium text-[var(--color-brand)]">
                  View invoice &rarr;
                </Link>
              </div>
            )}
          </DesktopCollapsibleSection>
        </div>
      </CollapsibleSectionsProvider>
    </div>
  );
}
