import { createClient } from "@/lib/supabase/server";
import { getBillingParty } from "@/lib/billing/party";
import { listSafeDocumentCandidates } from "@/lib/profile-share/generate";
import { getProfileShareSignedUrl } from "@/app/(app)/profile-share/actions";
import { ShareProfileDialog } from "./share-profile-dialog";
import { DesktopPanel, DesktopPanelHeader, DesktopPanelBody } from "@/components/desktop/panel";
import { DesktopCollapsibleSection } from "@/components/desktop/collapsible-section";
import { StatusBadge } from "@/components/ui/status-badge";
import { DocumentLinkButton } from "@/components/drivers/document-link-button";
import Link from "next/link";

// Load Detail -> Profile Sharing + Share History (spec sections 18/19).
// Recipient auto-selection reuses the SAME canonical broker-vs-customer
// rule (getBillingParty) as Invoice/Payment/Statement -- never a
// separately-invented "who does this load bill to" decision.
export async function LoadProfileSharingSection({ loadId }: { loadId: string }) {
  const supabase = await createClient();

  const [{ data: load }, { data: dispatch }, { data: history }] = await Promise.all([
    supabase.from("loads").select("id, load_number, broker_id, customer_id, brokers(company_name, email), customers(company_name, email)").eq("id", loadId).single(),
    supabase
      .from("dispatches")
      .select("driver_id, carrier_id, drivers(first_name, last_name), carriers(legal_name)")
      .eq("load_id", loadId)
      .order("dispatched_at", { ascending: false })
      .limit(1)
      .maybeSingle(),
    supabase
      .from("profile_share_log")
      .select("id, profile_type, recipient_email, status, document_ids_included, generated_at, storage_path, profiles!profile_share_log_generated_by_fkey(full_name)")
      .eq("load_id", loadId)
      .order("generated_at", { ascending: false }),
  ]);
  if (!load) return null;

  const loadRow = load as unknown as {
    id: string;
    load_number: string;
    broker_id: string | null;
    customer_id: string | null;
    brokers: { company_name: string; email: string | null } | null;
    customers: { company_name: string; email: string | null } | null;
  };
  const dispatchRow = dispatch as unknown as {
    driver_id: string | null;
    carrier_id: string | null;
    drivers: { first_name: string; last_name: string } | null;
    carriers: { legal_name: string } | null;
  } | null;

  const driver = dispatchRow?.driver_id && dispatchRow.drivers ? { id: dispatchRow.driver_id, name: `${dispatchRow.drivers.first_name} ${dispatchRow.drivers.last_name}` } : null;
  const carrier = dispatchRow?.carrier_id && dispatchRow.carriers ? { id: dispatchRow.carrier_id, name: dispatchRow.carriers.legal_name } : null;

  // Never a driver/carrier email by mistake (spec section 9) -- recipient
  // is always derived from the load's broker/customer relationship only.
  const party = getBillingParty(loadRow);
  const recipientEmail = party.type === "broker" ? loadRow.brokers?.email ?? "" : party.type === "customer" ? loadRow.customers?.email ?? "" : "";

  const [{ data: stops }, { data: org }, availableDocuments] = await Promise.all([
    supabase.from("load_stops").select("stop_type, stop_sequence, city, state").eq("load_id", loadId).order("stop_sequence"),
    supabase.from("organizations").select("name").single(),
    listSafeDocumentCandidates(driver?.id ?? null, carrier?.id ?? null),
  ]);
  const pickup = (stops ?? []).filter((s) => s.stop_type === "pickup")[0];
  const delivery = (stops ?? []).filter((s) => s.stop_type === "delivery").slice(-1)[0];
  const origin = pickup ? [pickup.city, pickup.state].filter(Boolean).join(", ") || null : null;
  const destination = delivery ? [delivery.city, delivery.state].filter(Boolean).join(", ") || null : null;

  const historyRows = (history ?? []) as unknown as {
    id: string;
    profile_type: string;
    recipient_email: string;
    status: string;
    document_ids_included: string[];
    generated_at: string;
    storage_path: string | null;
    profiles: { full_name: string } | null;
  }[];
  const lastShared = historyRows[0] ?? null;

  if (!driver && !carrier) return null;

  return (
    <DesktopCollapsibleSection id="profile_sharing" title="Profile Sharing" defaultOpen={false} badge={historyRows.length || undefined}>
      <div className="flex justify-end pb-2">
        <ShareProfileDialog
          loadId={loadId}
          loadNumber={loadRow.load_number}
          origin={origin}
          destination={destination}
          orgName={org?.name ?? "Your organization"}
          driver={driver}
          carrier={carrier}
          recipientEmail={recipientEmail}
          recipientPartyType={party.type === "none" ? null : party.type}
          availableDocuments={availableDocuments}
        />
      </div>
      <div className="grid grid-cols-2 gap-x-4 gap-y-1.5 text-[13px]">
        <span className="text-muted-foreground">Driver Profile</span>
        <span className="text-right font-medium">{driver ? "Available" : "Not Assigned"}</span>
        <span className="text-muted-foreground">Carrier Profile</span>
        <span className="text-right font-medium">{carrier ? "Available" : "Not Assigned"}</span>
      </div>
      {lastShared ? (
        <div className="mt-3 border-t border-desktop-border pt-2 text-[12.5px] text-muted-foreground">
          Last Shared: {new Date(lastShared.generated_at).toLocaleString()} to {lastShared.recipient_email}
          {lastShared.profiles?.full_name ? ` by ${lastShared.profiles.full_name}` : ""}
        </div>
      ) : (
        <p className="mt-3 border-t border-desktop-border pt-2 text-[12.5px] text-muted-foreground">Never shared externally.</p>
      )}

      {historyRows.length > 0 && (
        <DesktopPanel className="mt-3">
          <DesktopPanelHeader title="Share History" dense />
          <DesktopPanelBody className="overflow-auto p-0">
            <table className="w-full text-[12.5px]">
              <thead>
                <tr className="border-b border-desktop-border text-left text-[10.5px] font-semibold uppercase tracking-wide text-muted-foreground">
                  <th className="py-1.5 pl-3 pr-3">Date</th>
                  <th className="py-1.5 pr-3">Recipient</th>
                  <th className="py-1.5 pr-3">Profile Type</th>
                  <th className="py-1.5 pr-3">Documents</th>
                  <th className="py-1.5 pr-3">Status</th>
                  <th className="py-1.5 pr-3">Shared By</th>
                  <th className="py-1.5 pr-3">&nbsp;</th>
                </tr>
              </thead>
              <tbody>
                {historyRows.map((row) => (
                  <tr key={row.id} className="border-b border-desktop-border last:border-0">
                    <td className="py-1.5 pl-3 pr-3 text-muted-foreground">{new Date(row.generated_at).toLocaleString()}</td>
                    <td className="py-1.5 pr-3">{row.recipient_email}</td>
                    <td className="py-1.5 pr-3 capitalize">{row.profile_type}</td>
                    <td className="py-1.5 pr-3">{row.document_ids_included.length || "--"}</td>
                    <td className="py-1.5 pr-3"><StatusBadge status={row.status} /></td>
                    <td className="py-1.5 pr-3">{row.profiles?.full_name ?? "--"}</td>
                    <td className="py-1.5 pr-3">
                      <div className="flex items-center gap-2">
                        <Link href={`/loads/${loadId}/share-history/${row.id}`} className="text-primary hover:underline">
                          View Snapshot
                        </Link>
                        {row.storage_path && (
                          <DocumentLinkButton label="Download" getUrl={getProfileShareSignedUrl.bind(null, row.storage_path, true)} />
                        )}
                      </div>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </DesktopPanelBody>
        </DesktopPanel>
      )}
    </DesktopCollapsibleSection>
  );
}
