import Link from "next/link";
import { notFound } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { getProfileShareSignedUrl } from "@/app/(app)/profile-share/actions";
import { DesktopWorkspaceTabs } from "@/components/desktop/workspace-tabs";
import { DesktopPanel, DesktopPanelHeader, DesktopPanelBody } from "@/components/desktop/panel";
import { PageHeader } from "@/components/ui/page-header";
import { StatusBadge } from "@/components/ui/status-badge";
import { DocumentLinkButton } from "@/components/drivers/document-link-button";

type Snapshot = {
  load_number: string;
  broker_name: string | null;
  origin: string | null;
  destination: string | null;
  pickup_scheduled: string | null;
  delivery_scheduled: string | null;
  truck_unit: string | null;
  trailer_unit: string | null;
  driver: {
    name: string;
    status: string;
    cdl_class: string | null;
    cdl_status: string;
    cdl_expiry: string | null;
    medical_card_status: string;
    medical_card_expiry: string | null;
    years_experience: number | null;
    completed_trips: number;
  } | null;
  carrier: {
    name: string;
    mc_number: string | null;
    dot_number: string | null;
    auto_liability_status: string;
    cargo_insurance_status: string;
    completed_loads: number;
  } | null;
  included_document_ids: string[];
  generated_at: string;
};

// Renders EXACTLY what was shared, straight from the frozen snapshot
// JSONB -- never a live re-query of the driver/carrier/load (spec section
// 19: "Do not regenerate historical profile silently"). This is why a
// share record is worth keeping even after the underlying driver/carrier
// data changes.
export default async function ShareHistorySnapshotPage({
  params,
}: {
  params: Promise<{ id: string; shareId: string }>;
}) {
  const { id, shareId } = await params;
  const supabase = await createClient();

  const { data: share } = await supabase
    .from("profile_share_log")
    .select(
      "id, load_id, profile_type, recipient_email, status, error, snapshot, storage_path, generated_at, sent_at, profiles!profile_share_log_generated_by_fkey(full_name), sent_profile:profiles!profile_share_log_sent_by_fkey(full_name)"
    )
    .eq("id", shareId)
    .eq("load_id", id)
    .maybeSingle();
  if (!share) notFound();

  const snap = share.snapshot as unknown as Snapshot;
  const generatedBy = (share as unknown as { profiles: { full_name: string } | null }).profiles;
  const sentBy = (share as unknown as { sent_profile: { full_name: string } | null }).sent_profile;

  return (
    <div className="space-y-3">
      <DesktopWorkspaceTabs
        tabs={[
          { label: "Loads", href: "/loads" },
          { label: snap.load_number, href: `/loads/${id}` },
          { label: "Share Snapshot", href: `/loads/${id}/share-history/${shareId}` },
        ]}
      />
      <PageHeader
        title={`Shared Profile Snapshot -- ${snap.load_number}`}
        description={`Exactly what was generated and sent to ${share.recipient_email} on ${new Date(share.generated_at).toLocaleString()}. Frozen at generation time -- does not reflect any later changes.`}
      />

      <DesktopPanel>
        <DesktopPanelHeader title="Share Details" />
        <DesktopPanelBody>
          <div className="grid grid-cols-2 gap-x-4 gap-y-1.5 text-[13px]">
            <span className="text-muted-foreground">Recipient</span>
            <span className="text-right font-medium">{share.recipient_email}</span>
            <span className="text-muted-foreground">Profile Type</span>
            <span className="text-right capitalize">{share.profile_type}</span>
            <span className="text-muted-foreground">Status</span>
            <span className="text-right"><StatusBadge status={share.status} /></span>
            <span className="text-muted-foreground">Generated</span>
            <span className="text-right">{new Date(share.generated_at).toLocaleString()}{generatedBy ? ` by ${generatedBy.full_name}` : ""}</span>
            {share.sent_at && (
              <>
                <span className="text-muted-foreground">Sent</span>
                <span className="text-right">{new Date(share.sent_at).toLocaleString()}{sentBy ? ` by ${sentBy.full_name}` : ""}</span>
              </>
            )}
            {share.error && (
              <>
                <span className="text-muted-foreground">Error</span>
                <span className="text-right text-danger">{share.error}</span>
              </>
            )}
          </div>
          {share.storage_path && (
            <div className="mt-3 border-t border-desktop-border pt-2">
              <DocumentLinkButton label="Download Original PDF" getUrl={getProfileShareSignedUrl.bind(null, share.storage_path, true)} />
            </div>
          )}
        </DesktopPanelBody>
      </DesktopPanel>

      <DesktopPanel>
        <DesktopPanelHeader title="Load Information (as shared)" />
        <DesktopPanelBody>
          <div className="grid grid-cols-2 gap-x-4 gap-y-1.5 text-[13px]">
            <span className="text-muted-foreground">Broker / Customer</span>
            <span className="text-right font-medium">{snap.broker_name ?? "--"}</span>
            <span className="text-muted-foreground">Pickup</span>
            <span className="text-right">{snap.origin ?? "--"}</span>
            <span className="text-muted-foreground">Delivery</span>
            <span className="text-right">{snap.destination ?? "--"}</span>
            <span className="text-muted-foreground">Truck / Trailer</span>
            <span className="text-right">{[snap.truck_unit, snap.trailer_unit].filter(Boolean).join(" / ") || "--"}</span>
          </div>
        </DesktopPanelBody>
      </DesktopPanel>

      {snap.driver && (
        <DesktopPanel>
          <DesktopPanelHeader title="Driver Information (as shared)" />
          <DesktopPanelBody>
            <div className="grid grid-cols-2 gap-x-4 gap-y-1.5 text-[13px]">
              <span className="text-muted-foreground">Name</span>
              <span className="text-right font-medium">{snap.driver.name}</span>
              <span className="text-muted-foreground">Status</span>
              <span className="text-right"><StatusBadge status={snap.driver.status} /></span>
              <span className="text-muted-foreground">CDL</span>
              <span className="text-right">{snap.driver.cdl_class ?? "--"} <StatusBadge status={snap.driver.cdl_status} /></span>
              <span className="text-muted-foreground">Medical Card</span>
              <span className="text-right"><StatusBadge status={snap.driver.medical_card_status} /></span>
              <span className="text-muted-foreground">Years of Experience</span>
              <span className="text-right">{snap.driver.years_experience ?? "--"}</span>
              <span className="text-muted-foreground">Completed Trips</span>
              <span className="text-right">{snap.driver.completed_trips}</span>
            </div>
          </DesktopPanelBody>
        </DesktopPanel>
      )}

      {snap.carrier && (
        <DesktopPanel>
          <DesktopPanelHeader title="Carrier Information (as shared)" />
          <DesktopPanelBody>
            <div className="grid grid-cols-2 gap-x-4 gap-y-1.5 text-[13px]">
              <span className="text-muted-foreground">Name</span>
              <span className="text-right font-medium">{snap.carrier.name}</span>
              <span className="text-muted-foreground">MC / DOT</span>
              <span className="text-right">{snap.carrier.mc_number ?? "--"} / {snap.carrier.dot_number ?? "--"}</span>
              <span className="text-muted-foreground">Auto Liability</span>
              <span className="text-right"><StatusBadge status={snap.carrier.auto_liability_status} /></span>
              <span className="text-muted-foreground">Cargo Insurance</span>
              <span className="text-right"><StatusBadge status={snap.carrier.cargo_insurance_status} /></span>
              <span className="text-muted-foreground">Completed Loads</span>
              <span className="text-right">{snap.carrier.completed_loads}</span>
            </div>
          </DesktopPanelBody>
        </DesktopPanel>
      )}

      <Link href={`/loads/${id}`} className="inline-block text-xs font-medium text-primary hover:underline">
        &larr; Back to Load
      </Link>
    </div>
  );
}
