import Link from "next/link";
import { MessageSquare, HandCoins, ShieldAlert, CalendarClock, UserCog, Bell } from "lucide-react";
import { createClient } from "@/lib/supabase/server";
import { StatusBadge } from "@/components/ui/status-badge";
import { Button } from "@/components/ui/button";
import {
  type CollectionsQueueRow,
  COLLECTION_STATUS_OPTIONS,
  CONTACT_METHOD_OPTIONS,
  DISPUTE_REASON_OPTIONS,
  formatMoney,
} from "@/lib/collections/types";
import {
  logContact,
  createPromise,
  cancelPromise,
  openDispute,
  resolveDispute,
  markDisputeUnderReview,
  assignCollector,
  updateCollectionStatus,
  queueReminder,
} from "@/app/(app)/collections/actions";

type ActivityRow = {
  id: string;
  contact_method: string;
  contact_name: string | null;
  note: string;
  next_follow_up_at: string | null;
  created_at: string;
  created_by: string | null;
};
type PromiseRow = {
  id: string;
  promised_amount: number;
  promise_date: string;
  expected_payment_date: string;
  contact_person: string | null;
  notes: string | null;
  status: string;
  cancelled_reason: string | null;
  created_at: string;
};
type DisputeRow = {
  id: string;
  status: string;
  reason: string;
  disputed_amount: number;
  broker_contact: string | null;
  notes: string | null;
  opened_at: string;
  resolved_at: string | null;
  resolution: string | null;
};
type ReminderRow = {
  id: string;
  stage: string;
  status: string;
  recipient_email: string | null;
  error_message: string | null;
  created_at: string;
  sent_at: string | null;
};

// Invoice Detail's Collections section -- built entirely on
// get_collections_queue() (0027_collections.sql, the same canonical
// function the Collections queue page uses) for the summary fields, plus
// the raw history tables for the full timeline/promise/dispute lists this
// single-row RPC call intentionally doesn't repeat in full.
export async function CollectionsSection({ invoiceId }: { invoiceId: string }) {
  const supabase = await createClient();

  const [{ data: rows }, { data: activity }, { data: promises }, { data: disputes }, { data: reminders }, { data: profiles }] =
    await Promise.all([
      supabase.rpc("get_collections_queue", { p_invoice_id: invoiceId }),
      supabase
        .from("invoice_collection_activity")
        .select("id, contact_method, contact_name, note, next_follow_up_at, created_at, created_by")
        .eq("invoice_id", invoiceId)
        .order("created_at", { ascending: false }),
      supabase
        .from("payment_promises")
        .select("id, promised_amount, promise_date, expected_payment_date, contact_person, notes, status, cancelled_reason, created_at")
        .eq("invoice_id", invoiceId)
        .order("created_at", { ascending: false }),
      supabase
        .from("invoice_disputes")
        .select("id, status, reason, disputed_amount, broker_contact, notes, opened_at, resolved_at, resolution")
        .eq("invoice_id", invoiceId)
        .order("created_at", { ascending: false }),
      supabase
        .from("invoice_reminders")
        .select("id, stage, status, recipient_email, error_message, created_at, sent_at")
        .eq("invoice_id", invoiceId)
        .order("created_at", { ascending: false }),
      supabase.from("profiles").select("id, full_name").order("full_name"),
    ]);

  const row = (rows as CollectionsQueueRow[] | null)?.[0];
  if (!row) return null;

  const activityRows = (activity ?? []) as ActivityRow[];
  const promiseRows = (promises ?? []) as PromiseRow[];
  const disputeRows = (disputes ?? []) as DisputeRow[];
  const reminderRows = (reminders ?? []) as ReminderRow[];

  const byId = new Map((profiles ?? []).map((p) => [p.id, p.full_name]));
  const openPromise = promiseRows.find((p) => p.id === row.promise_id);
  const activeDispute = disputeRows.find((d) => d.status === "open" || d.status === "under_review");

  return (
    <div className="rounded-xl border border-border bg-card p-4 shadow-elevation-1">
      <div className="flex items-center justify-between">
        <p className="text-sm font-medium">Collections</p>
        <StatusBadge status={row.priority} />
      </div>

      {/* ---- summary strip ---- */}
      <dl className="mt-3 grid grid-cols-2 gap-x-4 gap-y-3 text-sm sm:grid-cols-3 lg:grid-cols-6">
        <Field label="Collection Status"><StatusBadge status={row.collection_status} /></Field>
        <Field label="Priority"><StatusBadge status={row.priority} /></Field>
        <Field label="Days Past Due">{row.days_past_due > 0 ? `${row.days_past_due}d` : "Current"}</Field>
        <Field label="Assigned Collector">{row.assigned_collector_name ?? "Unassigned"}</Field>
        <Field label="Last Contact">{row.last_contact_at ? new Date(row.last_contact_at).toLocaleDateString() : "--"}</Field>
        <Field label="Next Follow-Up">{row.next_follow_up_at ? new Date(row.next_follow_up_at).toLocaleDateString() : "--"}</Field>
      </dl>

      {/* ---- promise to pay ---- */}
      {openPromise && (
        <div className="mt-4 rounded-lg border border-border bg-muted/40 p-3">
          <p className="text-xs font-semibold uppercase tracking-wide text-muted-foreground">Promise to Pay</p>
          <div className="mt-1 flex items-baseline gap-3">
            <span className="text-xl font-semibold">{formatMoney(openPromise.promised_amount)}</span>
            <span className="text-sm text-muted-foreground">Expected {new Date(openPromise.expected_payment_date + "T00:00:00").toLocaleDateString()}</span>
            <StatusBadge status={row.promise_effective_status ?? "open"} />
          </div>
          {openPromise.contact_person && <p className="mt-1 text-xs text-muted-foreground">Contact: {openPromise.contact_person}</p>}
          {row.promise_effective_status === "open" && (
            <details className="mt-2">
              <summary className="cursor-pointer text-xs font-medium text-danger">Cancel this promise</summary>
              <form action={cancelPromise.bind(null, openPromise.id, invoiceId)} className="mt-2 flex gap-2">
                <input name="cancelled_reason" required placeholder="Reason" className="flex-1 rounded-lg border border-border bg-card px-2.5 py-1.5 text-xs shadow-elevation-1 outline-none focus-visible:border-primary" />
                <Button type="submit" size="sm" variant="danger">Cancel Promise</Button>
              </form>
            </details>
          )}
        </div>
      )}

      {/* ---- dispute ---- */}
      {activeDispute && (
        <div className="mt-4 rounded-lg border border-danger/30 bg-danger/5 p-3">
          <div className="flex items-center justify-between">
            <p className="text-xs font-semibold uppercase tracking-wide text-danger">Dispute -- {DISPUTE_REASON_OPTIONS.find((r) => r.value === activeDispute.reason)?.label ?? activeDispute.reason}</p>
            <StatusBadge status={activeDispute.status} />
          </div>
          <div className="mt-2 grid grid-cols-3 gap-3 text-sm">
            <Field label="Total Balance">{formatMoney(row.balance_due)}</Field>
            <Field label="Disputed">{formatMoney(row.disputed_amount)}</Field>
            <Field label="Undisputed">{formatMoney(row.undisputed_amount)}</Field>
          </div>
          {activeDispute.notes && <p className="mt-2 text-xs text-muted-foreground">{activeDispute.notes}</p>}
          <div className="mt-2 flex flex-wrap gap-2">
            {activeDispute.status === "open" && (
              <form action={markDisputeUnderReview.bind(null, activeDispute.id, invoiceId)}>
                <Button type="submit" size="sm" variant="outline">Mark Under Review</Button>
              </form>
            )}
            <details>
              <summary className="inline-flex cursor-pointer list-none items-center rounded-lg border border-border bg-card px-3 py-1.5 text-xs font-medium hover:bg-muted">Resolve Dispute</summary>
              <form action={resolveDispute.bind(null, activeDispute.id, invoiceId)} className="mt-2 w-80 space-y-2 rounded-lg border border-border bg-card p-3">
                <select name="outcome" className="h-9 w-full rounded-lg border border-border bg-card px-2.5 text-xs">
                  <option value="resolved">Resolved (dispute upheld/settled)</option>
                  <option value="rejected">Rejected (dispute denied)</option>
                </select>
                <textarea name="resolution" required rows={2} placeholder="Resolution notes (required)" className="w-full rounded-lg border border-border bg-card px-2.5 py-1.5 text-xs shadow-elevation-1 outline-none" />
                <Button type="submit" size="sm" className="w-full">Save Resolution</Button>
              </form>
            </details>
          </div>
        </div>
      )}

      {/* ---- action bar ---- */}
      <div className="mt-4 flex flex-wrap gap-2 border-t border-border pt-3">
        <ActionDisclosure icon={MessageSquare} label="Add Note / Log Contact">
          <form action={logContact.bind(null, invoiceId)} className="space-y-2">
            <div className="grid grid-cols-2 gap-2">
              <select name="contact_method" className="h-9 rounded-lg border border-border bg-card px-2.5 text-xs">
                {CONTACT_METHOD_OPTIONS.map((o) => <option key={o.value} value={o.value}>{o.label}</option>)}
              </select>
              <input name="contact_name" placeholder="Contact person" className="h-9 rounded-lg border border-border bg-card px-2.5 text-xs" />
            </div>
            <textarea name="note" required rows={2} placeholder="Note (required)" className="w-full rounded-lg border border-border bg-card px-2.5 py-1.5 text-xs" />
            <div className="flex items-center gap-2">
              <label className="text-xs text-muted-foreground">Next follow-up</label>
              <input name="next_follow_up_at" type="date" className="h-9 rounded-lg border border-border bg-card px-2.5 text-xs" />
            </div>
            <Button type="submit" size="sm">Save</Button>
          </form>
        </ActionDisclosure>

        <ActionDisclosure icon={HandCoins} label="Promise to Pay">
          <form action={createPromise.bind(null, invoiceId)} className="space-y-2">
            <div className="grid grid-cols-2 gap-2">
              <input name="promised_amount" type="number" step="0.01" required placeholder="Promised amount ($)" className="h-9 rounded-lg border border-border bg-card px-2.5 text-xs" />
              <input name="expected_payment_date" type="date" required className="h-9 rounded-lg border border-border bg-card px-2.5 text-xs" />
            </div>
            <input name="contact_person" placeholder="Contact person" className="h-9 w-full rounded-lg border border-border bg-card px-2.5 text-xs" />
            <textarea name="notes" rows={2} placeholder="Notes" className="w-full rounded-lg border border-border bg-card px-2.5 py-1.5 text-xs" />
            <Button type="submit" size="sm">Log Promise</Button>
          </form>
        </ActionDisclosure>

        <ActionDisclosure icon={ShieldAlert} label="Open Dispute">
          <form action={openDispute.bind(null, invoiceId)} className="space-y-2">
            <div className="grid grid-cols-2 gap-2">
              <select name="reason" className="h-9 rounded-lg border border-border bg-card px-2.5 text-xs">
                {DISPUTE_REASON_OPTIONS.map((o) => <option key={o.value} value={o.value}>{o.label}</option>)}
              </select>
              <input name="disputed_amount" type="number" step="0.01" required placeholder="Disputed amount ($)" className="h-9 rounded-lg border border-border bg-card px-2.5 text-xs" />
            </div>
            <input name="broker_contact" placeholder="Broker/customer contact" className="h-9 w-full rounded-lg border border-border bg-card px-2.5 text-xs" />
            <textarea name="notes" rows={2} placeholder="Notes" className="w-full rounded-lg border border-border bg-card px-2.5 py-1.5 text-xs" />
            <Button type="submit" size="sm" variant="danger">Open Dispute</Button>
          </form>
        </ActionDisclosure>

        <ActionDisclosure icon={UserCog} label="Assign Collector">
          <form action={assignCollector.bind(null, invoiceId)} className="space-y-2">
            <select name="assigned_collector_id" defaultValue={row.assigned_collector_id ?? ""} className="h-9 w-full rounded-lg border border-border bg-card px-2.5 text-xs">
              <option value="">Unassigned</option>
              {(profiles ?? []).map((p) => <option key={p.id} value={p.id}>{p.full_name}</option>)}
            </select>
            <Button type="submit" size="sm">Save</Button>
          </form>
        </ActionDisclosure>

        <ActionDisclosure icon={CalendarClock} label="Update Status">
          <form action={updateCollectionStatus.bind(null, invoiceId)} className="space-y-2">
            <select name="collection_status" defaultValue={row.collection_status} className="h-9 w-full rounded-lg border border-border bg-card px-2.5 text-xs">
              {COLLECTION_STATUS_OPTIONS.map((o) => <option key={o.value} value={o.value}>{o.label}</option>)}
            </select>
            <Button type="submit" size="sm">Save</Button>
          </form>
        </ActionDisclosure>

        <ActionDisclosure icon={Bell} label="Queue Reminder">
          <form action={queueReminder.bind(null, invoiceId)} className="space-y-2">
            <select name="stage" className="h-9 w-full rounded-lg border border-border bg-card px-2.5 text-xs">
              <option value="before_due">Before Due</option>
              <option value="due_today">Due Today</option>
              <option value="overdue_7">7 Days Overdue</option>
              <option value="overdue_15">15 Days Overdue</option>
              <option value="overdue_30">30 Days Overdue</option>
              <option value="overdue_60">60 Days Overdue</option>
              <option value="overdue_90_plus">90+ Days Overdue</option>
            </select>
            <input name="recipient_email" type="email" placeholder="Recipient email" className="h-9 w-full rounded-lg border border-border bg-card px-2.5 text-xs" />
            <label className="flex items-center gap-1.5 text-xs text-muted-foreground">
              <input type="checkbox" name="force" value="1" className="size-3.5" /> Resend even if one was already queued for this stage
            </label>
            <Button type="submit" size="sm">Queue Reminder</Button>
            <p className="text-[11px] text-muted-foreground">No email provider is connected -- this will record a failed attempt, not send a real email.</p>
          </form>
        </ActionDisclosure>
      </div>

      {/* ---- reminder history ---- */}
      {reminderRows.length > 0 && (
        <div className="mt-4 border-t border-border pt-3">
          <p className="text-xs font-medium uppercase tracking-wide text-muted-foreground">Reminder History</p>
          <ul className="mt-2 divide-y divide-border text-xs">
            {reminderRows.map((r) => (
              <li key={r.id} className="flex items-center justify-between py-1.5">
                <span className="capitalize">{r.stage.replace(/_/g, " ")}</span>
                <span className="text-muted-foreground">{r.recipient_email ?? "--"}</span>
                <span className="text-muted-foreground">{new Date(r.created_at).toLocaleString()}</span>
                <StatusBadge status={r.status} />
              </li>
            ))}
          </ul>
        </div>
      )}

      {/* ---- activity timeline ---- */}
      <div className="mt-4 border-t border-border pt-3">
        <p className="text-xs font-medium uppercase tracking-wide text-muted-foreground">Activity Timeline</p>
        {activityRows.length === 0 && disputeRows.length === 0 && promiseRows.length === 0 ? (
          <p className="mt-2 text-sm text-muted-foreground">No collection activity yet.</p>
        ) : (
          <ul className="mt-2 space-y-2 text-sm">
            {activityRows.map((a) => (
              <li key={a.id} className="rounded-lg border border-border p-2.5">
                <div className="flex items-center justify-between text-xs text-muted-foreground">
                  <span className="capitalize font-medium text-foreground">{a.contact_method}{a.contact_name ? ` -- ${a.contact_name}` : ""}</span>
                  <span>{new Date(a.created_at).toLocaleString()} {a.created_by && byId.get(a.created_by) ? `by ${byId.get(a.created_by)}` : ""}</span>
                </div>
                <p className="mt-1">{a.note}</p>
                {a.next_follow_up_at && <p className="mt-1 text-xs text-primary">Follow up {new Date(a.next_follow_up_at).toLocaleDateString()}</p>}
              </li>
            ))}
            {promiseRows.map((p) => (
              <li key={p.id} className="rounded-lg border border-border p-2.5">
                <div className="flex items-center justify-between text-xs text-muted-foreground">
                  <span className="font-medium text-foreground">Promise to Pay -- {formatMoney(p.promised_amount)}</span>
                  <span>{new Date(p.created_at).toLocaleString()}</span>
                </div>
                <p className="mt-1">Expected {new Date(p.expected_payment_date + "T00:00:00").toLocaleDateString()}{p.contact_person ? ` -- ${p.contact_person}` : ""}</p>
                {p.status === "cancelled" && <p className="mt-1 text-xs text-danger">Cancelled: {p.cancelled_reason}</p>}
              </li>
            ))}
            {disputeRows.map((d) => (
              <li key={d.id} className="rounded-lg border border-border p-2.5">
                <div className="flex items-center justify-between text-xs text-muted-foreground">
                  <span className="font-medium text-foreground">Dispute -- {formatMoney(d.disputed_amount)}</span>
                  <span>{new Date(d.opened_at).toLocaleString()}</span>
                </div>
                <p className="mt-1">{DISPUTE_REASON_OPTIONS.find((r) => r.value === d.reason)?.label ?? d.reason}{d.notes ? ` -- ${d.notes}` : ""}</p>
                {d.resolved_at && <p className="mt-1 text-xs text-success">Resolved {new Date(d.resolved_at).toLocaleDateString()}: {d.resolution}</p>}
              </li>
            ))}
          </ul>
        )}
      </div>

      <Link href="/collections" className="mt-3 inline-block text-xs font-medium text-primary hover:underline">
        View Collections Queue &rarr;
      </Link>
    </div>
  );
}

function Field({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div>
      <p className="text-xs font-medium uppercase tracking-wide text-muted-foreground">{label}</p>
      <div className="mt-0.5">{children}</div>
    </div>
  );
}

function ActionDisclosure({ icon: Icon, label, children }: { icon: React.ComponentType<{ className?: string }>; label: string; children: React.ReactNode }) {
  return (
    <details className="group">
      <summary className="inline-flex cursor-pointer list-none items-center gap-1.5 rounded-lg border border-border bg-card px-3 py-1.5 text-xs font-medium transition-colors hover:bg-muted">
        <Icon className="size-3.5" />
        {label}
      </summary>
      <div className="mt-2 w-80 rounded-lg border border-border bg-muted/40 p-3">{children}</div>
    </details>
  );
}
