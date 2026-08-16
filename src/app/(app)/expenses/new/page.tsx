import { createClient } from "@/lib/supabase/server";
import { FormCard } from "@/components/ui/form-card";
import { FormField, FormGrid, FormSelect, FormTextarea } from "@/components/ui/form-field";
import { DesktopWorkspaceTabs } from "@/components/desktop/workspace-tabs";
import { createExpense } from "../actions";

const DIRECT_LOAD_CATEGORIES = [
  ["fuel", "Fuel"], ["tolls", "Toll"], ["lumper", "Lumper"], ["detention_cost", "Detention Cost"],
  ["scale_ticket", "Scale Ticket"], ["parking", "Parking"], ["permit", "Permit"], ["escort", "Escort"],
  ["washout", "Washout"], ["repair", "Repair / Breakdown"], ["trailer_expense", "Trailer Expense"],
  ["hotel_layover", "Hotel / Layover"], ["cargo_claim", "Cargo Claim"], ["other", "Other Direct Cost"],
] as const;
const OVERHEAD_CATEGORIES = [
  ["rent", "Office Rent"], ["utilities", "Utilities"], ["software", "Software"], ["insurance", "Insurance"],
  ["accounting", "Accounting"], ["legal", "Legal"], ["phone_internet", "Phone / Internet"],
  ["office_supplies", "Office Supplies"], ["payroll", "General Payroll"], ["bank_fees", "Bank Fees"],
  ["maintenance", "Maintenance"], ["permits_and_licenses", "Permits & Licenses"], ["lease_or_loan", "Lease / Loan"],
  ["office", "Office (Other)"], ["other", "Other Overhead"],
] as const;
const ALL_CATEGORIES = [...DIRECT_LOAD_CATEGORIES, ...OVERHEAD_CATEGORIES];

export default async function NewExpensePage({
  searchParams,
}: {
  searchParams: Promise<{ load_id?: string; dispatch_id?: string; truck_id?: string; driver_id?: string; carrier_id?: string; scope?: string; return_to?: string }>;
}) {
  const { load_id, dispatch_id, truck_id, driver_id, carrier_id, scope, return_to } = await searchParams;
  const supabase = await createClient();

  const [{ data: loads }, { data: trucks }, { data: trailers }, { data: drivers }, { data: carriers }, dispatchInfo] = await Promise.all([
    supabase.from("loads").select("id, load_number").order("load_number", { ascending: false }).limit(200),
    supabase.from("trucks").select("id, unit_number").order("unit_number"),
    supabase.from("trailers").select("id, unit_number").order("unit_number"),
    supabase.from("drivers").select("id, first_name, last_name").order("last_name"),
    supabase.from("carriers").select("id, legal_name").order("legal_name"),
    // Opening from a load/dispatch prefills driver/truck/carrier from the
    // dispatch (spec section 10) -- context fields only, not a separate scope.
    dispatch_id
      ? supabase.from("dispatches").select("load_id, carrier_id, truck_id, driver_id, trailer_id").eq("id", dispatch_id).maybeSingle()
      : load_id
        ? supabase.from("dispatches").select("id, carrier_id, truck_id, driver_id, trailer_id").eq("load_id", load_id).order("dispatched_at", { ascending: false }).limit(1).maybeSingle()
        : Promise.resolve({ data: null }),
  ]);

  const dispatch = dispatchInfo.data as { id?: string; load_id?: string; carrier_id: string; truck_id: string; driver_id: string; trailer_id: string | null } | null;
  const defaultScope = scope || (load_id ? "load" : truck_id ? "truck" : driver_id ? "driver" : carrier_id ? "carrier" : "general");
  const defaultLoadId = load_id || dispatch?.load_id || "";
  const defaultDispatchId = dispatch_id || dispatch?.id || "";
  const defaultTruckId = truck_id || dispatch?.truck_id || "";
  const defaultDriverId = driver_id || dispatch?.driver_id || "";
  const defaultCarrierId = carrier_id || dispatch?.carrier_id || "";
  const defaultTrailerId = dispatch?.trailer_id || "";

  return (
    <div className="space-y-3">
      <DesktopWorkspaceTabs tabs={[{ label: "Expenses", href: "/expenses" }, { label: "New Expense", href: "/expenses/new" }]} />
      <FormCard title="Add Expense" description="Every expense has one accounting scope. Load-scoped costs feed Load Profitability once approved." action={createExpense} cancelHref={return_to || "/expenses"}>
        <FormGrid>
          <input type="hidden" name="return_to" value={return_to ?? ""} />
          <FormSelect
            label="Scope"
            name="scope"
            required
            defaultValue={defaultScope}
            options={[
              { value: "load", label: "Load (direct load cost)" },
              { value: "truck", label: "Truck (fleet cost)" },
              { value: "driver", label: "Driver (company-paid, not a settlement deduction)" },
              { value: "carrier", label: "Carrier" },
              { value: "general", label: "General / Overhead" },
            ]}
          />
          <FormSelect label="Category" name="category" required defaultValue="other" options={ALL_CATEGORIES.map(([v, l]) => ({ value: v, label: l }))} />
          <FormField label="Date" name="expense_date" type="date" defaultValue={new Date().toISOString().slice(0, 10)} required />
          <FormField label="Amount ($)" name="amount" type="number" step="0.01" required />
          <FormField label="Tax ($)" name="tax_amount" type="number" step="0.01" defaultValue={0} />
          <FormField label="Vendor / Payee" name="vendor_name" />
          <FormSelect
            label="Payment method"
            name="payment_method"
            options={[
              { value: "ach", label: "ACH" }, { value: "wire", label: "Wire" }, { value: "check", label: "Check" },
              { value: "credit_card", label: "Credit Card" }, { value: "cash", label: "Cash" }, { value: "other", label: "Other" },
            ]}
          />
          <FormField label="Reference #" name="reference_number" />

          <FormSelect label="Load" name="load_id" defaultValue={defaultLoadId} options={(loads ?? []).map((l) => ({ value: l.id, label: l.load_number }))} />
          <FormField label="Dispatch ID (auto-resolved from load if blank)" name="dispatch_id" defaultValue={defaultDispatchId} disabled={!!defaultDispatchId} />
          <FormSelect label="Truck" name="truck_id" defaultValue={defaultTruckId} options={(trucks ?? []).map((t) => ({ value: t.id, label: t.unit_number }))} />
          <FormSelect label="Trailer" name="trailer_id" defaultValue={defaultTrailerId} options={(trailers ?? []).map((t) => ({ value: t.id, label: t.unit_number }))} />
          <FormSelect label="Driver" name="driver_id" defaultValue={defaultDriverId} options={(drivers ?? []).map((d) => ({ value: d.id, label: `${d.first_name} ${d.last_name}` }))} />
          <FormSelect label="Carrier" name="carrier_id" defaultValue={defaultCarrierId} options={(carriers ?? []).map((c) => ({ value: c.id, label: c.legal_name }))} />

          <label className="flex items-center gap-2 text-sm font-medium sm:col-span-2">
            <input type="checkbox" name="billable_to_customer" className="size-4 rounded border-desktop-border" />
            Billable to customer/broker separately (do not net against revenue -- invoice the accessorial separately)
          </label>

          <FormTextarea label="Description" name="description" />
          <FormTextarea label="Notes" name="notes" />
        </FormGrid>
      </FormCard>
      <p className="text-xs text-muted-foreground">Saved as a draft. Add a receipt and approve it from the expense detail page.</p>
    </div>
  );
}
