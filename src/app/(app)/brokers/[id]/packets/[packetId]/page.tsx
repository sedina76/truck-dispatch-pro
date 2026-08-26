import Link from "next/link";
import { notFound } from "next/navigation";
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
import { MAX_EMAIL_ATTACHMENT_BYTES } from "@/lib/broker-packets/types";

const DOWNLOAD_ROLES = new Set(["owner", "admin", "dispatcher", "accountant"]);
const SEND_ROLES = new Set(["owner", "admin", "dispatcher"]);

const STATUS_SUBTEXT: Record<string, string> = {
  draft: "Draft — select documents, then generate.",
  generating: "Generating — rendering the PDF and uploading it to secure storage.",
  generated: "Ready to send.",
  sent: "Sent — see send history below.",
  superseded: "Historical packet — not current. A newer version now represents this broker.",
  failed: "Generation failed — cannot send. Start a new draft to try again.",
  voided: "Voided — historical artifact retained where permitted.",
};

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
    // Authoritative recipient source (2M.4 section 6): the broker's
    // designated primary contact of any type, falling back to the
    // broker's own base email -- never guessed, never invented.
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

  return (
    <div className="min-w-0 space-y-4">
      <Link href={`/brokers/${id}?tab=broker-packets`} className="text-xs text-muted-foreground hover:text-foreground">
        ← Broker Packets
      </Link>
      <div className="flex flex-wrap items-center gap-2">
        <h1 className="wrap-break-word text-xl font-semibold">
          {broker.legal_name} — {packet.version ? `Broker Packet v${packet.version}` : "Broker Packet Draft"}
        </h1>
        <StatusBadge status={packet.status} />
      </div>
      <p className="text-sm text-muted-foreground">{STATUS_SUBTEXT[packet.status]}</p>

      {packet.status === "failed" && packet.failure_reason && (
        <p className="wrap-break-word rounded-md border border-destructive/40 bg-destructive/5 p-3 text-sm text-destructive">{packet.failure_reason}</p>
      )}
      {packet.status === "voided" && packet.void_reason && (
        <p className="wrap-break-word rounded-md border p-3 text-sm text-muted-foreground">Voided: {packet.void_reason}</p>
      )}
      {["generated", "sent", "superseded"].includes(packet.status) && (
        <div className="min-w-0 space-y-1 rounded-md border bg-card p-3 text-sm">
          <p>
            Generated {packet.generated_at ? new Date(packet.generated_at).toLocaleString() : "--"} · {packet.page_count} pages ·{" "}
            {packet.generated_file_size_bytes ? `${Math.ceil(packet.generated_file_size_bytes / 1024)} KB` : "--"}
            {packet.status === "superseded" && <span className="ml-1 text-muted-foreground">· Superseded (not current)</span>}
          </p>
          {canDownload && (
            <div className="flex flex-wrap gap-2 pt-1">
              <a className="text-xs text-primary" href={`/brokers/${id}/packets/${packetId}/pdf`} target="_blank" rel="noreferrer">
                View
              </a>
              <a className="text-xs text-primary" href={`/brokers/${id}/packets/${packetId}/pdf?download=1`}>
                Download
              </a>
            </div>
          )}
        </div>
      )}

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

      {sendHistory !== null && (
        <section className="min-w-0 space-y-2 rounded-md border bg-card p-4">
          <h2 className="font-semibold">Send History</h2>
          {sendHistory?.length ? (
            <div className="min-w-0 space-y-2">
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
          ) : (
            <p className="text-sm text-muted-foreground">No email has been sent for this packet yet.</p>
          )}
        </section>
      )}

      {isDraft && canOperate && (
        <section className="min-w-0 space-y-2 rounded-md border bg-card p-4">
          <h2 className="font-semibold">Requirements Checklist</h2>
          <p className="text-xs text-muted-foreground">Changing a requirement here only affects future packets for this broker -- it never touches an already-generated one.</p>
          <RequirementsChecklist
            brokerId={id}
            documentTypes={[...DEFAULT_DOCUMENT_TYPES, ...OPTIONAL_DOCUMENT_TYPES]}
            documentLabels={DOCUMENT_LABELS}
            initialRequired={Object.fromEntries((requirements ?? []).map((r) => [r.document_type, r.is_required]))}
          />
        </section>
      )}

      {isDraft && canOperate && (
        <section className="min-w-0 space-y-2 rounded-md border bg-card p-4">
          <h2 className="font-semibold">Available Documents</h2>
          <div className="grid min-w-0 gap-2 sm:grid-cols-2">
            {candidates.map((c) => (
              <div key={`${c.documentType}-${c.documentId ?? "missing"}`} className="min-w-0 rounded border p-2 text-sm">
                <div className="flex min-w-0 items-center justify-between gap-2">
                  <span className="min-w-0 wrap-break-word font-medium">{c.label}</span>
                  <span
                    className={`shrink-0 rounded px-1.5 py-0.5 text-[10px] uppercase ${
                      c.status === "eligible" ? "bg-success/10 text-success" : c.status === "missing" ? "bg-destructive/10 text-destructive" : "bg-warning/10 text-warning"
                    }`}
                  >
                    {c.status}
                  </span>
                </div>
                <p className="wrap-break-word text-xs text-muted-foreground">{c.statusMessage}</p>
                {c.status === "eligible" && c.documentId && !includedTypes.has(c.documentType) && (
                  <form action={addBrokerPacketItem.bind(null, id, packetId)} className="mt-1">
                    <input type="hidden" name="document_id" value={c.documentId} />
                    <button className="text-xs text-primary">Add to packet</button>
                  </form>
                )}
              </div>
            ))}
          </div>
        </section>
      )}

      <section className="min-w-0 space-y-2 rounded-md border bg-card p-4">
        <h2 className="font-semibold">Selected Documents ({packet.document_count})</h2>
        {missingRequired.length > 0 && isDraft && (
          <p className="wrap-break-word text-sm text-destructive">Missing required: {missingRequired.map((t) => DOCUMENT_LABELS[t] ?? t).join(", ")}</p>
        )}
        <div className="min-w-0 space-y-2">
          {(items ?? []).map((item, index) => (
            <div key={item.id} className="flex min-w-0 items-center justify-between gap-2 rounded border p-2 text-sm">
              <div className="min-w-0 wrap-break-word">
                <span className="font-medium">{DOCUMENT_LABELS[item.document_type] ?? item.document_type}</span>
                <span className="block text-xs text-muted-foreground">{item.source_filename}</span>
              </div>
              {isDraft && canOperate && (
                <div className="flex shrink-0 items-center gap-1">
                  <form action={moveBrokerPacketItem.bind(null, id, packetId, itemIds, item.id, -1)}>
                    <button disabled={index === 0} className="rounded border px-1.5 py-0.5 text-xs disabled:opacity-30">
                      ↑
                    </button>
                  </form>
                  <form action={moveBrokerPacketItem.bind(null, id, packetId, itemIds, item.id, 1)}>
                    <button disabled={index === (items?.length ?? 0) - 1} className="rounded border px-1.5 py-0.5 text-xs disabled:opacity-30">
                      ↓
                    </button>
                  </form>
                  <form action={removeBrokerPacketItem.bind(null, id, packetId, item.id)}>
                    <button className="text-xs text-destructive">Remove</button>
                  </form>
                </div>
              )}
            </div>
          ))}
          {!items?.length && <p className="text-sm text-muted-foreground">No documents selected yet.</p>}
        </div>
      </section>

      {isDraft && canOperate && (
        <div className="flex flex-wrap gap-2">
          <form action={generateBrokerPacket.bind(null, id, packetId)}>
            <button disabled={packet.document_count < 1 || missingRequired.length > 0} className="h-9 rounded-md bg-primary px-3 text-sm font-medium text-primary-foreground disabled:opacity-40">
              Generate Packet
            </button>
          </form>
          <form action={deleteBrokerPacketDraft.bind(null, id, packetId)}>
            <button className="h-9 rounded-md border px-3 text-sm text-destructive">Delete Draft</button>
          </form>
        </div>
      )}
      {packet.status === "generating" && (
        <div className="min-w-0 space-y-2 rounded-md border bg-card p-3 text-sm">
          <p className="text-muted-foreground">
            This packet reserved version {packet.version} and is ready to render. If generation was interrupted, Resume
            Generation continues from this exact reserved state -- it never creates a new version.
          </p>
          {canOperate && (
            <form action={generateBrokerPacket.bind(null, id, packetId)}>
              <button className="h-9 rounded-md bg-primary px-3 text-sm font-medium text-primary-foreground">Resume Generation</button>
            </form>
          )}
        </div>
      )}
      {canVoid && ["draft", "generated", "sent"].includes(packet.status) && (
        <form action={voidBrokerPacket.bind(null, id, packetId)} className="flex flex-wrap items-end gap-2">
          <label className="min-w-0 flex-1 space-y-1 text-sm">
            <span className="font-medium">Void reason</span>
            <input name="reason" required className="h-9 w-full min-w-0 rounded-md border bg-background px-3" />
          </label>
          <button className="h-9 shrink-0 rounded-md border px-3 text-sm text-destructive">Void Packet</button>
        </form>
      )}
    </div>
  );
}
