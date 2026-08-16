import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { DesktopCollapsibleSection } from "@/components/desktop/collapsible-section";
import { StatusBadge } from "@/components/ui/status-badge";

function money(n: number): string {
  return `$${Number(n).toLocaleString(undefined, { minimumFractionDigits: 2 })}`;
}

// Load Detail -> Expenses (spec section 32). Reuses the same collapsible
// desktop component built for Driver Profile. Every row here is
// scope='load' for this exact load -- see get_load_direct_expenses()
// (0040) for the canonical approved total this feeds into Profitability.
export async function LoadExpensesSection({ loadId }: { loadId: string }) {
  const supabase = await createClient();
  const { data } = await supabase
    .from("expenses")
    .select("id, expense_number, expense_date, category, vendor_name, total_amount, status, receipt_document_id")
    .eq("load_id", loadId)
    .eq("scope", "load")
    .order("expense_date", { ascending: false });
  const rows = data ?? [];

  return (
    <DesktopCollapsibleSection id="expenses" title="Expenses" defaultOpen={false} badge={rows.length || undefined}>
      <div className="flex justify-end pb-2">
        <Link
          href={`/expenses/new?load_id=${loadId}&scope=load&return_to=${encodeURIComponent(`/loads/${loadId}`)}`}
          className="inline-flex h-7 items-center rounded-sm bg-primary px-2.5 text-xs font-medium text-primary-foreground hover:bg-primary-hover"
        >
          Add Expense
        </Link>
      </div>
      {rows.length === 0 ? (
        <p className="text-[13px] text-muted-foreground">No expenses logged for this load yet.</p>
      ) : (
        <table className="w-full text-[12.5px]">
          <thead>
            <tr className="border-b border-desktop-border text-left text-[10.5px] font-semibold uppercase tracking-wide text-muted-foreground">
              <th className="py-1.5 pr-3">Expense #</th>
              <th className="py-1.5 pr-3">Date</th>
              <th className="py-1.5 pr-3">Category</th>
              <th className="py-1.5 pr-3">Vendor</th>
              <th className="py-1.5 pr-3 text-right">Amount</th>
              <th className="py-1.5 pr-3">Status</th>
              <th className="py-1.5 pr-3">Receipt</th>
            </tr>
          </thead>
          <tbody>
            {rows.map((e) => (
              <tr key={e.id} className="border-b border-desktop-border last:border-0">
                <td className="py-1.5 pr-3 font-medium">
                  <Link href={`/expenses/${e.id}`} className="text-primary hover:underline">{e.expense_number}</Link>
                </td>
                <td className="py-1.5 pr-3 text-muted-foreground">{new Date(e.expense_date + "T00:00:00").toLocaleDateString()}</td>
                <td className="py-1.5 pr-3 capitalize">{e.category.replace(/_/g, " ")}</td>
                <td className="py-1.5 pr-3">{e.vendor_name ?? "--"}</td>
                <td className="py-1.5 pr-3 text-right tabular-nums font-medium">{money(e.total_amount)}</td>
                <td className="py-1.5 pr-3"><StatusBadge status={e.status} /></td>
                <td className="py-1.5 pr-3">{e.receipt_document_id ? "Yes" : "--"}</td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
    </DesktopCollapsibleSection>
  );
}
