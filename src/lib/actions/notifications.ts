"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";

export type NotificationRow = {
  id: string;
  title: string;
  body: string | null;
  type: string;
  entity_type: string | null;
  entity_id: string | null;
  // Phase 2P.6B -- links this notification to the specific exception
  // episode it's about (0107). Null for every non-exception notification
  // (dispatch_message, etc.) -- unaffected either way.
  exception_id: string | null;
  read_at: string | null;
  created_at: string;
};

// Phase 2I.1A section K -- the narrow, single-purpose fetch the
// notification bell polls every 20s to pick up a new dispatch_message
// notification without a websocket/Realtime channel. Exact same query
// (app)/layout.tsx already runs server-side for the first paint; RLS
// (profile_id = auth.uid(), enforced by the anon-key client from
// createClient()) is the only thing scoping this to the caller's own
// rows -- there is no organization_id/profile_id parameter to spoof.
export async function getMyNotifications(): Promise<NotificationRow[]> {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) return [];
  const { data } = await supabase
    .from("notifications")
    .select("id, title, body, type, entity_type, entity_id, exception_id, read_at, created_at")
    .eq("profile_id", user.id)
    .order("created_at", { ascending: false })
    .limit(20);
  return (data ?? []) as NotificationRow[];
}

export async function markNotificationRead(id: string) {
  const supabase = await createClient();
  await supabase.from("notifications").update({ read_at: new Date().toISOString() }).eq("id", id);
  revalidatePath("/", "layout");
}

export async function markAllNotificationsRead() {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) return;
  await supabase
    .from("notifications")
    .update({ read_at: new Date().toISOString() })
    .eq("profile_id", user.id)
    .is("read_at", null);
  revalidatePath("/", "layout");
}
