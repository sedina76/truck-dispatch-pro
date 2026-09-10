import { createClient } from "@/lib/supabase/server";
import { DesktopPanel, DesktopPanelHeader, DesktopPanelBody } from "@/components/desktop/panel";
import { GoToLoadSelect } from "./go-to-load-select";

// Compact "Share External Profile" entry point for the Driver Profile and
// Carrier Profile pages (spec sections 16/17). Always requires picking a
// load -- there is no shipment-less generic external profile.
export async function ShareExternalProfileSection({
  entity,
}: {
  entity: { type: "driver"; driverId: string } | { type: "carrier"; carrierId: string };
}) {
  const supabase = await createClient();
  const query = supabase
    .from("dispatches")
    .select("load_id, dispatched_at, loads:loads!dispatches_load_id_fkey(load_number, status)")
    .order("dispatched_at", { ascending: false })
    .limit(20);
  const { data } =
    entity.type === "driver" ? await query.eq("driver_id", entity.driverId) : await query.eq("carrier_id", entity.carrierId);

  const rows = (data ?? []) as unknown as { load_id: string; loads: { load_number: string; status: string } | null }[];
  const loads = rows
    .filter((r) => r.loads)
    .map((r) => ({ id: r.load_id, label: `${r.loads!.load_number} (${r.loads!.status.replace(/_/g, " ")})` }));

  return (
    <DesktopPanel>
      <DesktopPanelHeader title="Share External Profile" />
      <DesktopPanelBody>
        {loads.length === 0 ? (
          <p className="text-[13px] text-muted-foreground">
            No loads on file for this {entity.type} yet. Assign a load before sharing an external profile -- shares are always tied to a specific shipment.
          </p>
        ) : (
          <>
            <p className="mb-2 text-[12.5px] text-muted-foreground">Choose the load this profile applies to. The full share dialog (preview/download/email) opens on that load&apos;s page.</p>
            <GoToLoadSelect loads={loads} />
          </>
        )}
      </DesktopPanelBody>
    </DesktopPanel>
  );
}
