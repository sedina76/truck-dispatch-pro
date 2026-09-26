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
    <div className="mx-auto max-w-3xl space-y-4 p-4">
      <h1 className="text-xl font-semibold">New carrier invoice</h1>
      <p className="text-sm text-muted-foreground">
        Select one carrier and its delivered loads. The system resolves whether the carrier is billed directly or factored, the recipient and the totals; the dispatch-service fee is a separate receivable.
      </p>
      <NewCarrierInvoiceForm carriers={carriers} />
    </div>
  );
}
