import Link from "next/link";
import { notFound } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { requireRole } from "@/lib/auth/require-role";
import { StatusBadge } from "@/components/ui/status-badge";
import { DOCUMENT_LABELS, MAX_EMAIL_ATTACHMENT_BYTES, type SetupPackageRow } from "@/lib/carrier-setup-packages/types";
import { PackageActions } from "./package-actions";

export default async function SetupPackageDetailPage({ params }: { params: Promise<{ id: string; packageId: string }> }) {
  const role = await requireRole(["owner", "admin", "dispatcher", "accountant"]);
  const { id, packageId } = await params;
  const supabase = await createClient();
  const [{ data }, { data: items }] = await Promise.all([
    supabase.from("carrier_setup_packages").select("*").eq("id", packageId).eq("onboarding_application_id", id).maybeSingle(),
    supabase.from("carrier_setup_package_items").select("document_type, source_filename, source_expiry_date, start_page, end_page").eq("package_id", packageId).order("display_order"),
  ]);
  if (!data) notFound();
  const pkg = data as unknown as SetupPackageRow;
  const canUsePdf = ["generated", "sent"].includes(pkg.status) && pkg.generated_storage_path;
  const canSend = ["owner", "admin", "dispatcher"].includes(role) && Boolean(canUsePdf) && (pkg.generated_file_size_bytes ?? Infinity) <= MAX_EMAIL_ATTACHMENT_BYTES;
  return <div className="mx-auto max-w-5xl space-y-4">
    <div className="flex flex-wrap items-start justify-between gap-3"><div><Link href={`/carriers/onboarding/${id}`} className="text-[12.5px] text-primary hover:underline">Carrier Onboarding</Link><div className="mt-1 flex items-center gap-2"><h1 className="text-xl font-semibold">Package v{pkg.version}</h1><StatusBadge status={pkg.status} /></div><p className="text-[13px] text-muted-foreground">{pkg.carrier_snapshot.legal_name}</p></div>{canUsePdf && <div className="flex gap-2"><a href={`/carriers/onboarding/${id}/setup-packages/${packageId}/pdf`} target="_blank" className="inline-flex h-8 items-center rounded-sm border border-desktop-border px-3 text-[13px] font-medium">View PDF</a><a href={`/carriers/onboarding/${id}/setup-packages/${packageId}/pdf?download=1`} className="inline-flex h-8 items-center rounded-sm bg-primary px-3 text-[13px] font-medium text-primary-foreground">Download</a></div>}</div>
    <section className="grid gap-3 rounded-md border border-desktop-border bg-card p-4 sm:grid-cols-2 lg:grid-cols-4"><Fact label="Generated" value={pkg.generated_at ? new Date(pkg.generated_at).toLocaleString() : "-"} /><Fact label="Prepared For" value={pkg.prepared_for_name || pkg.recipient_name || "Generic"} /><Fact label="Documents" value={String(pkg.document_count)} /><Fact label="Pages" value={pkg.page_count ? String(pkg.page_count) : "-"} /></section>
    {pkg.status === "failed" && <div className="rounded-md border border-danger/30 bg-danger/5 p-3 text-[13px] text-danger">Generation failed. This version has no usable PDF.</div>}
    {pkg.status === "voided" && <div className="rounded-md border border-warning/30 bg-warning/5 p-3 text-[13px] text-warning">Voided: {pkg.void_reason}</div>}
    <section className="rounded-md border border-desktop-border bg-card"><div className="border-b border-desktop-border p-3"><h2 className="text-[14px] font-semibold">Package Contents</h2></div><ul className="divide-y divide-desktop-border">{(items ?? []).map((item) => <li key={item.source_filename} className="flex flex-wrap items-center justify-between gap-2 px-3 py-2.5 text-[12.5px]"><div><p className="font-medium">{DOCUMENT_LABELS[item.document_type] ?? item.document_type.replaceAll("_", " ")}</p><p className="text-muted-foreground">{item.source_filename}</p></div><span className="text-muted-foreground">{item.start_page ? `Pages ${item.start_page}${item.end_page !== item.start_page ? `-${item.end_page}` : ""}` : "Pending"}</span></li>)}</ul></section>
    <PackageActions packageId={pkg.id} applicationId={id} legalName={pkg.carrier_snapshot.legal_name} mcNumber={pkg.carrier_snapshot.mc_number ?? ""} organizationName={pkg.organization_snapshot.name} defaultRecipientName={pkg.recipient_name ?? ""} defaultRecipientEmail={pkg.recipient_email ?? ""} canSend={canSend} tooLarge={Boolean(canUsePdf && (pkg.generated_file_size_bytes ?? 0) > MAX_EMAIL_ATTACHMENT_BYTES)} canVoid={["owner", "admin"].includes(role) && ["generated", "sent"].includes(pkg.status)} hasBeenSent={pkg.status === "sent"} />
  </div>;
}
function Fact({ label, value }: { label: string; value: string }) { return <div><p className="text-[11px] font-medium uppercase tracking-wide text-muted-foreground">{label}</p><p className="mt-1 text-[13px] font-medium">{value}</p></div>; }
