import Link from "next/link";
import { notFound } from "next/navigation";
import { AlertTriangle, Receipt } from "lucide-react";
import { createClient } from "@/lib/supabase/server";
import { DesktopWorkspaceTabs } from "@/components/desktop/workspace-tabs";
import { DesktopPanel, DesktopPanelHeader, DesktopPanelBody } from "@/components/desktop/panel";
import { DesktopKpiStrip, DesktopKpiBox } from "@/components/desktop/kpi-box";
import { StatusBadge } from "@/components/ui/status-badge";
import { Button } from "@/components/ui/button";
import { DocumentLinkButton } from "@/components/drivers/document-link-button";
import { RegisterDesktopActions } from "@/components/desktop/actions-context";
import { submitExpense, approveExpense, markExpensePaid, voidExpense, uploadExpenseReceipt, getExpenseReceiptSignedUrl } from "../actions";

function money(n: number): string {
  return `$${Number(n).toLocaleString(undefined, { minimumFractionDigits: 2 })}`;
}

export default async function ExpenseDetailPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const supabase = await createClient();

  const { data: row } = await supabase
    .from("expenses")
    .select(
      `id, expense_number, expense_date, scope, category, amount, tax_amount, total_amount, vendor_name, description,
       notes, payment_method, reference_number, billable_to_customer, status, receipt_document_id,
       load_id, dispatch_id, truck_id, trailer_id, driver_id, carrier_id,
       approved_at, approved_by, paid_at, paid_by, voided_at, voided_by, void_reason, created_at,
       loads(load_number), trucks(unit_number), trailers(unit_number), drivers(first_name, last_name), carriers(legal_name),
       recorded:profiles!expenses_recorded_by_fkey(full_name),
       approver:profiles!expenses_approved_by_fkey(full_name),
       payer:profiles!expenses_paid_by_fkey(full_name),
       voider:profiles!expenses_voided_by_fkey(full_name),
       receipt:documents!expenses_receipt_document_id_fkey(id, file_path, file_name, document_type)`
    )
    .eq("id", id)
    .single();
  if (!row) notFound();

  const {
    data: { user },
  } = await supabase.auth.getUser();
  const { data: profile } = await supabase.from("profiles").select("role").eq("id", user!.id).single();
  const canApprove = ["owner", "admin", "accountant"].includes(profile?.role ?? "");

  const r = row as unknown as {
    expense_number: string; expense_date: string; scope: string; category: string;
    amount: number; tax_amount: number; total_amount: number; vendor_name: string | null; description: string | null;
    notes: string | null; payment_method: string | null; reference_number: string | null; billable_to_customer: boolean;
    status: string; receipt_document_id: string | null;
    load_id: string | null; dispatch_id: string | null; truck_id: string | null; trailer_id: string | null; driver_id: string | null; carrier_id: string | null;
    approved_at: string | null; paid_at: string | null; voided_at: string | null; void_reason: string | null; created_at: string;
    loads: { load_number: string } | null; trucks: { unit_number: string } | null; trailers: { unit_number: string } | null;
    drivers: { first_name: string; last_name: string } | null; carriers: { legal_name: string } | null;
    recorded: { full_name: string } | null; approver: { full_name: string } | null; payer: { full_name: string } | null; voider: { full_name: string } | null;
    receipt: { id: string; file_path: string; file_name: string; document_type: string } | null;
  };

  const isDraft = r.status === "draft" || r.status === "submitted";
  const isVoid = r.status === "void";

  return (
    <div className="space-y-3">
      <DesktopWorkspaceTabs tabs={[{ label: "Expenses", href: "/expenses" }, { label: r.expense_number, href: `/expenses/${id}` }]} />
      <RegisterDesktopActions title={`Expense ${r.expense_number}`} printInPlace exportDisabledReason="Open the Expenses list to export this record via CSV." />

      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-[15px] font-semibold tracking-tight text-desktop-text">{r.expense_number}</h1>
          <p className="mt-0.5 text-xs text-muted-foreground">
            {r.vendor_name ?? "No vendor"} &middot; {new Date(r.expense_date + "T00:00:00").toLocaleDateString()}
          </p>
        </div>
        <StatusBadge status={r.status} />
      </div>

      {isVoid && r.void_reason && (
        <div className="flex items-start gap-2 rounded-sm border border-danger/30 bg-danger/5 px-3 py-2 text-sm text-danger">
          <AlertTriangle className="mt-0.5 size-4 shrink-0" />
          Voided: {r.void_reason} ({r.voider?.full_name ?? "unknown"}, {r.voided_at ? new Date(r.voided_at).toLocaleString() : ""})
        </div>
      )}

      <DesktopKpiStrip>
        <DesktopKpiBox label="Amount" value={money(r.amount)} />
        <DesktopKpiBox label="Tax" value={money(r.tax_amount)} />
        <DesktopKpiBox label="Total" value={money(r.total_amount)} tone="primary" />
        <DesktopKpiBox label="Scope" value={r.scope} />
        <DesktopKpiBox label="Category" value={r.category.replace(/_/g, " ")} />
      </DesktopKpiStrip>

      <DesktopPanel>
        <DesktopPanelHeader
          title="Details"
          actions={
            <div className="flex items-center gap-1.5">
              {r.status === "draft" && <form action={submitExpense.bind(null, id)}><button className="rounded-sm bg-white/10 px-2 py-1 text-[11px] font-medium text-white hover:bg-white/20">Submit</button></form>}
              {canApprove && (r.status === "draft" || r.status === "submitted") && (
                <form action={approveExpense.bind(null, id)}><button className="rounded-sm bg-white/10 px-2 py-1 text-[11px] font-medium text-white hover:bg-white/20">Approve</button></form>
              )}
            </div>
          }
        />
        <DesktopPanelBody>
          <div className="grid grid-cols-2 gap-x-4 gap-y-2 text-[13px] sm:grid-cols-4">
            <Field label="Description" value={r.description ?? "--"} />
            <Field label="Payment Method" value={r.payment_method ?? "--"} />
            <Field label="Reference #" value={r.reference_number ?? "--"} />
            <Field label="Billable to Customer" value={r.billable_to_customer ? "Yes -- invoice separately, not netted here" : "No"} />
            <Field label="Load" value={r.loads ? r.loads.load_number : "--"} href={r.load_id ? `/loads/${r.load_id}` : undefined} />
            <Field label="Truck" value={r.trucks?.unit_number ?? "--"} href={r.truck_id ? `/trucks/${r.truck_id}` : undefined} />
            <Field label="Trailer" value={r.trailers?.unit_number ?? "--"} />
            <Field label="Driver" value={r.drivers ? `${r.drivers.first_name} ${r.drivers.last_name}` : "--"} href={r.driver_id ? `/drivers/${r.driver_id}` : undefined} />
            <Field label="Carrier" value={r.carriers?.legal_name ?? "--"} href={r.carrier_id ? `/carriers/${r.carrier_id}` : undefined} />
            <Field label="Created By" value={r.recorded?.full_name ?? "--"} />
            <Field label="Approved" value={r.approver ? `${r.approver.full_name}, ${new Date(r.approved_at!).toLocaleDateString()}` : "--"} />
            <Field label="Paid" value={r.payer ? `${r.payer.full_name}, ${new Date(r.paid_at!).toLocaleDateString()}` : "--"} />
          </div>
          {r.notes && <p className="mt-3 border-t border-desktop-border pt-3 text-[13px] text-muted-foreground">{r.notes}</p>}
        </DesktopPanelBody>
      </DesktopPanel>

      <DesktopPanel>
        <DesktopPanelHeader title="Receipt" />
        <DesktopPanelBody>
          {r.receipt ? (
            <div className="flex items-center gap-2">
              <Receipt className="size-4 text-primary" />
              <span className="text-[13px]">{r.receipt.file_name}</span>
              <DocumentLinkButton label="View" getUrl={getExpenseReceiptSignedUrl.bind(null, r.receipt.file_path, false)} />
              <DocumentLinkButton label="Download" getUrl={getExpenseReceiptSignedUrl.bind(null, r.receipt.file_path, true)} />
            </div>
          ) : (
            <p className="text-[13px] text-muted-foreground">No receipt uploaded yet.</p>
          )}
          <form action={uploadExpenseReceipt.bind(null, id, "expense_receipt")} className="mt-3 flex flex-wrap items-center gap-2 border-t border-desktop-border pt-3">
            <input type="file" name="file" accept=".pdf,.jpg,.jpeg,.png" required className="text-xs text-muted-foreground file:mr-2 file:rounded-sm file:border-0 file:bg-primary file:px-3 file:py-1.5 file:text-xs file:font-medium file:text-primary-foreground" />
            <Button type="submit" size="sm">{r.receipt ? "Replace Receipt" : "Upload Receipt"}</Button>
          </form>
        </DesktopPanelBody>
      </DesktopPanel>

      {canApprove && r.status === "approved" && (
        <DesktopPanel>
          <DesktopPanelHeader title="Mark Paid" />
          <DesktopPanelBody>
            <form action={markExpensePaid.bind(null, id)} className="flex flex-wrap items-end gap-2">
              <div className="space-y-1">
                <label className="text-[11px] font-medium uppercase tracking-wide text-muted-foreground">Payment Method</label>
                <select name="payment_method" className="h-8 rounded-sm border border-desktop-border bg-desktop-panel px-2 text-[13px]">
                  <option value="ach">ACH</option><option value="wire">Wire</option><option value="check">Check</option>
                  <option value="credit_card">Credit Card</option><option value="cash">Cash</option><option value="other">Other</option>
                </select>
              </div>
              <div className="space-y-1">
                <label className="text-[11px] font-medium uppercase tracking-wide text-muted-foreground">Reference #</label>
                <input name="reference_number" className="h-8 rounded-sm border border-desktop-border bg-desktop-panel px-2 text-[13px]" />
              </div>
              <Button type="submit" size="sm">Mark Paid</Button>
            </form>
          </DesktopPanelBody>
        </DesktopPanel>
      )}

      {canApprove && !isVoid && (
        <DesktopPanel>
          <DesktopPanelHeader title="Void Expense" />
          <DesktopPanelBody>
            <form action={voidExpense.bind(null, id)} className="flex flex-wrap items-end gap-2">
              <div className="flex-1 space-y-1">
                <label className="text-[11px] font-medium uppercase tracking-wide text-muted-foreground">Reason (required)</label>
                <input name="void_reason" required className="h-8 w-full rounded-sm border border-desktop-border bg-desktop-panel px-2 text-[13px]" />
              </div>
              <Button type="submit" size="sm" variant="danger">Void</Button>
            </form>
          </DesktopPanelBody>
        </DesktopPanel>
      )}

      {!isDraft && !isVoid && (
        <p className="text-xs text-muted-foreground">Amount, category, scope, and entity links are frozen once an expense leaves draft/submitted. Void and re-enter to correct.</p>
      )}
    </div>
  );
}

function Field({ label, value, href }: { label: string; value: string; href?: string }) {
  return (
    <div>
      <p className="text-[10.5px] font-medium uppercase tracking-wide text-muted-foreground">{label}</p>
      {href ? (
        <Link href={href} className="font-medium text-primary hover:underline">{value}</Link>
      ) : (
        <p className="font-medium text-desktop-text capitalize">{value}</p>
      )}
    </div>
  );
}
