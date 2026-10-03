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
          For one load, use Billing &rarr; Invoices &rarr; Create Invoice. Use this page to put several of a carrier&apos;s delivered loads (same broker) on one invoice. The system works out whether the carrier factors, the recipient and the totals; your dispatch fee is billed separately on a Dispatch Fee Invoice.
        </p>
      </div>
      <div className="rounded-sm border border-desktop-border bg-muted/40 px-3 py-2 text-[12px] text-muted-foreground">
        <p className="font-medium text-desktop-text">First invoice for a carrier?</p>
        <p className="mt-0.5">
          On the carrier&apos;s page, set &quot;Who does the broker pay?&quot; to <span className="font-medium">Broker pays the carrier</span>. Its{" "}
          <span className="font-medium">Billing setup</span> box then shows what&apos;s left (usually just whether it factors). The invoice code and the broker&apos;s billing details are filled in automatically. Loads need a verified proof of delivery before the billing packet can be sent.
        </p>
      </div>
      <NewCarrierInvoiceForm carriers={carriers} />
    </div>
  );
}
