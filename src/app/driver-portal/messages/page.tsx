import { redirect } from "next/navigation";
import { getDriverPortalSession } from "@/lib/driver-portal/session";
import { getMyDispatchMessages } from "@/app/driver-portal/actions";
import { MessageThread } from "@/components/driver-portal/message-thread";

// Phase 2I.1 (Part B4) -- driver-facing conversation, scoped to the
// driver's CURRENT dispatch (same "current trip" resolver every other
// Driver Portal page already uses -- see documents/page.tsx). No message
// history browsing across past trips in this pass -- matches the
// approved scope (a bounded, current-trip conversation, not an inbox).
export default async function DriverPortalMessagesPage() {
  const identity = await getDriverPortalSession();
  if (!identity) redirect("/driver-portal/login");

  const { dispatchId, loadNumber, messages, hasMore } = await getMyDispatchMessages();

  if (!dispatchId) {
    return (
      <div className="flex flex-1 flex-col gap-4">
        <h1 className="text-lg font-semibold tracking-tight">Messages</h1>
        <div className="rounded-2xl border border-border bg-card p-4">
          <p className="text-sm text-muted-foreground">No active trip to message dispatch about right now.</p>
        </div>
      </div>
    );
  }

  return (
    <div className="flex flex-1 flex-col gap-4">
      <div>
        <h1 className="text-lg font-semibold tracking-tight">Messages</h1>
        <p className="text-xs text-muted-foreground">{loadNumber}</p>
      </div>
      <MessageThread dispatchId={dispatchId} initialMessages={messages} initialHasMore={hasMore} />
    </div>
  );
}
