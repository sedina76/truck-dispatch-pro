import "server-only";
import { redirect } from "next/navigation";
import { NextResponse } from "next/server";
import { createClient } from "@/lib/supabase/server";

// Phase 2G.6 -- the first real "deny before rendering" server-side route
// guard in this app. Every existing role check found during audit
// (settings/organization, settings/email, settings/organization/bank-accounts)
// only ever computed a boolean and used it to conditionally render a
// button/section -- the page's data was already fetched and the shell
// already rendered either way. That's fine for "hide an edit control from
// a role that can still safely view the page," but it is NOT what
// Billing/Reports/Email History/Expenses/Settlements need: those pages
// must never even reach their own data-fetching code for a role that
// shouldn't see that data at all. Every guarded page below calls one of
// these functions as its very first line, before any Supabase query.
//
// This is UX/defense-in-depth layered on top of RLS, not a replacement
// for it -- see 0066_financial_rls_hardening.sql (proposed, not applied)
// for the actual authorization boundary at the database layer, which
// protects direct client-side queries this guard cannot see.
export type OrgRole = "owner" | "admin" | "dispatcher" | "accountant" | "driver" | "viewer";

async function currentRole(): Promise<{ role: OrgRole | null; hasOrg: boolean }> {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) return { role: null, hasOrg: false };

  const { data: profile } = await supabase.from("profiles").select("role, organization_id").eq("id", user.id).maybeSingle();
  return { role: (profile?.role as OrgRole | undefined) ?? null, hasOrg: Boolean(profile?.organization_id) };
}

// For page.tsx / layout.tsx Server Components. Redirects (never renders
// the caller's own content) if the signed-in user's role isn't in
// `allowed`. Mirrors the app's existing "no organization -> /onboarding"
// and "no session -> /login" redirects (src/app/(app)/layout.tsx) rather
// than introducing a third convention.
export async function requireRole(allowed: OrgRole[]): Promise<OrgRole> {
  const { role, hasOrg } = await currentRole();
  if (!role || !hasOrg) redirect("/login");
  if (!allowed.includes(role)) redirect("/access-denied");
  return role;
}

// For route.ts handlers (CSV/export endpoints), which are not wrapped by
// layout.tsx -- a redirect() doesn't make sense for a fetch() call a page
// makes to download a file, so this returns a plain 403 Response instead.
// Usage: `const denied = await requireRoleForApi([...]); if (denied) return denied;`
export async function requireRoleForApi(allowed: OrgRole[]): Promise<NextResponse | null> {
  const { role, hasOrg } = await currentRole();
  if (!role || !hasOrg) return NextResponse.json({ error: "Not authenticated." }, { status: 401 });
  if (!allowed.includes(role)) return NextResponse.json({ error: "You do not have access to this data." }, { status: 403 });
  return null;
}

// The one role tier every Billing-family page, Reports, Email History,
// Expenses, and Settlements/Advances share -- matches the Billing nav
// section's own visibility rule from Phase 2G.5 exactly, so "what's in
// the sidebar" and "what actually loads" can never disagree. Driver and
// viewer are excluded from all of it: the Financial Data Rule explicitly
// requires drivers never gain office-level access to rates, invoices,
// payments, A/R, collections, profit/margin, or settlements belonging to
// others, and no "approved non-sensitive financial area" has been defined
// for viewer yet, so it stays excluded until one is.
export const FINANCIAL_ROLES: OrgRole[] = ["owner", "admin", "dispatcher", "accountant"];

// The tier allowed to change a load's internal load_number after creation
// (0114 revision 2 -- controlled Owner/Admin override). Matches the
// database's own has_role(['owner','admin']) check inside
// guard_load_number_change()/change_load_number() exactly -- this
// constant only controls whether the UI offers the control at all;
// Dispatcher and every other role are rejected at the database layer
// regardless of what this constant says, so it is never the actual
// security boundary, only the UI's mirror of it.
export const OWNER_ADMIN_ROLES: OrgRole[] = ["owner", "admin"];
