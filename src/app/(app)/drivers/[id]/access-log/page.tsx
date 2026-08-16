import Link from "next/link";
import { notFound } from "next/navigation";
import { ArrowLeft } from "lucide-react";
import { createClient } from "@/lib/supabase/server";
import { PageHeader } from "@/components/ui/page-header";
import { EmptyState } from "@/components/ui/empty-state";

export default async function DriverAccessLogPage({
  params,
}: {
  params: Promise<{ id: string }>;
}) {
  const { id } = await params;
  const supabase = await createClient();

  const { data: driver } = await supabase.from("drivers").select("first_name, last_name").eq("id", id).single();
  if (!driver) notFound();

  const { data: logs } = await supabase
    .from("driver_pii_access_log")
    .select("id, field_name, reason, accessed_at, profiles(full_name)")
    .eq("driver_id", id)
    .order("accessed_at", { ascending: false });

  return (
    <div className="space-y-6">
      <Link href={`/drivers/${id}`} className="inline-flex items-center gap-1.5 text-sm text-muted-foreground hover:text-foreground">
        <ArrowLeft className="size-4" />
        Back to {driver.first_name} {driver.last_name}
      </Link>

      <PageHeader
        title="Sensitive Data Access Log"
        description={`Every time someone revealed ${driver.first_name} ${driver.last_name}'s SSN or direct deposit numbers.`}
      />

      {!logs || logs.length === 0 ? (
        <EmptyState title="No access recorded" description="Nobody has revealed this driver's sensitive data yet." />
      ) : (
        <div className="overflow-hidden rounded-xl border border-border bg-card shadow-elevation-1">
          <table className="w-full text-sm">
            <thead>
              <tr className="border-b border-border bg-muted/40 text-left text-xs font-medium uppercase tracking-wide text-muted-foreground">
                <th className="px-4 py-3">Field</th>
                <th className="px-4 py-3">Accessed By</th>
                <th className="px-4 py-3">Reason</th>
                <th className="px-4 py-3">When</th>
              </tr>
            </thead>
            <tbody>
              {(logs as unknown as { id: string; field_name: string; reason: string | null; accessed_at: string; profiles: { full_name: string } | null }[]).map(
                (log) => (
                  <tr key={log.id} className="border-b border-border last:border-0">
                    <td className="px-4 py-3 capitalize">{log.field_name.replace(/_/g, " ")}</td>
                    <td className="px-4 py-3">{log.profiles?.full_name ?? "Unknown"}</td>
                    <td className="px-4 py-3 text-muted-foreground">{log.reason ?? "--"}</td>
                    <td className="px-4 py-3 text-muted-foreground">{new Date(log.accessed_at).toLocaleString()}</td>
                  </tr>
                )
              )}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
}
