import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { NewCarrierInvoiceForm } from "@/components/carrier-invoices/new-carrier-invoice-form";
import { listBillableCarriers } from "../issuance-actions";

// Proposal 0157 (D-57): step 1 of the controlled carrier-invoice issuance workflow. The page only offers the form to owner / admin / dispatcher; that is a convenience, not security -- every RPC re-checks
// the role and the per-carrier grant.
export default async function NewCarrierInvoicePage() {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) redirect("/login");
  const { data: profile } = await supabase.from("profiles").select("role").eq("id", user.id).maybeSingle();
  const role = String(profile?.role ?? "");
  if (role !== "owner" && role !== "admin" && role !== "dispatcher") redirect("/access-denied");
  const carriers = await listBillableCarriers();
  return (
    <div className="space-y-3">
      <div>
        <h1 className="text-[15px] font-semibold tracking-tight text-desktop-text">New Carrier Invoice</h1>
        <p className="mt-0.5 text-xs text-muted-foreground">
          Select one carrier and its delivered loads (one broker per invoice). The system resolves whether the carrier is billed directly or factored, the recipient and the totals; the dispatch-service fee is a separate receivable.
        </p>
      </div>
      <div className="rounded-sm border border-desktop-border bg-muted/40 px-3 py-2 text-[12px] text-muted-foreground">
        <p className="font-medium text-desktop-text">Before the first invoice for a carrier</p>
        <ul className="mt-1 list-disc space-y-0.5 pl-4">
          <li>On the carrier: &quot;Who does the broker pay?&quot; = Broker pays the carrier (only those loads are listed), an Invoice code (e.g. RRT), and the broker under &quot;Brokers this carrier invoices&quot;.</li>
          <li>In Settings, Factoring: the carrier&apos;s billing policy, Direct or Factored. For Factored: its factoring company, remit-to, and an approved notice of assignment.</li>
          <li>Each load needs its pickup and delivery stops, and a verified proof of delivery before its package can be sent.</li>
        </ul>
      </div>
      <NewCarrierInvoiceForm carriers={carriers} />
    </div>
  );
}
