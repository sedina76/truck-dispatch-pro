import Link from "next/link";
import { notFound } from "next/navigation";
import { AlertTriangle } from "lucide-react";
import { createClient } from "@/lib/supabase/server";
import { StatusBadge } from "@/components/ui/status-badge";
import { requireRole } from "@/lib/auth/require-role";
import { listBrokerPacketCandidates } from "@/lib/broker-packets/candidates";
import { DEFAULT_DOCUMENT_TYPES, DOCUMENT_LABELS, OPTIONAL_DOCUMENT_TYPES } from "@/lib/broker-packets/types";
import {
  addBrokerPacketItem,
  deleteBrokerPacketDraft,
  generateBrokerPacket,
  moveBrokerPacketItem,
  removeBrokerPacketItem,
  voidBrokerPacket,
} from "../actions";
import { PacketSendForm } from "./packet-send-form";
import { RequirementsChecklist } from "./requirements-checklist";
import { DocumentToggle } from "./document-toggle";
import { MAX_EMAIL_ATTACHMENT_BYTES } from "@/lib/broker-packets/types";

const DOWNLOAD_ROLES = new Set(["owner", "admin", "dispatcher", "accountant"]);
const SEND_ROLES = new Set(["owner", "admin", "dispatcher"]);

// Presentation only -- workflow simplification. Every server action,
// eligibility rule, requirement, guard, generate/void condition, and the
// send flow are byte-for-byte the same as before; only the page layout,
// section grouping, and the add/remove control surface changed.

const STATUS_SUFFIX: Record<string, string> = {
  draft: "Draft",
  generating: "Generating",
  generated: "Generated",
  sent: "Sent",
  superseded: "Superseded",
  failed: "Generation failed",
  voided: "Voided",
};

// Candidate status -> compact badge (spec: READY / MISSING / EXPIRED / UNVERIFIED).
const CANDIDATE_BADGE: Record<string, { label: string; cls: string }> = {
  eligible: { label: "READY", cls: "bg-success/10 text-success" },
  missing: { label: "MISSING", cls: "bg-destructive/10 text-destructive" },
  expired: { label: "EXPIRED", cls: "bg-destructive/10 text-destructive" },
  unverified: { label: "UNVERIFIED", cls: "bg-warning/10 text-warning" },
  rejected: { label: "REJECTED", cls: "bg-destructive/10 text-destructive" },
};
function candidateBadge(status: string) {
  return CANDIDATE_BADGE[status] ?? { label: "NOT ELIGIBLE", cls: "bg-warning/10 text-warning" };
}

export default async function BrokerPacketDetailPage({ params }: { params: Promise<{ id: string; packetId: string }> }) {
  const { id, packetId } = await params;
  const role = await requireRole(["owner", "admin", "dispatcher", "accountant", "viewer"]);
  const canOperate = ["owner", "admin", "dispatcher"].includes(role);
  const canVoid = role === "owner" || role === "admin";
  const canDownload = DOWNLOAD_ROLES.has(role);
  const supabase = await createClient();

  const [{ data: broker }, { data: packet }] = await Promise.all([
    supabase.from("brokers").select("id,legal_name,email").eq("id", id).maybeSingle(),
    supabase.from("broker_packets").select("*").eq("id", packetId).eq("broker_id", id).maybeSingle(),
  ]);
  if (!broker || !packet) notFound();

  const eligibleToSend = ["generated", "sent"].includes(packet.status);
  const [{ data: items }, { data: requirements }, { data: primaryContact }, { data: profile }, { data: sendHistory }] = await Promise.all([
    supabase.from("broker_packet_items").select("*").eq("packet_id", packetId).order("display_order"),
    supabase.from("broker_packet_requirements").select("*").eq("broker_id", id),
    supabase.from("broker_contacts").select("email").eq("broker_id", id).eq("is_primary", true).maybeSingle(),
    supabase.from("profiles").select("organizations(name)").eq("id", (await supabase.auth.getUser()).data.user?.id ?? "").single(),
    canDownload && (SEND_ROLES.has(role) || DOWNLOAD_ROLES.has(role))
      ? supabase.from("email_send_log").select("id,recipient,status,delivery_status,sent_by,created_at,sent_at,error").eq("broker_packet_id", packetId).order("created_at", { ascending: false })
      : Promise.resolve({ data: null }),
  ]);
  const organizationName = (profile as unknown as { organizations: { name: string } | null } | null)?.organizations?.name ?? "Your organization";
  const defaultRecipientEmail = primaryContact?.email || broker.email || "";
  const requiredTypes = new Set((requirements ?? []).filter((r) => r.is_required).map((r) => r.document_type));
  const includedTypes = new Set((items ?? []).map((i) => i.document_type));
  const missingRequired = [...requiredTypes].filter((t) => !includedTypes.has(t));

  const isDraft = packet.status === "draft";
  const candidates = isDraft && canOperate ? await listBrokerPacketCandidates(id, packet.carrier_id) : [];
  const itemIds = (items ?? []).map((i) => i.id);
  const itemByType = new Map((items ?? []).map((i) => [i.document_type, i]));
  const selectedCount = packet.document_count ?? (items ?? []).length;
  const generateBlocked = selectedCount < 1 || missingRequired.length > 0;

  const requiredLabels = [...requiredTypes].map((t) => DOCUMENT_LABELS[t] ?? t);

  return (
    <div className="min-w-0 space-y-4">
      <Link href={`/brokers/${id}?tab=broker-packets`} className="text-xs text-muted-foreground hover:text-foreground">
        ← Broker Packets
      </Link>

      {/* A. Compact header */}
      <div className="min-w-0 space-y-1">
        <div className="flex flex-wrap items-center gap-2">
          <h1 className="wrap-break-word text-xl font-semibold">{broker.legal_name}</h1>
          <StatusBadge status={packet.status} />
        </div>
        <p className="text-sm text-muted-foreground">
          Broker Packet · {packet.version ? `v${packet.version}` : STATUS_SUFFIX[packet.status] ?? packet.status}
          {isDraft && " — select the documents to include, then generate the packet."}
        </p>
      </div>

      {packet.status === "failed" && packet.failure_reason && (
        <p className="wrap-break-word rounded-md border border-destructive/40 bg-destructive/5 p-3 text-sm text-destructive">{packet.failure_reason}</p>
      )}
      {packet.status === "voided" && packet.void_reason && (
        <p className="wrap-break-word rounded-md border p-3 text-sm text-muted-foreground">Voided: {packet.void_reason}</p>
      )}

      {/* I. Generated / sent / superseded -- emphasize the artifact + actions */}
      {["generated", "sent", "superseded"].includes(packet.status) && (
        <div className="min-w-0 space-y-3 rounded-md border bg-card p-4">
          <p className="text-sm">
            Generated {packet.generated_at ? new Date(packet.generated_at).toLocaleDateString(undefined, { year: "numeric", month: "short", day: "numeric" }) : "--"}
            {" · "}
            {selectedCount} document{selectedCount === 1 ? "" : "s"} · {packet.page_count} pages ·{" "}
            {packet.generated_file_size_bytes ? `${Math.ceil(packet.generated_file_size_bytes / 1024)} KB` : "--"}
            {packet.status === "superseded" && <span className="ml-1 text-muted-foreground">· Superseded (not current)</span>}
          </p>
          {canDownload && (
            <div className="flex flex-wrap gap-2">
              <a
                className="inline-flex h-8 items-center rounded-md bg-primary px-3 text-xs font-medium text-primary-foreground"
                href={`/brokers/${id}/packets/${packetId}/pdf`}
                target="_blank"
                rel="noreferrer"
              >
                View PDF
              </a>
              <a className="inline-flex h-8 items-center rounded-md border px-3 text-xs font-medium" href={`/brokers/${id}/packets/${packetId}/pdf?download=1`}>
                Download
              </a>
            </div>
          )}
        </div>
      )}

      {/* J. Send -- primary action once the packet is ready */}
      {eligibleToSend && SEND_ROLES.has(role) && (
        <PacketSendForm
          brokerId={id}
          packetId={packetId}
          brokerLegalName={broker.legal_name}
          organizationName={organizationName}
          version={packet.version ?? 0}
          defaultRecipientEmail={defaultRecipientEmail}
          hasBeenSent={packet.status === "sent"}
          tooLarge={(packet.generated_file_size_bytes ?? 0) > MAX_EMAIL_ATTACHMENT_BYTES}
        />
      )}

      {/* C/D/E. Documents -- the primary section in a draft */}
      {isDraft && canOperate && (
        <section className="min-w-0 space-y-2">
          <div className="flex items-baseline justify-between gap-2">
            <h2 className="text-base font-semibold">Documents</h2>
            <span className="text-xs text-muted-foreground">Check to include in the packet</span>
          </div>

          {missingRequired.length > 0 && (
            <p className="flex items-start gap-1.5 rounded-md border border-destructive/40 bg-destructive/5 p-2.5 text-sm text-destructive">
              <AlertTriangle className="mt-0.5 size-4 shrink-0" />
              <span>
                {missingRequired.length} required document{missingRequired.length === 1 ? "" : "s"} not yet included:{" "}
                <span className="font-medium">{missingRequired.map((t) => DOCUMENT_LABELS[t] ?? t).join(", ")}</span>
              </span>
            </p>
          )}

          <div className="min-w-0 divide-y rounded-md border bg-card">
            {candidates.map((c) => {
              const isSelected = includedTypes.has(c.documentType);
              const item = itemByType.get(c.documentType);
              const isRequired = requiredTypes.has(c.documentType);
              const badge = candidateBadge(c.status);
              const canToggle = isSelected || (c.status === "eligible" && !!c.documentId);
              return (
                <div key={`${c.documentType}-${c.documentId ?? "missing"}`} className="flex min-w-0 items-start gap-2.5 p-2.5 text-sm">
                  <div className="pt-0.5">
                    <DocumentToggle
                      checked={isSelected}
                      disabled={!canToggle}
                      documentId={c.documentId}
                      addAction={c.documentId && !isSelected ? addBrokerPacketItem.bind(null, id, packetId) : null}
                      removeAction={item ? removeBrokerPacketItem.bind(null, id, packetId, item.id) : null}
                    />
                  </div>
                  <div className="min-w-0 flex-1">
                    <div className="flex flex-wrap items-center gap-1.5">
                      <span className="wrap-break-word font-medium">{c.label}</span>
                      {isRequired && (
                        <span className="shrink-0 rounded bg-muted px-1.5 py-0.5 text-[10px] font-medium uppercase text-muted-foreground">Required</span>
                      )}
                      <span className={`shrink-0 rounded px-1.5 py-0.5 text-[10px] font-medium uppercase ${badge.cls}`}>{badge.label}</span>
                      {isRequired && !isSelected && c.status === "eligible" && (
                        <span className="shrink-0 text-[11px] font-medium text-destructive">Required — not selected</span>
                      )}
                    </div>
                    <p className="wrap-break-word text-xs text-muted-foreground">{c.statusMessage}</p>
                  </div>
                </div>
              );
            })}
            {candidates.length === 0 && <p className="p-2.5 text-sm text-muted-foreground">No candidate documents found for this carrier.</p>}
          </div>

          {/* F. Reorder -- the one unique bit of the old "Selected Documents"
              section, kept compact and only when order actually matters. */}
          {(items?.length ?? 0) > 1 && (
            <div className="min-w-0 space-y-1 rounded-md border bg-card p-2.5">
              <p className="text-xs font-medium text-muted-foreground">Packet order</p>
              {(items ?? []).map((item, index) => (
                <div key={item.id} className="flex min-w-0 items-center justify-between gap-2 text-sm">
                  <span className="min-w-0 wrap-break-word">
                    {index + 1}. {DOCUMENT_LABELS[item.document_type] ?? item.document_type}
                  </span>
                  <span className="flex shrink-0 items-center gap-1">
                    <form action={moveBrokerPacketItem.bind(null, id, packetId, itemIds, item.id, -1)}>
                      <button disabled={index === 0} className="rounded border px-1.5 py-0.5 text-xs disabled:opacity-30">↑</button>
                    </form>
                    <form action={moveBrokerPacketItem.bind(null, id, packetId, itemIds, item.id, 1)}>
                      <button disabled={index === (items?.length ?? 0) - 1} className="rounded border px-1.5 py-0.5 text-xs disabled:opacity-30">↓</button>
                    </form>
                  </span>
                </div>
              ))}
            </div>
          )}

          {/* B. Requirements -- collapsed by default, full editor preserved inside */}
          <details className="min-w-0 rounded-md border bg-card">
            <summary className="flex cursor-pointer flex-wrap items-center gap-2 p-2.5 text-sm">
              <span className="font-medium">Requirements</span>
              <span className="text-xs text-muted-foreground">
                {requiredTypes.size} required{requiredLabels.length > 0 ? ` · ${requiredLabels.join(", ")}` : ""}
              </span>
              <span className="ml-auto text-xs text-primary">Edit requirements</span>
            </summary>
            <div className="border-t p-2.5">
              <p className="mb-2 text-xs text-muted-foreground">
                Changing a requirement here only affects future packets for this broker — it never touches an already-generated one.
              </p>
              <RequirementsChecklist
                brokerId={id}
                documentTypes={[...DEFAULT_DOCUMENT_TYPES, ...OPTIONAL_DOCUMENT_TYPES]}
                documentLabels={DOCUMENT_LABELS}
                initialRequired={Object.fromEntries((requirements ?? []).map((r) => [r.document_type, r.is_required]))}
              />
            </div>
          </details>
        </section>
      )}

      {/* G. Generate action bar (draft) */}
      {isDraft && canOperate && (
        <div className="min-w-0 rounded-md border bg-card p-3">
          <div className="flex flex-wrap items-center justify-between gap-2">
            <div className="min-w-0 text-sm">
              <p className="font-medium">
                {selectedCount} document{selectedCount === 1 ? "" : "s"} selected
              </p>
              <p className={missingRequired.length > 0 ? "text-xs text-destructive" : "text-xs text-success"}>
                {missingRequired.length > 0
                  ? `${missingRequired.length} required document${missingRequired.length === 1 ? "" : "s"} missing`
                  : "All required documents included"}
              </p>
            </div>
            <form action={generateBrokerPacket.bind(null, id, packetId)}>
              <button
                disabled={generateBlocked}
                className="h-9 rounded-md bg-primary px-4 text-sm font-medium text-primary-foreground disabled:opacity-40"
              >
                Generate Packet
              </button>
            </form>
          </div>
        </div>
      )}

      {/* generating -- Resume */}
      {packet.status === "generating" && (
        <div className="min-w-0 space-y-2 rounded-md border bg-card p-3 text-sm">
          <p className="text-muted-foreground">
            This packet reserved version {packet.version} and is ready to render. If generation was interrupted, Resume Generation
            continues from this exact reserved state — it never creates a new version.
          </p>
          {canOperate && (
            <form action={generateBrokerPacket.bind(null, id, packetId)}>
              <button className="h-9 rounded-md bg-primary px-3 text-sm font-medium text-primary-foreground">Resume Generation</button>
            </form>
          )}
        </div>
      )}

      {/* Documents included -- read-only, once generated */}
      {!isDraft && (items?.length ?? 0) > 0 && (
        <details className="min-w-0 rounded-md border bg-card" open>
          <summary className="cursor-pointer p-2.5 text-sm font-medium">Documents included ({items?.length ?? 0})</summary>
          <div className="divide-y border-t">
            {(items ?? []).map((item, index) => (
              <div key={item.id} className="min-w-0 p-2.5 text-sm">
                <span className="font-medium">
                  {index + 1}. {DOCUMENT_LABELS[item.document_type] ?? item.document_type}
                </span>
                <span className="block text-xs text-muted-foreground">{item.source_filename}</span>
              </div>
            ))}
          </div>
        </details>
      )}

      {/* H. History -- collapsed; compact when empty */}
      {sendHistory !== null && (
        <details className="min-w-0 rounded-md border bg-card" open={!!sendHistory?.length}>
          <summary className="flex cursor-pointer items-center gap-2 p-2.5 text-sm">
            <span className="font-medium">History</span>
            <span className="text-xs text-muted-foreground">{sendHistory?.length ? `${sendHistory.length} send${sendHistory.length === 1 ? "" : "s"}` : "Not sent yet"}</span>
          </summary>
          {!!sendHistory?.length && (
            <div className="min-w-0 space-y-2 border-t p-2.5">
              {sendHistory.map((entry) => (
                <div key={entry.id} className="min-w-0 wrap-break-word rounded border p-2 text-sm">
                  <div className="flex flex-wrap items-center justify-between gap-2">
                    <span className="min-w-0 wrap-break-word font-medium">{entry.recipient}</span>
                    <span
                      className={`shrink-0 rounded px-1.5 py-0.5 text-[10px] uppercase ${
                        entry.status === "sent" ? "bg-success/10 text-success" : entry.status === "queued" ? "bg-warning/10 text-warning" : "bg-destructive/10 text-destructive"
                      }`}
                    >
                      {entry.status}
                    </span>
                  </div>
                  <p className="text-xs text-muted-foreground">{new Date(entry.sent_at ?? entry.created_at).toLocaleString()}</p>
                </div>
              ))}
            </div>
          )}
        </details>
      )}

      {/* Destructive actions -- de-emphasized at the bottom */}
      {((isDraft && canOperate) || (canVoid && ["draft", "generated", "sent"].includes(packet.status))) && (
        <div className="min-w-0 space-y-2 border-t pt-3">
          {isDraft && canOperate && (
            <form action={deleteBrokerPacketDraft.bind(null, id, packetId)}>
              <button className="h-8 rounded-md border px-3 text-xs text-destructive">Delete Draft</button>
            </form>
          )}
          {canVoid && ["draft", "generated", "sent"].includes(packet.status) && (
            <form action={voidBrokerPacket.bind(null, id, packetId)} className="flex flex-wrap items-end gap-2">
              <label className="min-w-0 flex-1 space-y-1 text-xs">
                <span className="font-medium">Void reason</span>
                <input name="reason" required className="h-8 w-full min-w-0 rounded-md border bg-background px-3 text-sm" />
              </label>
              <button className="h-8 shrink-0 rounded-md border px-3 text-xs text-destructive">Void Packet</button>
            </form>
          )}
        </div>
      )}
    </div>
  );
}
