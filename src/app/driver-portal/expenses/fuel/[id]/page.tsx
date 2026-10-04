import Link from "next/link";
import { redirect, notFound } from "next/navigation";
import { ArrowLeft, Fuel } from "lucide-react";
import { getDriverPortalSession } from "@/lib/driver-portal/session";
import { createServiceRoleClient } from "@/lib/supabase/service-role";
import { DocumentLinkButton } from "@/components/drivers/document-link-button";
import { ExpenseReceiptUpload } from "@/components/driver-portal/expense-receipt-upload";
import { getDriverFuelReceiptSignedUrl } from "@/app/driver-portal/actions";
import { DRIVER_FUEL_PAID_BY } from "@/lib/driver-portal/constants";

function money(n: number): string {
  return `$${Number(n).toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
}

// A fuel purchase the driver logged (it lives in the office's Fuel Logs).
// Only the driver's own (driver_id = this driver); the office handles who
// pays and any recovery.
export default async function DriverPortalFuelDetailPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const identity = await getDriverPortalSession();
  if (!identity) redirect("/driver-portal/login");

  const supabase = createServiceRoleClient();
  const { data: log } = await supabase
    .from("fuel_logs")
    .select("id, purchased_at, gallons, price_per_gallon, total_amount, state, station_name, odometer_reading, paid_by, receipt_document_id, trucks(unit_number)")
    .eq("id", id)
    .eq("driver_id", identity.driverId)
    .eq("organization_id", identity.organizationId)
    .maybeSingle();
  if (!log) notFound();
  const f = log as unknown as {
    id: string;
    purchased_at: string;
    gallons: number;
    price_per_gallon: number | null;
    total_amount: number;
    state: string | null;
    station_name: string | null;
    odometer_reading: number | null;
    paid_by: string;
    receipt_document_id: string | null;
    trucks: { unit_number: string } | null;
  };

  let receipt: { file_name: string; file_path: string } | null = null;
  if (f.receipt_document_id) {
    const { data: doc } = await supabase.from("documents").select("file_name, file_path").eq("id", f.receipt_document_id).maybeSingle();
    receipt = doc ?? null;
  }

  return (
    <div className="flex flex-1 flex-col gap-4">
      <div className="flex items-center gap-2">
        <Link href="/driver-portal/expenses" className="text-muted-foreground">
          <ArrowLeft className="size-4" />
        </Link>
        <h1 className="flex items-center gap-1.5 text-lg font-semibold tracking-tight">
          <Fuel className="size-4 text-primary" /> Fuel
        </h1>
        <span className="rounded-full bg-success/10 px-2 py-0.5 text-[11px] font-semibold text-success">Logged</span>
      </div>

      <div className="rounded-2xl border border-border bg-card p-4">
        <div className="grid grid-cols-2 gap-y-2 text-sm">
          <Field label="Date" value={new Date(f.purchased_at).toLocaleDateString()} />
          <Field label="Total" value={money(f.total_amount)} strong />
          <Field label="Gallons" value={Number(f.gallons).toLocaleString(undefined, { maximumFractionDigits: 3 })} />
          <Field label="Price / gal" value={f.price_per_gallon != null ? `$${Number(f.price_per_gallon).toFixed(3)}` : "--"} />
          <Field label="Fuel stop" value={f.station_name ?? "--"} />
          <Field label="State" value={f.state ?? "--"} />
          <Field label="Truck" value={f.trucks?.unit_number ?? "--"} />
          <Field label="Odometer" value={f.odometer_reading != null ? Number(f.odometer_reading).toLocaleString() : "--"} />
          <Field label="Paid with" value={DRIVER_FUEL_PAID_BY.find((o) => o.value === f.paid_by)?.label ?? f.paid_by} />
        </div>
      </div>

      <div className="rounded-2xl border border-border bg-card p-4">
        <p className="mb-2 text-xs font-medium uppercase tracking-wide text-muted-foreground">Receipt</p>
        {receipt ? (
          <div className="flex items-center justify-between gap-2">
            <p className="min-w-0 truncate text-sm text-muted-foreground">{receipt.file_name}</p>
            <DocumentLinkButton label="View" getUrl={getDriverFuelReceiptSignedUrl.bind(null, receipt.file_path, false)} />
          </div>
        ) : (
          <ExpenseReceiptUpload fuelLogId={f.id} />
        )}
      </div>

      <p className="text-center text-[11px] text-muted-foreground">Your dispatch office has been notified and will review this fuel purchase.</p>
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
