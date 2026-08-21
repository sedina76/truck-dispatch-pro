"use client";

import { useEffect, useRef, useState, useTransition } from "react";
import { Phone, Copy, Send, Loader2 } from "lucide-react";
import { Button, buttonVariants } from "@/components/ui/button";
import { useToast } from "@/components/ui/toast";
import {
  logDriverCall,
  sendDispatchMessage,
  loadMoreDispatchMessages,
  markDispatchMessagesRead,
  type DrawerActivity,
  type DrawerMessage,
} from "@/app/(app)/dispatch/board-actions";
import { cn } from "@/lib/utils";

// Phase 2I.1 (Part B) -- the Dispatch Drawer's Communication section:
// Call Driver info/logging + the merged call+message timeline + the
// message composer. Split into its own file (rather than inlined into
// the already-large dispatch-drawer.tsx) because of its size, not
// because it's a separate drawer -- it renders INSIDE the one existing
// DesktopCollapsibleSection the drawer already owns, never a second
// stacked panel.
//
// Calls are never a second data source: they're read straight out of the
// drawer's existing `activity` array (action='call_logged', already
// fetched via activity_logs -- see getDispatchDrawerData) and merged
// client-side with `messages` by timestamp. No raw enum/action string is
// ever shown -- CALL_OUTCOME_LABEL translates every one.
const CALL_OUTCOME_LABEL: Record<string, string> = {
  initiated: "Call initiated",
  reached_driver: "Reached driver",
  no_answer: "No answer",
  left_voicemail: "Left voicemail",
  follow_up_needed: "Follow-up needed",
};
const CALL_OUTCOME_BUTTONS: { value: string; label: string }[] = [
  { value: "reached_driver", label: "Reached Driver" },
  { value: "no_answer", label: "No Answer" },
  { value: "left_voicemail", label: "Left Voicemail" },
  { value: "follow_up_needed", label: "Follow-up Needed" },
];

type TimelineEntry = {
  id: string;
  createdAt: string;
  render: () => { label: string; body: string | null };
};

export function CommunicationPanel({
  dispatchId,
  driver,
  canManageDispatchOps,
  activity,
  initialMessages,
  initialHasMoreMessages,
  onSent,
}: {
  dispatchId: string;
  driver: { id: string; name: string; phone: string | null; status: string } | null;
  canManageDispatchOps: boolean;
  activity: DrawerActivity[];
  initialMessages: DrawerMessage[];
  initialHasMoreMessages: boolean;
  onSent: () => void | Promise<void>;
}) {
  const toast = useToast();
  const [messages, setMessages] = useState(initialMessages);
  const [hasMore, setHasMore] = useState(initialHasMoreMessages);
  const [text, setText] = useState("");

  // Phase 2I.1 live-verification defect fix: initialMessages is only a
  // mount-time seed for useState -- it does NOT re-sync `messages` on its
  // own when the drawer's parent data refreshes (after this panel's own
  // handleSend, after a Load Sheet/Documents/Tracking action elsewhere in
  // the drawer, or simply because the parent's polling/refresh fired).
  // Without this, a staff member's own just-sent message, or a driver's
  // reply that arrived after this panel first mounted, silently never
  // appeared until the whole drawer was closed and reopened. Merge rather
  // than replace so a page loaded via "Load More" (older messages this
  // panel fetched itself, which initialMessages -- always just the latest
  // page -- knows nothing about) is never dropped by a refresh.
  useEffect(() => {
    setMessages((prev) => {
      const existingIds = new Set(prev.map((m) => m.id));
      const newOnes = initialMessages.filter((m) => !existingIds.has(m.id));
      if (newOnes.length === 0) return prev;
      return [...prev, ...newOnes].sort((a, b) => new Date(a.createdAt).getTime() - new Date(b.createdAt).getTime());
    });
  }, [initialMessages]);
  const [sending, startSend] = useTransition();
  const [logging, startLog] = useTransition();
  const [loadingMore, startLoadMore] = useTransition();

  // Phase 2I.1A section B -- mark the driver's messages read exactly once
  // per genuine open of this panel. This component only exists in the
  // tree while its parent's data has actually loaded for THIS dispatch
  // (dispatch-drawer.tsx unmounts it between dispatches and while
  // loading), so a plain mount-guarded effect -- the same pattern already
  // proven in driver-portal/message-thread.tsx's markMyMessagesRead --
  // gives exactly the required behavior: never on login, never on Board
  // load, never for a drawer open on another tab, and a fresh guard (thus
  // a fresh read) each time a different dispatch's drawer is opened.
  // Failures are swallowed (best-effort, matching the driver-side
  // precedent) rather than surfaced as a toast -- an unread badge staying
  // one tick stale is not worth interrupting the dispatcher.
  const markedReadRef = useRef(false);
  useEffect(() => {
    // Viewer/accountant have read-only access to this panel (composer
    // hidden below) -- markDispatchMessagesRead is gated server-side to
    // owner/admin/dispatcher (requireDispatchOpsAccess), so skip the call
    // entirely for those roles rather than firing a request guaranteed to
    // be rejected.
    if (!canManageDispatchOps) return;
    if (markedReadRef.current) return;
    markedReadRef.current = true;
    markDispatchMessagesRead(dispatchId).catch(() => {});
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const callEntries: TimelineEntry[] = activity
    .filter((a) => a.action === "call_logged")
    .map((a) => {
      const outcome = (a.changes as { outcome?: string } | null)?.outcome ?? "initiated";
      return {
        id: a.id,
        createdAt: a.createdAt,
        render: () => ({ label: a.actorName ?? "Dispatcher", body: CALL_OUTCOME_LABEL[outcome] ?? outcome }),
      };
    });
  const messageEntries: TimelineEntry[] = messages.map((m) => ({
    id: m.id,
    createdAt: m.createdAt,
    render: () => ({ label: m.senderType === "driver" ? (driver?.name ?? "Driver") : (m.senderName ?? "Dispatcher"), body: m.body }),
  }));
  const timeline = [...callEntries, ...messageEntries].sort((a, b) => new Date(a.createdAt).getTime() - new Date(b.createdAt).getTime());

  function handleLogCall(outcome: string) {
    startLog(async () => {
      const result = await logDriverCall(dispatchId, outcome);
      if (result.ok) await onSent();
      else toast.show("error", result.error);
    });
  }

  function handleCopyPhone() {
    if (!driver?.phone) return;
    navigator.clipboard?.writeText(driver.phone).then(() => toast.show("success", "Phone number copied."));
  }

  function handleSend() {
    const trimmed = text.trim();
    if (!trimmed) return;
    startSend(async () => {
      const result = await sendDispatchMessage(dispatchId, trimmed);
      if (result.ok) {
        setText("");
        await onSent();
      } else {
        toast.show("error", result.error);
      }
    });
  }

  function handleLoadMore() {
    if (messages.length === 0) return;
    startLoadMore(async () => {
      const result = await loadMoreDispatchMessages(dispatchId, messages[0].createdAt);
      if (result.ok) {
        setMessages((prev) => [...result.messages, ...prev]);
        setHasMore(result.hasMore);
      }
    });
  }

  return (
    <div className="space-y-3">
      {/* Call Driver -- info + the action that both logs AND (via the
          native tel: handler) actually places the call. Origination is
          always Truck Dispatch Pro first: the log fires on the same click
          that opens the phone app, never a bare unlogged tel: link. */}
      <div className="rounded-md border border-desktop-border p-2.5">
        <div className="grid grid-cols-2 gap-x-3 gap-y-1 text-xs">
          <span className="text-muted-foreground">Driver</span>
          <span className="text-right font-medium">{driver?.name ?? "--"}</span>
          <span className="text-muted-foreground">Phone</span>
          <span className="text-right font-medium">{driver?.phone ?? "Not on file"}</span>
          <span className="text-muted-foreground">Current Status</span>
          <span className="text-right font-medium capitalize">{driver?.status?.replace(/_/g, " ") ?? "--"}</span>
        </div>
        {canManageDispatchOps && (
          <div className="mt-2 flex flex-wrap items-center gap-1.5">
            {driver?.phone ? (
              <a
                href={`tel:${driver.phone}`}
                onClick={() => handleLogCall("initiated")}
                className={cn(buttonVariants({ size: "sm" }), logging && "pointer-events-none opacity-50")}
              >
                <Phone className="mr-1.5 size-3.5" /> Call Driver
              </a>
            ) : (
              <Button size="sm" disabled>
                <Phone className="mr-1.5 size-3.5" /> Call Driver
              </Button>
            )}
            <Button size="sm" variant="outline" disabled={!driver?.phone} onClick={handleCopyPhone}>
              <Copy className="mr-1.5 size-3.5" /> Copy Number
            </Button>
          </div>
        )}
        {canManageDispatchOps && driver?.phone && (
          // Phase 2I.1A section A -- honesty requirement: Call Driver only
          // ever hands off to the device's native phone app (tel:), there
          // is no in-portal voice provider. Never imply "Calling...",
          // "Connected", or any in-app call state here or anywhere else in
          // this panel.
          <p className="mt-1 text-[10.5px] text-muted-foreground">Opens your device&apos;s phone app.</p>
        )}
        {canManageDispatchOps && (
          <div className="mt-1.5 flex flex-wrap gap-1">
            {CALL_OUTCOME_BUTTONS.map((o) => (
              <button
                key={o.value}
                type="button"
                disabled={logging}
                onClick={() => handleLogCall(o.value)}
                className="rounded-sm border border-desktop-border px-1.5 py-0.5 text-[11px] text-muted-foreground hover:bg-desktop-muted disabled:opacity-50"
              >
                {o.label}
              </button>
            ))}
          </div>
        )}
      </div>

      {/* Merged timeline */}
      <div>
        <p className="mb-1 text-[10.5px] font-semibold uppercase tracking-wide text-muted-foreground">Communication</p>
        {hasMore && (
          <button type="button" onClick={handleLoadMore} disabled={loadingMore} className="mb-1.5 w-full rounded-sm border border-desktop-border py-1 text-[11px] text-muted-foreground hover:bg-desktop-muted">
            {loadingMore ? <Loader2 className="mx-auto size-3.5 animate-spin" /> : "Load earlier"}
          </button>
        )}
        <div className="max-h-64 space-y-1.5 overflow-y-auto rounded-md border border-desktop-border p-2">
          {timeline.length === 0 && <p className="py-3 text-center text-xs text-muted-foreground">No calls or messages yet.</p>}
          {timeline.map((entry) => {
            const { label, body } = entry.render();
            return (
              <div key={entry.id} className="text-xs">
                <span className="text-muted-foreground">{new Date(entry.createdAt).toLocaleTimeString([], { hour: "numeric", minute: "2-digit" })}</span>{" "}
                <span className="font-medium">{label}:</span> <span className="text-muted-foreground">{body}</span>
              </div>
            );
          })}
        </div>
      </div>

      {/* Composer -- operational write tier only (owner/admin/dispatcher);
          viewer/accountant can read the full timeline above but never
          send, matching the dispatches table's own write policy. */}
      {canManageDispatchOps ? (
        <div className="flex items-end gap-1.5">
          <textarea
            value={text}
            onChange={(e) => setText(e.target.value)}
            rows={2}
            maxLength={2000}
            placeholder="Message the driver..."
            className="flex-1 rounded-sm border border-desktop-border bg-desktop-panel px-2 py-1.5 text-[13px] outline-none focus-visible:border-primary"
          />
          <Button size="sm" onClick={handleSend} disabled={sending || !text.trim()}>
            {sending ? <Loader2 className="size-3.5 animate-spin" /> : <Send className="size-3.5" />}
          </Button>
        </div>
      ) : (
        <p className="text-[11px] text-muted-foreground">You have read-only access to this conversation.</p>
      )}
    </div>
  );
}
