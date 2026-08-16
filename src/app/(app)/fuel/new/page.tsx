import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { Button } from "@/components/ui/button";
import { DesktopWorkspaceTabs } from "@/components/desktop/workspace-tabs";
import { DesktopCollapsibleSection, CollapsibleSectionsProvider, CollapsibleSectionsToolbar } from "@/components/desktop/collapsible-section";
import { FuelPurchaseFields } from "@/components/fuel/fuel-form-fields";
import { PaymentResponsibilityFields } from "@/components/shared/payment-responsibility-fields";
import { createFuelLog } from "../actions";

const SECTION_DEFAULTS: Record<string, boolean> = { purchase: true, payment: true };

async function createAndRedirect(formData: FormData) {
  "use server";
  const { id } = await createFuelLog(formData);
  redirect(`/fuel/${id}`);
}

export default async function NewFuelLogPage() {
  const supabase = await createClient();
  const [{ data: trucksRaw }, { data: driversRaw }] = await Promise.all([
    supabase.from("trucks").select("id, unit_number, carrier_id, ownership_type, current_odometer, carriers(legal_name)").order("unit_number"),
    supabase.from("drivers").select("id, carrier_id, first_name, last_name").eq("status", "active").order("last_name"),
  ]);

  const trucks = (trucksRaw ?? []).map((t) => {
    const row = t as unknown as { id: string; unit_number: string; carrier_id: string | null; ownership_type: string | null; current_odometer: number | null; carriers: { legal_name: string } | null };
    return { id: row.id, unit_number: row.unit_number, carrier_id: row.carrier_id, carrier_name: row.carriers?.legal_name ?? null, ownership_type: row.ownership_type, current_odometer: row.current_odometer };
  });

  return (
    <div className="space-y-3">
      <DesktopWorkspaceTabs tabs={[{ label: "Fuel Logs", href: "/fuel" }, { label: "Log Fuel Purchase", href: "/fuel/new" }]} />

      <form action={createAndRedirect} className="space-y-3">
        <CollapsibleSectionsProvider defaults={SECTION_DEFAULTS}>
          <div className="flex items-center justify-between">
            <div>
              <h1 className="text-base font-semibold text-desktop-text">Log Fuel Purchase</h1>
              <p className="text-[12px] text-desktop-text-muted">Record a fuel purchase and who is financially responsible for it.</p>
            </div>
            <CollapsibleSectionsToolbar />
          </div>

          <div className="space-y-3">
            <DesktopCollapsibleSection id="purchase" title="Fuel Purchase Details">
              <FuelPurchaseFields trucks={trucks} drivers={driversRaw ?? []} />
            </DesktopCollapsibleSection>

            <DesktopCollapsibleSection id="payment" title="Payment & Responsibility">
              <PaymentResponsibilityFields drivers={driversRaw ?? []} amountCapLabel="the fuel purchase total" />
            </DesktopCollapsibleSection>
          </div>
        </CollapsibleSectionsProvider>

        <div className="flex items-center justify-end gap-2 border-t border-desktop-border pt-3">
          <Link href="/fuel" className="inline-flex h-8 items-center rounded-sm px-3 text-[13px] font-medium text-muted-foreground transition-colors hover:bg-muted">
            Cancel
          </Link>
          <Button type="submit">Log Purchase</Button>
        </div>
      </form>
    </div>
  );
}
