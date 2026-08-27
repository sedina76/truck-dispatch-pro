import { createClient } from "@/lib/supabase/server";
import { toCsv, csvResponse, formatMoney } from "@/lib/export/csv";
import { FINANCIAL_ROLES, type OrgRole } from "@/lib/auth/require-role";

type Row = {
  id: string;
  load_number: string;
  status: string;
  equipment_type: string | null;
  rate?: number;
  total_miles: number | null;
  brokers: { company_name: string } | null;
  customers: { company_name: string } | null;
};

// Mirrors loads/page.tsx's own query+filters exactly (q, pod_missing isn't
// filterable server-side there either -- it's a POD-verification lookup,
// not a plain column filter, so it's intentionally left out of the export
// scope note below rather than silently ignored).
//
// Phase 2G.9 (item 3): this route is not covered by any layout guard
// (Loads is Operations, open to every role) and previously exported
// rate unconditionally in the CSV. Same role-gated column selection as
// loads/page.tsx.
//
// Schema-drift repair: `rate` was dropped from public.loads by
// 0069_financial_column_removal.sql -- selecting it directly here (as
// this route still did) made the entire export fail for every
// FINANCIAL_ROLES user, since PostgREST rejects a select naming a column
// that no longer exists. load_financials.rate is the authoritative source
// now (same writer-cutover every other rate-reading surface in this app
// already follows -- see loads/actions.ts, dispatch/new/page.tsx,
// invoices/new/page.tsx, reports/page.tsx, reports/broker-performance/
// page.tsx): a separate query plus a load_id -> rate Map, never a nested
// load_financials(...) embed -- no other file in this codebase embeds a
// *_financials extension table that way, so this stays consistent with
// the established convention rather than introducing a new one. Fetched
// only when canSeeFinancials is true, matching the column's existing role
// gate exactly.
//
// Integrity hardening: a load with no load_financials row must never be
// exported as a $0.00 rate -- that would be indistinguishable from a real,
// stored $0.00 rate (a load genuinely priced at zero is a valid, if rare,
// state -- see 0038_profitability_zero_rate_fix.sql's own "never convert
// missing to $0" principle, applied here to this surface too). rateByLoadId
// already distinguishes the two cases correctly (a real 0 is a present Map
// entry with value 0; a missing row is simply absent from the Map) -- the
// bug was only ever in how that distinction got collapsed at format time.
// Fixed by failing the whole export closed rather than silently rendering
// a wrong number: this route creates/modifies nothing, it only refuses to
// produce a CSV it cannot vouch for.
export async function GET(req: Request) {
  const { searchParams } = new URL(req.url);
  const q = searchParams.get("q");

  const supabase = await createClient();
  const { data: roleData } = await supabase.rpc("current_role");
  const canSeeFinancials = FINANCIAL_ROLES.includes((roleData as OrgRole | null) ?? ("viewer" as OrgRole));

  let query = supabase
    .from("loads")
    .select("id, load_number, status, equipment_type, total_miles, brokers(company_name), customers(company_name)")
    .order("created_at", { ascending: false });
  if (q) query = query.ilike("load_number", `%${q}%`);

  const { data } = await query;
  const baseRows = (data ?? []) as unknown as Row[];

  // rateByLoadId only ever gains an entry for a load_id that actually has a
  // load_financials row -- a real stored rate of exactly 0 is still a
  // present entry (value 0), correctly distinct from an absent one.
  const rateByLoadId = new Map<string, number>();
  if (canSeeFinancials && baseRows.length > 0) {
    const { data: financials } = await supabase
      .from("load_financials")
      .select("load_id, rate")
      .in("load_id", baseRows.map((r) => r.id));
    for (const row of financials ?? []) rateByLoadId.set(row.load_id, Number(row.rate));

    // Fail closed: exporting is refused entirely (no partial/best-effort
    // CSV) rather than silently rendering a missing financial record as a
    // legitimate $0.00 rate. This never writes or creates anything -- the
    // missing load_financials row itself is a separate, pre-existing data
    // gap this route has no business fixing on its own.
    const missingLoadNumbers = baseRows.filter((r) => !rateByLoadId.has(r.id)).map((r) => r.load_number);
    if (missingLoadNumbers.length > 0) {
      return new Response(
        `Cannot export: missing financial record(s) for load(s) ${missingLoadNumbers.join(", ")}. Rate cannot be safely represented in the CSV for these loads until their load_financials record is restored. Contact support before retrying this export.`,
        { status: 422, headers: { "Content-Type": "text/plain; charset=utf-8" } }
      );
    }
  }
  const rows = baseRows.map((r) => ({ ...r, rate: rateByLoadId.get(r.id) }));

  const csv = toCsv(rows, [
    { header: "Load #", value: (r) => r.load_number },
    { header: "Source", value: (r) => r.brokers?.company_name ?? r.customers?.company_name ?? "" },
    { header: "Equipment", value: (r) => r.equipment_type ?? "" },
    { header: "Miles", value: (r) => r.total_miles ?? "" },
    // Every row is guaranteed a present rateByLoadId entry by this point
    // (the check above already returned early otherwise) -- `?? 0` is
    // unreachable defensive code, not a re-introduction of the bug this
    // hardening fixes: it exists only because TypeScript can't prove that
    // guarantee across the intervening .map() call, not as a real fallback.
    ...(canSeeFinancials ? [{ header: "Rate", value: (r: Row) => formatMoney(r.rate ?? 0) }] : []),
    { header: "Status", value: (r) => r.status },
  ]);

  return csvResponse(csv, "loads");
}
