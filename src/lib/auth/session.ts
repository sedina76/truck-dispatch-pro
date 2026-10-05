import "server-only";
import { cache } from "react";
import { createClient } from "@/lib/supabase/server";

// One page load used to ask Supabase "who is this?" several times over: the
// app layout, requireRole() on the page, and getCurrentOrgId() in each
// section each made their own round trips. React's cache() keeps the answer
// for the rest of that one request (never across requests or users), so
// each is fetched once per page. Authorization itself is unchanged: the
// same queries, the same RLS.

export type SessionProfile = {
  full_name: string;
  role: string;
  organization_id: string | null;
  organizations: { name: string } | null;
};

/** The signed-in user (verified with Supabase Auth), once per request. */
export const getSessionUser = cache(async () => {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  return user;
});

/** The signed-in user's profile row (role, company), once per request. */
export const getSessionProfile = cache(async (): Promise<SessionProfile | null> => {
  const user = await getSessionUser();
  if (!user) return null;
  const supabase = await createClient();
  const { data } = await supabase
    .from("profiles")
    .select("full_name, role, organization_id, organizations(name)")
    .eq("id", user.id)
    .maybeSingle();
  return (data as unknown as SessionProfile | null) ?? null;
});

/** public.current_org_id() -- the database's own answer -- once per request. */
export const getSessionOrgId = cache(async (): Promise<{ id: string | null; error: boolean }> => {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("current_org_id");
  return { id: (data as string | null) ?? null, error: Boolean(error) };
});
