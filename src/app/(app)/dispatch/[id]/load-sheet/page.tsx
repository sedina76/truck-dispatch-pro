import { notFound } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { getDriverLoadSheetData, type LoadSheetStop } from "@/lib/dispatch/load-sheet";
import { PrintInvoiceButton } from "@/components/invoices/print-invoice-button";
import { formatStopDateTime } from "@/lib/timezone/format";

// Driver-Safe Load Sheet (spec section 12) -- same browser-print pattern
// already used for invoices/receipts/settlements (window.print(), no PDF
// library). This is the ONLY thing "Print Load Sheet" ever renders --
// never the original Rate Confirmation. Reuses getDriverLoadSheetData(),
// which has no query path to broker rate, carrier rate, dispatch fee,
// profit, customer billing, settlement data, or internal notes, so
// there's no field here that could leak one by accident.
export default async function DispatchLoadSheetPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const supabase = await createClient();

  const { data: dispatch } = await supabase.from("dispatches").select("id, load_id, status").eq("id", id).single();
  if (!dispatch) notFound();

  const sheet = await getDriverLoadSheetData(dispatch.load_id);
  if (!sheet) notFound();

  const { data: org } = await supabase.from("organizations").select("name, business_phone").single();

  return (
    <div className="min-h-screen bg-muted/30 py-8 print:bg-white print:py-0">
      <div className="mx-auto mb-4 flex max-w-xl justify-end px-4 print:hidden">
        <PrintInvoiceButton />
      </div>

      <div className="pdf-page mx-auto max-w-xl rounded-xl border border-border bg-white p-10 text-neutral-900 shadow-elevation-2 print:max-w-none">
        <div className="flex items-start justify-between border-b border-neutral-200 pb-6">
          <div>
            <h1 className="text-xl font-bold">{org?.name ?? "Your Company"}</h1>
            {org?.business_phone && <p className="mt-1 text-xs text-neutral-500">{org.business_phone}</p>}
          </div>
          <div className="text-right">
            <p className="text-2xl font-bold tracking-tight text-neutral-800">LOAD SHEET</p>
            <p className="mt-1 text-sm font-medium">{sheet.loadNumber}</p>
          </div>
        </div>

        <div className="grid grid-cols-2 gap-x-4 gap-y-2 border-b border-neutral-200 py-6 text-sm">
          <Field label="Commodity" value={sheet.commodity ?? "--"} />
          <Field label="Weight" value={sheet.weightLbs ? `${Number(sheet.weightLbs).toLocaleString()} lbs` : "--"} />
          <Field label="Equipment" value={sheet.equipmentType ? sheet.equipmentType.replace(/_/g, " ") : "--"} />
          <Field label="Miles" value={sheet.totalMiles ? Number(sheet.totalMiles).toLocaleString() : "--"} />
        </div>

        <div className="grid grid-cols-1 gap-6 border-b border-neutral-200 py-6 sm:grid-cols-2">
          <StopBlock title="Pickup" stop={sheet.pickup} />
          <StopBlock title="Delivery" stop={sheet.delivery} />
        </div>

        {sheet.specialInstructions && (
          <div className="py-6">
            <p className="text-xs font-semibold uppercase tracking-wide text-neutral-400">Special Instructions</p>
            <p className="mt-1 text-sm">{sheet.specialInstructions}</p>
          </div>
        )}

        <p className="mt-4 text-center text-[11px] text-neutral-400">
          Operational information only. Does not include rate, billing, or settlement data.
        </p>
      </div>
    </div>
  );
}

function Field({ label, value }: { label: string; value: string }) {
  return (
    <div>
      <p className="text-xs text-neutral-500">{label}</p>
      <p className="font-medium">{value}</p>
    </div>
  );
}

function StopBlock({ title, stop }: { title: string; stop: LoadSheetStop | null }) {
  return (
    <div>
      <p className="text-xs font-semibold uppercase tracking-wide text-neutral-400">{title}</p>
      {stop ? (
        <div className="mt-1 space-y-0.5 text-sm">
          <p className="font-medium">{stop.companyName ?? "--"}</p>
          {stop.addressLine1 && <p className="text-neutral-600">{stop.addressLine1}</p>}
          <p className="text-neutral-600">{[stop.city, stop.state].filter(Boolean).join(", ") || "--"}</p>
          {stop.scheduledAt && <p className="text-neutral-600">{formatStopDateTime(stop.scheduledAt, stop.timezone, { includeYear: true })}</p>}
          {stop.referenceNumber && <p className="text-xs text-neutral-500">Ref #: {stop.referenceNumber}</p>}
        </div>
      ) : (
        <p className="mt-1 text-sm text-neutral-400">Not set</p>
      )}
    </div>
  );
}
