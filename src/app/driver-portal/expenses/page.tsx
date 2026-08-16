import Link from "next/link";
import { redirect } from "next/navigation";
import { Plus, Receipt } from "lucide-react";
import { getDriverPortalSession } from "@/lib/driver-portal/session";
import { createServiceRoleClient } from "@/lib/supabase/service-role";
import { StatusBadge } from "@/components/ui/status-badge";

function money(n: number): string {
  return `$${Number(n).toLocaleString(undefined, { minimumFractionDigits: 2 })}`;
}

// My Expenses (spec section 15): only expenses associated with THIS driver
// (driver_id = identity.driverId) -- never another driver's. Reuses the
// canonical expenses table/status vocabulary from the Expense & Cost
// Management module verbatim; no separate driver-expense list source.
export default async function DriverPortalExpensesPage() {
  const identity = await getDriverPortalSession();
  if (!identity) redirect("/driver-portal/login");

  const supabase = createServiceRoleClient();
  const { data: expenses } = await supabase
    .from("expenses")
    .select("id, expense_number, expense_date, category, total_amount, status, receipt_document_id, loads(load_number)")
    .eq("driver_id", identity.driverId)
    .order("expense_date", { ascending: false });

  const rows = (expenses ?? []) as unknown as {
    id: string;
    expense_number: string;
    expense_date: string;
    category: string;
    total_amount: number;
    status: string;
    receipt_document_id: string | null;
    loads: { load_number: string } | null;
  }[];

  return (
    <div className="flex flex-1 flex-col gap-4">
      <div className="flex items-center justify-between">
        <h1 className="text-lg font-semibold tracking-tight">My Expenses</h1>
        <Link href="/driver-portal/expenses/new" className="flex h-10 items-center gap-1.5 rounded-xl bg-primary px-3 text-sm font-semibold text-primary-foreground">
          <Plus className="size-4" /> Submit
        </Link>
      </div>

      {rows.length === 0 ? (
        <div className="rounded-2xl border border-border bg-card p-4">
          <p className="text-sm text-muted-foreground">No expenses submitted yet.</p>
        </div>
      ) : (
        <div className="space-y-2.5">
          {rows.map((e) => (
            <Link key={e.id} href={`/driver-portal/expenses/${e.id}`} className="block rounded-2xl border border-border bg-card p-4">
              <div className="flex items-center justify-between">
                <p className="flex items-center gap-1.5 text-sm font-semibold capitalize">
                  <Receipt className="size-3.5 text-primary" /> {e.category.replace(/_/g, " ")}
                </p>
                <StatusBadge status={e.status} />
              </div>
              <div className="mt-1.5 flex items-center justify-between text-xs text-muted-foreground">
                <span>{new Date(e.expense_date + "T00:00:00").toLocaleDateString()}{e.loads ? ` · ${e.loads.load_number}` : ""}</span>
                <span className="font-semibold text-foreground">{money(e.total_amount)}</span>
              </div>
              {!e.receipt_document_id && <p className="mt-1 text-[10.5px] text-warning">No receipt attached</p>}
            </Link>
          ))}
        </div>
      )}
    </div>
  );
}
