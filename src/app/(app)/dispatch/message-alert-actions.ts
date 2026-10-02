"use server";

import { createClient } from "@/lib/supabase/server";

export type DriverMessageAlert = {
  count: number;
  latestAt: string | null;
  latest: { dispatchId: string; driverName: string | null; loadNumber: string | null; preview: string } | null;
};

const EMPTY: DriverMessageAlert = { count: 0, latestAt: null, latest: null };

// Polled by <MessageAlertWatcher> (every page of the staff app) to decide
// when to chime for a new driver -> dispatch message. Read-only, RLS-scoped
// to the caller's organization (dispatch_messages_select, 0080), and
// limited to the roles that actually handle driver communication -- the
// same owner/admin/dispatcher tier as requireDispatchOpsAccess in
// board-actions.ts. Never throws: any failure just means "no alert".
export async function getUnreadDriverMessageAlert(): Promise<DriverMessageAlert> {
  try {
    const supabase = await createClient();
    const {
      data: { user },
    } = await supabase.auth.getUser();
    if (!user) return EMPTY;
    const { data: profile } = await supabase.from("profiles").select("role, organization_id").eq("id", user.id).maybeSingle();
    if (!profile?.organization_id || !["owner", "admin", "dispatcher"].includes(String(profile.role))) return EMPTY;

    const [{ count }, { data: latestRows }] = await Promise.all([
      supabase.from("dispatch_messages").select("id", { count: "exact", head: true }).eq("sender_type", "driver").is("read_at", null),
      supabase
        .from("dispatch_messages")
        .select("dispatch_id, body, created_at, drivers(first_name, last_name), loads(load_number)")
        .eq("sender_type", "driver")
        .is("read_at", null)
        .order("created_at", { ascending: false })
        .limit(1),
    ]);
    const row = (latestRows ?? [])[0] as unknown as
      | { dispatch_id: string; body: string; created_at: string; drivers: { first_name: string; last_name: string } | null; loads: { load_number: string } | null }
      | undefined;
    if (!count || !row) return EMPTY;
    const body = row.body.replace(/\s+/g, " ").trim();
    return {
      count,
      latestAt: row.created_at,
      latest: {
        dispatchId: row.dispatch_id,
        driverName: row.drivers ? `${row.drivers.first_name} ${row.drivers.last_name}`.trim() : null,
        loadNumber: row.loads?.load_number ?? null,
        preview: body.length > 80 ? `${body.slice(0, 77)}...` : body,
      },
    };
  } catch {
    return EMPTY;
  }
}

export type NotificationAlert = {
  count: number;
  latestAt: string | null;
  latest: { title: string; body: string | null } | null;
};

const EMPTY_NOTIFICATIONS: NotificationAlert = { count: 0, latestAt: null, latest: null };

// Polled by <MessageAlertWatcher> for the bell: the caller's own unread
// notifications (profile_id = the signed-in user, enforced by RLS), except
// driver messages -- those already chime through the message check above.
// Never throws: any failure just means "no alert".
export async function getUnreadNotificationAlert(): Promise<NotificationAlert> {
  try {
    const supabase = await createClient();
    const {
      data: { user },
    } = await supabase.auth.getUser();
    if (!user) return EMPTY_NOTIFICATIONS;
    const [{ count }, { data: latestRows }] = await Promise.all([
      supabase.from("notifications").select("id", { count: "exact", head: true }).eq("profile_id", user.id).is("read_at", null).neq("type", "dispatch_message"),
      supabase
        .from("notifications")
        .select("title, body, created_at")
        .eq("profile_id", user.id)
        .is("read_at", null)
        .neq("type", "dispatch_message")
        .order("created_at", { ascending: false })
        .limit(1),
    ]);
    const row = (latestRows ?? [])[0] as { title: string; body: string | null; created_at: string } | undefined;
    if (!count || !row) return EMPTY_NOTIFICATIONS;
    return { count, latestAt: row.created_at, latest: { title: row.title, body: row.body } };
  } catch {
    return EMPTY_NOTIFICATIONS;
  }
}
