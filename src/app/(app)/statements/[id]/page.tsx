import Link from "next/link";
import { notFound } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { DesktopPanel, DesktopPanelHeader, DesktopPanelBody } from "@/components/desktop/panel";
import { StatusBadge } from "@/components/ui/status-badge";
import { DocumentLinkButton } from "@/components/drivers/document-link-button";
import { getStatementSignedUrl } from "../actions";
import { RegisterDesktopActions } from "@/components/desktop/actions-context";

const AGING_LABELS: Record<string, string> = { current: "Current", "1_30": "1-30 Days", "31_60": "31-60 Days", "61_90": "61-90 Days", "90_plus": "90+ Days" };

function money(n: number): string {
  return `$${Number(n).toLocaleString(undefined, { minimumFractionDigits: 2 })}`;
}

// Renders straight from the persisted snapshot (opening/closing balance,
// aging, included invoice/payment ids/totals) -- never re-queries live
// invoices/payments -- so a previously-generated statement always shows
// exactly what was true when it was generated, even if invoices/payments
// have since changed.
export default async function StatementDetailPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const supabase = await createClient();

  const { data: statement } = await supabase
    .from("statements")
    .select(
      "id, statement_number, party_type, statement_type, period_start, period_end, as_of_date, opening_balance, closing_balance, status, storage_path, snapshot, generated_at, sent_at, recipient_email, brokers(id, company_name), customers(id, company_name)"
    )
    .eq("id", id)
    .single();
  if (!statement) notFound();

  const row = statement as unknown as {
    id: string;
    statement_number: string;
    party_type: string;
    statement_type: string;
    period_start: string | null;
    period_end: string | null;
    as_of_date: string;
    opening_balance: number;
    closing_balance: number;
    status: string;
    storage_path: string | null;
    snapshot: { included_invoice_ids?: string[]; included_payment_references?: string[]; period_charges?: number; period_payments?: number; aging?: Record<string, number> };
    generated_at: string;
    sent_at: string | null;
    recipient_email: string | null;
    brokers: { id: string; company_name: string } | null;
    customers: { id: string; company_name: string } | null;
  };
  const partyName = row.brokers?.company_name ?? row.customers?.company_name ?? "--";
  const partyHref = row.brokers ? `/brokers/${row.brokers.id}` : row.customers ? `/customers/${row.customers.id}` : null;
  const aging = row.snapshot?.aging ?? {};

  return (
    <div className="space-y-3">
      <RegisterDesktopActions
        title={`Statement ${row.statement_number}`}
        printHref={row.storage_path ? `/statements/${id}/pdf` : undefined}
        exportOptions={row.storage_path ? [{ label: "Export PDF", href: `/statements/${id}/pdf?download=1` }] : []}
        exportDisabledReason="No generated PDF yet for this statement."
        email={row.storage_path ? { entityType: "statement", entityId: id } : undefined}
        emailDisabledReason={row.storage_path ? undefined : "No generated PDF yet for this statement."}
      />
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-[15px] font-semibold tracking-tight text-desktop-text">{row.statement_number}</h1>
          <p className="mt-0.5 text-xs text-muted-foreground">
            {partyHref ? (
              <Link href={partyHref} className="text-primary hover:underline">
                {partyName}
              </Link>
            ) : (
              partyName
            )}{" "}
            -- {row.statement_type.replace("_", " ")} statement, generated {new Date(row.generated_at).toLocaleDateString()}
          </p>
        </div>
        <div className="flex items-center gap-2">
          <Link href="/statements" className="inline-flex h-8 items-center rounded-sm border border-desktop-border px-3 text-[13px] font-medium hover:bg-muted">
            Back to Statements
          </Link>
          {row.storage_path && (
            <>
              <DocumentLinkButton label="View PDF" getUrl={getStatementSignedUrl.bind(null, row.storage_path, false)} />
              <DocumentLinkButton label="Download PDF" getUrl={getStatementSignedUrl.bind(null, row.storage_path, true)} />
            </>
          )}
        </div>
      </div>

      <DesktopPanel>
        <DesktopPanelHeader title="Summary" actions={<StatusBadge status={row.status} />} />
        <DesktopPanelBody>
          <div className="grid grid-cols-2 gap-x-4 gap-y-2 text-[13px] sm:grid-cols-4">
            <Field label="Statement Type" value={row.statement_type.replace("_", " ")} />
            <Field label={row.statement_type === "period" ? "Period" : "As Of"} value={row.statement_type === "period" ? `${new Date(row.period_start! + "T00:00:00").toLocaleDateString()} - ${new Date(row.period_end! + "T00:00:00").toLocaleDateString()}` : new Date(row.as_of_date + "T00:00:00").toLocaleDateString()} />
            <Field label="Opening Balance" value={money(row.opening_balance)} />
            <Field label="Closing Balance" value={money(row.closing_balance)} strong />
            {row.statement_type === "period" && <Field label="Period Charges" value={money(row.snapshot?.period_charges ?? 0)} />}
            {row.statement_type === "period" && <Field label="Period Payments" value={money(row.snapshot?.period_payments ?? 0)} />}
            <Field label="Invoices Included" value={String(row.snapshot?.included_invoice_ids?.length ?? 0)} />
            <Field label="Sent" value={row.sent_at ? new Date(row.sent_at).toLocaleDateString() : "Not sent"} />
          </div>
        </DesktopPanelBody>
      </DesktopPanel>

      {Object.keys(aging).length > 0 && (
        <DesktopPanel>
          <DesktopPanelHeader title="Aging Summary (at generation time)" />
          <DesktopPanelBody>
            <div className="grid grid-cols-5 gap-3 text-[12.5px]">
              {(["current", "bucket_1_30", "bucket_31_60", "bucket_61_90", "bucket_90_plus"] as const).map((key) => (
                <div key={key}>
                  <p className="text-[10.5px] font-semibold uppercase tracking-wide text-muted-foreground">{AGING_LABELS[key.replace("bucket_", "")]}</p>
                  <p className="mt-1 font-semibold text-desktop-text tabular-nums">{money(aging[key] ?? 0)}</p>
                </div>
              ))}
            </div>
          </DesktopPanelBody>
        </DesktopPanel>
      )}
    </div>
  );
}

function Field({ label, value, strong }: { label: string; value: string; strong?: boolean }) {
  return (
    <div>
      <p className="text-[10.5px] font-medium uppercase tracking-wide text-muted-foreground">{label}</p>
      <p className={strong ? "font-semibold text-primary" : "font-medium capitalize text-desktop-text"}>{value}</p>
    </div>
  );
}
