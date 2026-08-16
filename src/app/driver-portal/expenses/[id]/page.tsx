import Link from "next/link";
import { redirect, notFound } from "next/navigation";
import { ArrowLeft } from "lucide-react";
import { getDriverPortalSession } from "@/lib/driver-portal/session";
import { createServiceRoleClient } from "@/lib/supabase/service-role";
import { StatusBadge } from "@/components/ui/status-badge";
import { DocumentLinkButton } from "@/components/drivers/document-link-button";
import { ExpenseReceiptUpload } from "@/components/driver-portal/expense-receipt-upload";
import { getDriverExpenseReceiptSignedUrl } from "@/app/driver-portal/actions";

function money(n: number): string {
  return `$${Number(n).toLocaleString(undefined, { minimumFractionDigits: 2 })}`;
}

// Ownership check is .eq("driver_id", identity.driverId) below -- a driver
// requesting another driver's expense id gets notFound(), never another
// driver's spend data (spec section 32). No approve/pay/void controls
// exist on this page at all -- staff Expense Management remains the only
// place those actions can happen (spec section 13).
export default async function DriverPortalExpenseDetailPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const identity = await getDriverPortalSession();
  if (!identity) redirect("/driver-portal/login");

  const supabase = createServiceRoleClient();
  const { data: expense } = await supabase
    .from("expenses")
    .select(
      "id, expense_number, expense_date, category, amount, tax_amount, total_amount, vendor_name, reference_number, notes, status, receipt_document_id, loads(load_number)"
    )
    .eq("id", id)
    .eq("driver_id", identity.driverId)
    .maybeSingle();
  if (!expense) notFound();

  const e = expense as unknown as typeof expense & { loads: { load_number: string } | null };

  let receiptFile: { file_name: string; file_path: string } | null = null;
  if (e.receipt_document_id) {
    const { data: doc } = await supabase.from("documents").select("file_name, file_path").eq("id", e.receipt_document_id).maybeSingle();
    receiptFile = doc ?? null;
  }

  return (
    <div className="flex flex-1 flex-col gap-4">
      <div className="flex items-center gap-2">
        <Link href="/driver-portal/expenses" className="text-muted-foreground">
          <ArrowLeft className="size-4" />
        </Link>
        <h1 className="text-lg font-semibold tracking-tight capitalize">{e.category.replace(/_/g, " ")}</h1>
        <StatusBadge status={e.status} />
      </div>

      <div className="rounded-2xl border border-border bg-card p-4">
        <div className="grid grid-cols-2 gap-y-2 text-sm">
          <Field label="Expense #" value={e.expense_number} />
          <Field label="Load" value={e.loads?.load_number ?? "--"} />
          <Field label="Date" value={new Date(e.expense_date + "T00:00:00").toLocaleDateString()} />
          <Field label="Amount" value={money(e.total_amount)} strong />
          <Field label="Vendor" value={e.vendor_name ?? "--"} />
          <Field label="Reference #" value={e.reference_number ?? "--"} />
        </div>
        {e.notes && (
          <div className="mt-3 border-t border-border pt-3">
            <p className="text-xs font-medium uppercase tracking-wide text-muted-foreground">Notes</p>
            <p className="mt-1 text-sm">{e.notes}</p>
          </div>
        )}
      </div>

      <div className="rounded-2xl border border-border bg-card p-4">
        <p className="mb-2 text-xs font-medium uppercase tracking-wide text-muted-foreground">Receipt</p>
        {receiptFile ? (
          <div className="flex items-center justify-between gap-2">
            <p className="min-w-0 truncate text-sm text-muted-foreground">{receiptFile.file_name}</p>
            <DocumentLinkButton label="View" getUrl={getDriverExpenseReceiptSignedUrl.bind(null, receiptFile.file_path, false)} />
          </div>
        ) : (
          <ExpenseReceiptUpload expenseId={e.id} documentType="expense_receipt" />
        )}
      </div>

      <p className="text-center text-[11px] text-muted-foreground">
        This expense is reviewed by your dispatch/finance team. Status updates here automatically.
      </p>
    </div>
  );
}

function Field({ label, value, strong }: { label: string; value: string; strong?: boolean }) {
  return (
    <div>
      <p className="text-[10.5px] font-medium uppercase tracking-wide text-muted-foreground">{label}</p>
      <p className={strong ? "font-semibold text-primary" : "font-medium"}>{value}</p>
    </div>
  );
}
