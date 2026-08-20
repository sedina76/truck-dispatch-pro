import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { getCurrentOrgId } from "@/lib/actions/records";
import { PageHeader } from "@/components/ui/page-header";
import { StatusBadge } from "@/components/ui/status-badge";

const PAGE_SIZE = 25;

// Org-wide Email History (spec section 27) -- server-side paginated (spec
// section 27: "Use server-side pagination", never the whole history
// loaded into the browser). email_send_log is the SAME table from 0039
// (0064 extends it in place, never renames it -- see that migration's own
// header comment). Same graceful pre-migration behavior as
// /settings/email: the new columns this page selects (delivery_status,
// from_name, to_addresses, email_purpose, ...) don't exist until 0064 is
// applied, so the query errors cleanly and shows a controlled message
// instead of a raw 500.
export default async function EmailHistoryPage({ searchParams }: { searchParams: Promise<{ status?: string; page?: string; q?: string }> }) {
  const sp = await searchParams;
  const supabase = await createClient();
  const orgId = await getCurrentOrgId();

  const page = Math.max(1, Number(sp.page) || 1);
  const from = (page - 1) * PAGE_SIZE;
  const to = from + PAGE_SIZE - 1;

  let query = supabase
    .from("email_send_log")
    .select("id, status, delivery_status, sent_at, created_at, from_name, from_email, recipient, to_addresses, subject, email_purpose, entity_type, load_id, invoice_id, error", { count: "exact" })
    .eq("organization_id", orgId)
    .order("created_at", { ascending: false })
    .range(from, to);

  if (sp.status && sp.status !== "all") {
    // "status" here means delivery_status for sent mail, or the attempt
    // status (blocked/failed) for everything else -- matched against
    // whichever column is populated for that row.
    query = sp.status === "blocked" || sp.status === "failed" ? query.eq("status", sp.status) : query.eq("delivery_status", sp.status);
  }
  if (sp.q) {
    query = query.or(`subject.ilike.%${sp.q}%,recipient.ilike.%${sp.q}%`);
  }

  const { data, error, count } = await query;

  if (error) {
    return (
      <div className="space-y-4">
        <PageHeader title="Email History" description="Every outgoing email this organization has sent." />
        <div className="rounded-md border border-dashed border-[var(--color-border)] bg-[var(--color-muted)]/30 p-6 text-sm text-[var(--color-text-muted)]">
          Email history database migration has not been applied yet. This page will become available once it is.
        </div>
      </div>
    );
  }

  const rows = data ?? [];
  const totalPages = Math.max(1, Math.ceil((count ?? 0) / PAGE_SIZE));

  return (
    <div className="space-y-4">
      <PageHeader title="Email History" description={`${count ?? 0} email${count === 1 ? "" : "s"} sent by this organization.`} />

      <form className="flex flex-wrap items-center gap-2">
        <input name="q" defaultValue={sp.q ?? ""} placeholder="Search subject or recipient..." className="h-8 w-64 rounded-md border border-border bg-card px-2 text-sm shadow-elevation-1" />
        <select name="status" defaultValue={sp.status ?? "all"} className="h-8 rounded-md border border-border bg-card px-2 text-sm shadow-elevation-1">
          <option value="all">All Statuses</option>
          <option value="sent">Sent</option>
          <option value="delivered">Delivered</option>
          <option value="bounced">Bounced</option>
          <option value="failed">Failed</option>
          <option value="blocked">Blocked</option>
        </select>
        <button type="submit" className="h-8 rounded-md border border-border bg-card px-3 text-sm shadow-elevation-1 hover:bg-muted">
          Filter
        </button>
      </form>

      <div className="overflow-x-auto rounded-md border border-[var(--color-border)]">
        <table className="w-full text-sm">
          <thead className="bg-[var(--color-muted)]/40 text-left text-xs font-medium text-muted-foreground">
            <tr>
              <th className="px-3 py-2">Status</th>
              <th className="px-3 py-2">Sent</th>
              <th className="px-3 py-2">From</th>
              <th className="px-3 py-2">To</th>
              <th className="px-3 py-2">Subject</th>
              <th className="px-3 py-2">Purpose</th>
              <th className="px-3 py-2">Record</th>
            </tr>
          </thead>
          <tbody>
            {rows.length === 0 && (
              <tr>
                <td colSpan={7} className="px-3 py-6 text-center text-muted-foreground">
                  No emails found.
                </td>
              </tr>
            )}
            {rows.map((r) => (
              <tr key={r.id} className="border-t border-[var(--color-border)]">
                <td className="px-3 py-2">
                  <StatusBadge status={r.delivery_status ?? r.status} />
                  {r.error && <p className="mt-0.5 max-w-[180px] truncate text-xs text-danger" title={r.error}>{r.error}</p>}
                </td>
                <td className="px-3 py-2 text-xs text-muted-foreground">{new Date(r.sent_at ?? r.created_at).toLocaleString()}</td>
                <td className="max-w-[200px] truncate px-3 py-2 text-xs">{r.from_name ? `${r.from_name} <${r.from_email}>` : "--"}</td>
                <td className="max-w-[200px] truncate px-3 py-2 text-xs">{(r.to_addresses && r.to_addresses.length > 0 ? r.to_addresses.join(", ") : r.recipient) ?? "--"}</td>
                <td className="max-w-[240px] truncate px-3 py-2">{r.subject}</td>
                <td className="px-3 py-2 text-xs text-muted-foreground">{r.email_purpose ?? r.entity_type}</td>
                <td className="px-3 py-2 text-xs">
                  {r.invoice_id ? (
                    <Link href={`/invoices/${r.invoice_id}`} className="text-primary hover:underline">
                      Invoice
                    </Link>
                  ) : r.load_id ? (
                    <Link href={`/loads/${r.load_id}`} className="text-primary hover:underline">
                      Load
                    </Link>
                  ) : (
                    "--"
                  )}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      {totalPages > 1 && (
        <div className="flex items-center justify-between text-sm">
          <span className="text-muted-foreground">
            Page {page} of {totalPages}
          </span>
          <div className="flex gap-2">
            {page > 1 && (
              <Link href={`?${new URLSearchParams({ ...sp, page: String(page - 1) }).toString()}`} className="rounded-md border border-border bg-card px-3 py-1.5 shadow-elevation-1 hover:bg-muted">
                Previous
              </Link>
            )}
            {page < totalPages && (
              <Link href={`?${new URLSearchParams({ ...sp, page: String(page + 1) }).toString()}`} className="rounded-md border border-border bg-card px-3 py-1.5 shadow-elevation-1 hover:bg-muted">
                Next
              </Link>
            )}
          </div>
        </div>
      )}
    </div>
  );
}
