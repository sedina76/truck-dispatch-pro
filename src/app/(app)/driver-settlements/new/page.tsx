import { createClient } from "@/lib/supabase/server";
import { NewSettlementForm } from "@/components/driver-settlements/new-settlement-form";

function isoDate(d: Date) {
  return d.toISOString().slice(0, 10);
}

export default async function NewDriverSettlementPage() {
  const supabase = await createClient();
  const { data: drivers } = await supabase.from("drivers").select("id, first_name, last_name").eq("status", "active").order("first_name");

  // Default period: the last 7 days (weekly, spec section 6's suggested default).
  const today = new Date();
  const weekAgo = new Date(today);
  weekAgo.setDate(weekAgo.getDate() - 6);

  return (
    <div className="space-y-3">
      <div>
        <h1 className="text-[15px] font-semibold tracking-tight text-desktop-text">New Settlement</h1>
        <p className="mt-0.5 text-xs text-muted-foreground">
          Select a driver and period -- delivered loads not already settled are added automatically, priced with the driver&apos;s pay rate. Review before approving.
        </p>
      </div>
      <div className="rounded-md border border-desktop-border bg-card p-4 shadow-elevation-1">
        <NewSettlementForm drivers={(drivers ?? []).map((d) => ({ value: d.id, label: `${d.first_name} ${d.last_name}` }))} defaultStart={isoDate(weekAgo)} defaultEnd={isoDate(today)} />
      </div>
    </div>
  );
}
