import type { CompanyAccessKey } from "@/lib/superadmin/company-access";

// Pure helpers behind Platform Console -> Reports (no I/O, unit-tested).

export type ReportCompanyInput = {
  id: string;
  name: string;
  createdAt: string;
  planName: string | null;
  status: string | null;
  accessKey: CompanyAccessKey;
  accessLabel: string;
  accessDetail: string;
  trialEnd: string | null;
};

export type ReportUserInput = { id: string; organizationId: string | null; role: string | null; email: string | null; lastSignInAt: string | null };

export type AttentionReason = "locked" | "suspended" | "past_due" | "trial_ending" | "never_signed_in" | "inactive";

export type ReportRow = ReportCompanyInput & {
  ownerEmail: string | null;
  userCount: number;
  lastSignInAt: string | null;
  attention: AttentionReason[];
};

export const ATTENTION_LABEL: Record<AttentionReason, string> = {
  locked: "Locked out of the app",
  suspended: "Suspended",
  past_due: "Payment past due",
  trial_ending: "Trial ends within 14 days",
  never_signed_in: "Nobody has signed in yet",
  inactive: "No sign-in for 30+ days",
};

const DAY = 24 * 60 * 60 * 1000;

export function buildReportRows(companies: ReportCompanyInput[], users: ReportUserInput[], now: Date = new Date()): ReportRow[] {
  const byOrg = new Map<string, ReportUserInput[]>();
  for (const u of users) {
    if (!u.organizationId) continue;
    const list = byOrg.get(u.organizationId) ?? [];
    list.push(u);
    byOrg.set(u.organizationId, list);
  }

  return companies.map((c) => {
    const members = byOrg.get(c.id) ?? [];
    const owner = members.find((m) => m.role === "owner") ?? members[0] ?? null;
    const lastSignInAt = members.reduce<string | null>((latest, m) => (m.lastSignInAt && (!latest || m.lastSignInAt > latest) ? m.lastSignInAt : latest), null);

    const attention: AttentionReason[] = [];
    if (c.accessKey === "locked") attention.push("locked");
    if (c.accessKey === "suspended") attention.push("suspended");
    if (c.accessKey === "grace" || c.status === "past_due") attention.push("past_due");
    if (c.accessKey === "trial" && c.trialEnd) {
      const left = new Date(c.trialEnd).getTime() - now.getTime();
      if (left >= 0 && left <= 14 * DAY) attention.push("trial_ending");
    }
    if (c.accessKey !== "suspended") {
      if (!lastSignInAt) attention.push("never_signed_in");
      else if (now.getTime() - new Date(lastSignInAt).getTime() > 30 * DAY) attention.push("inactive");
    }

    return { ...c, ownerEmail: owner?.email ?? null, userCount: members.length, lastSignInAt, attention };
  });
}

/** Most urgent first: locked/suspended, then payment, trials, then activity; ties by newest signup. */
export function sortByAttention(rows: ReportRow[]): ReportRow[] {
  const weight = (r: ReportRow) =>
    r.attention.includes("locked") ? 0 : r.attention.includes("past_due") ? 1 : r.attention.includes("trial_ending") ? 2 : r.attention.includes("suspended") ? 3 : r.attention.length ? 4 : 5;
  return [...rows].sort((a, b) => weight(a) - weight(b) || b.createdAt.localeCompare(a.createdAt));
}

/** Last `months` calendar months (UTC) ending with the month of `now`, oldest first, with zero-filled counts. */
export function monthBuckets(dates: (string | null)[], months: number, now: Date = new Date(), values?: number[]): { key: string; label: string; count: number; total: number }[] {
  const out: { key: string; label: string; count: number; total: number }[] = [];
  for (let i = months - 1; i >= 0; i -= 1) {
    const d = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth() - i, 1));
    const key = `${d.getUTCFullYear()}-${String(d.getUTCMonth() + 1).padStart(2, "0")}`;
    out.push({ key, label: d.toLocaleString("en-US", { month: "short", year: "2-digit", timeZone: "UTC" }), count: 0, total: 0 });
  }
  const index = new Map(out.map((b, i) => [b.key, i]));
  dates.forEach((iso, i) => {
    if (!iso) return;
    const key = iso.slice(0, 7);
    const at = index.get(key);
    if (at === undefined) return;
    out[at].count += 1;
    out[at].total += values?.[i] ?? 0;
  });
  return out;
}

function csvCell(v: unknown): string {
  const s = v === null || v === undefined ? "" : String(v);
  // Neutralise spreadsheet formulas in user-entered text (CSV injection).
  const safe = /^[=+\-@\t\r]/.test(s) ? `'${s}` : s;
  return /[",\n\r]/.test(safe) ? `"${safe.replace(/"/g, '""')}"` : safe;
}

export function reportCsv(rows: ReportRow[]): string {
  const header = ["Company", "Access", "Plan", "Subscription status", "Owner email", "Users", "Last sign-in (UTC)", "Signed up (UTC)", "Trial ends (UTC)", "Needs attention"];
  const lines = rows.map((r) =>
    [
      r.name,
      r.accessLabel,
      r.planName ?? "",
      r.status ?? "none",
      r.ownerEmail ?? "",
      r.userCount,
      r.lastSignInAt ? r.lastSignInAt.slice(0, 16).replace("T", " ") : "never",
      r.createdAt.slice(0, 10),
      r.trialEnd ? r.trialEnd.slice(0, 10) : "",
      r.attention.map((a) => ATTENTION_LABEL[a]).join("; "),
    ]
      .map(csvCell)
      .join(",")
  );
  return [header.join(","), ...lines].join("\r\n") + "\r\n";
}
