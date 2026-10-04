import { createClient } from "@/lib/supabase/server";
import { requireRole } from "@/lib/auth/require-role";
import { DesktopWorkspaceTabs } from "@/components/desktop/workspace-tabs";
import { IncidentForm } from "@/components/safety/incident-form";
import { INCIDENT_TYPES } from "@/lib/safety/incidents";
import { createIncident } from "../actions";
import { incidentFormOptions, orgToday } from "../safety-data";

type SP = { driver_id?: string; truck_id?: string; load_id?: string; type?: string };

export default async function NewIncidentPage({ searchParams }: { searchParams: Promise<SP> }) {
  await requireRole(["owner", "admin", "dispatcher", "accountant"]);
  const sp = await searchParams;
  const supabase = await createClient();
  const [options, today] = await Promise.all([incidentFormOptions(supabase, sp), orgToday(supabase)]);

  // Coming from a driver's page: preselect the truck they drive now (and vice versa).
  let truckId = sp.truck_id ?? null;
  let driverId = sp.driver_id ?? null;
  if (driverId && !truckId) {
    const { data } = await supabase.from("truck_driver_assignments").select("truck_id").eq("driver_id", driverId).eq("is_current", true).maybeSingle();
    truckId = (data?.truck_id as string | undefined) ?? null;
  } else if (truckId && !driverId) {
    const { data } = await supabase.from("truck_driver_assignments").select("driver_id").eq("truck_id", truckId).eq("is_current", true).maybeSingle();
    driverId = (data?.driver_id as string | undefined) ?? null;
  }

  return (
    <div className="space-y-3">
      <DesktopWorkspaceTabs tabs={[{ label: "Safety Incidents", href: "/safety" }, { label: "Report Incident", href: "/safety/new" }]} />
      <div>
        <h1 className="text-[15px] font-semibold tracking-tight text-desktop-text">Report Incident</h1>
        <p className="mt-0.5 text-xs text-muted-foreground">Record what happened. You can add photos and papers on the next screen.</p>
      </div>
      <div className="rounded-md border border-desktop-border bg-card p-4 shadow-elevation-1">
        <IncidentForm
          action={createIncident}
          drivers={options.drivers}
          trucks={options.trucks}
          loads={options.loads}
          today={today}
          defaults={{
            incident_type: sp.type && (INCIDENT_TYPES as readonly string[]).includes(sp.type) ? sp.type : null,
            driver_id: driverId,
            truck_id: truckId,
            load_id: sp.load_id ?? null,
          }}
          submitLabel="Save & add photos"
          cancelHref="/safety"
        />
      </div>
    </div>
  );
}
