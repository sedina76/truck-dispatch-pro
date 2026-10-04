import "server-only";
import { createServiceRoleClient } from "@/lib/supabase/service-role";
import { driverDocumentNotice, driverExpenseNotice, driverFuelNotice } from "./document-notice";

type ServiceRoleClient = ReturnType<typeof createServiceRoleClient>;

/**
 * A driver uploaded a document from the Driver Portal: one bell
 * notification per active owner/admin/dispatcher/accountant (they verify
 * PODs and bill the load). The bell links to the load; the staff watcher
 * chimes for it. Best-effort: never fails the driver's upload.
 */
export async function notifyOfficeOfDriverDocument(
  supabase: ServiceRoleClient,
  p: { organizationId: string; loadId: string; documentType: string; driverName: string | null }
): Promise<void> {
  try {
    const [{ data: recipients }, { data: load }] = await Promise.all([
      supabase.from("profiles").select("id").eq("organization_id", p.organizationId).in("role", ["owner", "admin", "dispatcher", "accountant"]).eq("is_active", true),
      supabase.from("loads").select("load_number").eq("id", p.loadId).eq("organization_id", p.organizationId).maybeSingle(),
    ]);
    if (!recipients || recipients.length === 0) return;
    const { title, body } = driverDocumentNotice(p.documentType, load?.load_number ?? null, p.driverName);
    const rows = recipients.map((r) => ({
      organization_id: p.organizationId,
      profile_id: r.id,
      type: "system" as const,
      title,
      body,
      entity_type: "load" as const,
      entity_id: p.loadId,
    }));
    const { error } = await supabase.from("notifications").insert(rows);
    if (error) console.error("[driver-document] notification insert failed:", error);
  } catch (err) {
    console.error("[driver-document] notification failed:", err);
  }
}

/**
 * A driver submitted an expense (fuel, lumper, toll, ...) from the Driver
 * Portal: one bell notification per active owner/admin/dispatcher/accountant,
 * opening the expense so it can be checked and approved. Best-effort: never
 * fails the driver's submission.
 */
export async function notifyOfficeOfDriverExpense(
  supabase: ServiceRoleClient,
  p: { organizationId: string; expenseId: string; loadId: string; category: string; amount: number; vendor: string | null; driverName: string | null }
): Promise<void> {
  try {
    const [{ data: recipients }, { data: load }] = await Promise.all([
      supabase.from("profiles").select("id").eq("organization_id", p.organizationId).in("role", ["owner", "admin", "dispatcher", "accountant"]).eq("is_active", true),
      supabase.from("loads").select("load_number").eq("id", p.loadId).eq("organization_id", p.organizationId).maybeSingle(),
    ]);
    if (!recipients || recipients.length === 0) return;
    const { title, body } = driverExpenseNotice(p.category, p.amount, load?.load_number ?? null, p.driverName, p.vendor);
    const rows = recipients.map((r) => ({
      organization_id: p.organizationId,
      profile_id: r.id,
      type: "system" as const,
      title,
      body,
      entity_type: "expense" as const,
      entity_id: p.expenseId,
    }));
    const { error } = await supabase.from("notifications").insert(rows);
    if (error) console.error("[driver-expense] notification insert failed:", error);
  } catch (err) {
    console.error("[driver-expense] notification failed:", err);
  }
}

/**
 * A driver logged a fuel purchase from the Driver Portal: bell + chime for
 * the office, opening the fuel log (Fuel Logs) to review who paid and set
 * recovery. Best-effort: never fails the driver's submission.
 */
export async function notifyOfficeOfDriverFuel(
  supabase: ServiceRoleClient,
  p: { organizationId: string; fuelLogId: string; loadId: string | null; amount: number; gallons: number; station: string | null; truckUnit: string | null; paidByLabel: string; driverName: string | null }
): Promise<void> {
  try {
    const [{ data: recipients }, { data: load }] = await Promise.all([
      supabase.from("profiles").select("id").eq("organization_id", p.organizationId).in("role", ["owner", "admin", "dispatcher", "accountant"]).eq("is_active", true),
      p.loadId ? supabase.from("loads").select("load_number").eq("id", p.loadId).eq("organization_id", p.organizationId).maybeSingle() : Promise.resolve({ data: null }),
    ]);
    if (!recipients || recipients.length === 0) return;
    const { title, body } = driverFuelNotice({ ...p, loadNumber: (load as { load_number?: string } | null)?.load_number ?? null });
    const rows = recipients.map((r) => ({
      organization_id: p.organizationId,
      profile_id: r.id,
      type: "system" as const,
      title,
      body,
      entity_type: "fuel" as const,
      entity_id: p.fuelLogId,
    }));
    const { error } = await supabase.from("notifications").insert(rows);
    if (error) console.error("[driver-fuel] notification insert failed:", error);
  } catch (err) {
    console.error("[driver-fuel] notification failed:", err);
  }
}
