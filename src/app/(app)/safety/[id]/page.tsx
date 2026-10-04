import Link from "next/link";
import { notFound } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { requireRole } from "@/lib/auth/require-role";
import { DesktopWorkspaceTabs } from "@/components/desktop/workspace-tabs";
import { StatusBadge } from "@/components/ui/status-badge";
import { ConfirmDeleteForm } from "@/components/ui/confirm-delete-form";
import { IncidentForm } from "@/components/safety/incident-form";
import { IncidentFiles, type IncidentFile } from "@/components/safety/incident-files";
import { incidentTypeLabel } from "@/lib/safety/incidents";
import { updateIncident, uploadIncidentFiles, getIncidentFileUrl, deleteIncident } from "../actions";
import { INCIDENT_SELECT, driverName, incidentFormOptions, money, orgToday, shortDate, type IncidentRow } from "../safety-data";

export default async function IncidentPage({ params }: { params: Promise<{ id: string }> }) {
  const role = await requireRole(["owner", "admin", "dispatcher", "accountant", "viewer"]);
  const { id } = await params;
  const supabase = await createClient();

  const { data } = await supabase.from("safety_incidents").select(`${INCIDENT_SELECT}, created_at`).eq("id", id).maybeSingle();
  if (!data) notFound();
  const incident = data as unknown as IncidentRow & { created_at: string };

  const [options, today, { data: docs }, { data: activity }] = await Promise.all([
    incidentFormOptions(supabase, incident),
    orgToday(supabase),
    supabase.from("documents").select("id, file_name, file_path, mime_type, document_type, created_at").eq("entity_type", "safety_incident").eq("entity_id", id).order("created_at"),
    supabase
      .from("activity_logs")
      .select("id, action, created_at, profiles!activity_logs_actor_id_fkey(full_name)")
      .eq("entity_type", "safety_incident")
      .eq("entity_id", id)
      .order("created_at", { ascending: false })
      .limit(20),
  ]);

  const docRows = (docs ?? []) as { id: string; file_name: string; file_path: string; mime_type: string | null; document_type: string; created_at: string }[];
  const photoPaths = docRows.filter((d) => d.document_type === "incident_photo").map((d) => d.file_path);
  const signed = new Map<string, string>();
  if (photoPaths.length > 0) {
    const { data: urls } = await supabase.storage.from("load-documents").createSignedUrls(photoPaths, 3600);
    for (const u of (urls ?? []) as { path: string | null; signedUrl: string | null }[]) if (u.path && u.signedUrl) signed.set(u.path, u.signedUrl);
  }
  const files: IncidentFile[] = docRows.map((d) => ({
    id: d.id,
    name: d.file_name,
    isPhoto: d.document_type === "incident_photo",
    url: signed.get(d.file_path) ?? null,
    addedAt: d.created_at,
  }));

  const canEdit = role !== "viewer";
  const canDelete = role === "owner" || role === "admin";
  const title = `${incidentTypeLabel(incident.incident_type)} -- ${shortDate(incident.occurred_on)}`;
  const activityRows = (activity ?? []) as unknown as { id: string; action: string; created_at: string; profiles: { full_name: string } | null }[];

  return (
    <div className="space-y-3">
      <DesktopWorkspaceTabs tabs={[{ label: "Safety Incidents", href: "/safety" }, { label: title, href: `/safety/${id}` }]} />

      <div className="flex flex-wrap items-start justify-between gap-2">
        <div>
          <h1 className="text-[15px] font-semibold tracking-tight text-desktop-text">{title}</h1>
          <p className="mt-0.5 flex flex-wrap items-center gap-x-2 gap-y-1 text-[12px] text-desktop-text-muted">
            <StatusBadge status={incident.status} />
            {incident.driver_id && (
              <Link href={`/drivers/${incident.driver_id}`} className="hover:underline">
                {driverName(incident.drivers) ?? "Driver"}
              </Link>
            )}
            {incident.truck_id && (
              <Link href={`/trucks/${incident.truck_id}`} className="hover:underline">
                Truck {incident.trucks?.unit_number}
              </Link>
            )}
            {incident.load_id && (
              <Link href={`/loads/${incident.load_id}`} className="hover:underline">
                {incident.loads?.load_number}
              </Link>
            )}
            <span>Cost {money(incident.cost)}</span>
          </p>
        </div>
        <div className="flex items-center gap-2">
          {canDelete && <ConfirmDeleteForm action={deleteIncident.bind(null, id)} />}
          <Link href="/safety" className="inline-flex h-8 items-center rounded-sm border border-desktop-border px-3 text-[13px] font-medium hover:bg-muted">
            Back
          </Link>
        </div>
      </div>

      <section className="rounded-md border border-desktop-border bg-card shadow-elevation-1">
        <h2 className="flex h-7 items-center rounded-t-md bg-desktop-header px-3 text-[11px] font-semibold uppercase tracking-wide text-desktop-header-text">Photos &amp; papers ({files.length})</h2>
        <div className="p-4">
          <IncidentFiles files={files} upload={uploadIncidentFiles.bind(null, id)} openFile={getIncidentFileUrl} canUpload={canEdit} />
        </div>
      </section>

      <section className="rounded-md border border-desktop-border bg-card shadow-elevation-1">
        <h2 className="flex h-7 items-center rounded-t-md bg-desktop-header px-3 text-[11px] font-semibold uppercase tracking-wide text-desktop-header-text">Incident details</h2>
        <div className="p-4">
          {canEdit ? (
            <IncidentForm
              action={updateIncident.bind(null, id)}
              drivers={options.drivers}
              trucks={options.trucks}
              loads={options.loads}
              today={today}
              defaults={incident}
              submitLabel="Save changes"
              cancelHref="/safety"
              showStatus
            />
          ) : (
            <dl className="grid grid-cols-1 gap-x-4 gap-y-2 text-[13px] sm:grid-cols-2">
              <div>
                <dt className="text-[11.5px] text-muted-foreground">Place</dt>
                <dd>{incident.location ?? "--"}</dd>
              </div>
              <div className="sm:col-span-2">
                <dt className="text-[11.5px] text-muted-foreground">Details</dt>
                <dd className="whitespace-pre-wrap">{incident.description ?? "--"}</dd>
              </div>
            </dl>
          )}
        </div>
      </section>

      {activityRows.length > 0 && (
        <section className="rounded-md border border-desktop-border bg-card shadow-elevation-1">
          <h2 className="flex h-7 items-center rounded-t-md bg-desktop-header px-3 text-[11px] font-semibold uppercase tracking-wide text-desktop-header-text">History</h2>
          <ul className="divide-y divide-desktop-border text-[12px]">
            {activityRows.map((a) => (
              <li key={a.id} className="flex justify-between gap-2 px-3 py-1.5">
                <span>
                  {a.action.replace(/_/g, " ")} {a.profiles?.full_name ? `by ${a.profiles.full_name}` : ""}
                </span>
                <span className="text-muted-foreground">{new Date(a.created_at).toLocaleString("en-US", { dateStyle: "medium", timeStyle: "short" })}</span>
              </li>
            ))}
          </ul>
        </section>
      )}
    </div>
  );
}
