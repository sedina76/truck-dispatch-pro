import Link from "next/link";
import { redirect } from "next/navigation";
import { ArrowLeft } from "lucide-react";
import { getDriverPortalSession } from "@/lib/driver-portal/session";
import { createServiceRoleClient } from "@/lib/supabase/service-role";
import { getCurrentDispatch } from "@/lib/driver-portal/dashboard-data";
import { NewExpenseForm } from "@/components/driver-portal/new-expense-form";

// Load is resolved server-side from the driver's own current dispatch and
// shown read-only -- the driver never browses/picks from all company loads
// (spec section 12). The actual submit action re-resolves it again itself,
// so this page's display value is never trusted as the source of truth.
export default async function DriverPortalNewExpensePage() {
  const identity = await getDriverPortalSession();
  if (!identity) redirect("/driver-portal/login");

  const supabase = createServiceRoleClient();
  const dispatch = await getCurrentDispatch(supabase, identity.driverId);

  return (
    <div className="flex flex-1 flex-col gap-4">
      <div className="flex items-center gap-2">
        <Link href="/driver-portal/expenses" className="text-muted-foreground">
          <ArrowLeft className="size-4" />
        </Link>
        <h1 className="text-lg font-semibold tracking-tight">Submit Expense</h1>
      </div>

      {!dispatch ? (
        <div className="rounded-2xl border border-border bg-card p-4">
          <p className="text-sm text-muted-foreground">You need an active trip to submit a load expense against.</p>
        </div>
      ) : (
        <div className="rounded-2xl border border-border bg-card p-4">
          <NewExpenseForm loadNumber={dispatch.load_number} />
        </div>
      )}
    </div>
  );
}
