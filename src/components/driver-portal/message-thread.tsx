"use client";

import { useEffect, useRef, useState, useTransition } from "react";
import { Loader2, Send } from "lucide-react";
import { sendDriverMessage, markMyMessagesRead, loadMoreDriverMessages, getMyDispatchMessages, type DriverMessage } from "@/app/driver-portal/actions";

// Phase 2I.1 (Part B4/G). Mobile-first, matches the app-wide Driver Portal
// card styling (rounded-2xl border bg-card) rather than inventing a new
// chat-app look. Body text is ALWAYS rendered as a plain text node
// (React's default escaping) -- never dangerouslySetInnerHTML -- so any
// HTML/script a sender types shows up as inert literal text, never runs.
export function MessageThread({ dispatchId, initialMessages, initialHasMore }: { dispatchId: string; initialMessages: DriverMessage[]; initialHasMore: boolean }) {
  const [messages, setMessages] = useState(initialMessages);
  const [hasMore, setHasMore] = useState(initialHasMore);
  const [text, setText] = useState("");
  const [sending, startSend] = useTransition();
  const [loadingMore, startLoadMore] = useTransition();
  const [error, setError] = useState<string | null>(null);
  const markedRead = useRef(false);

  // Mark staff-sent messages read once, on mount -- not on every render.
  useEffect(() => {
    if (markedRead.current) return;
    markedRead.current = true;
    markMyMessagesRead(dispatchId).catch(() => {});
  }, [dispatchId]);

  function handleSend() {
    const trimmed = text.trim();
    if (!trimmed) return;
    setError(null);
    startSend(async () => {
      try {
        await sendDriverMessage(dispatchId, trimmed);
        setText("");
        const fresh = await getMyDispatchMessages();
        setMessages(fresh.messages);
        setHasMore(fresh.hasMore);
      } catch (e) {
        setError(e instanceof Error ? e.message : "Unable to send message.");
      }
    });
  }

  function handleLoadMore() {
    if (messages.length === 0) return;
    startLoadMore(async () => {
      try {
        const older = await loadMoreDriverMessages(dispatchId, messages[0].createdAt);
        setMessages((prev) => [...older.messages, ...prev]);
        setHasMore(older.hasMore);
      } catch {
        // Non-fatal -- the composer/existing thread still work.
      }
    });
  }

  return (
    <div className="flex flex-1 flex-col gap-3">
      <div className="flex flex-col-reverse gap-2 overflow-y-auto rounded-2xl border border-border bg-card p-3" style={{ maxHeight: "60vh" }}>
        <div className="flex flex-col gap-2">
          {hasMore && (
            <button type="button" onClick={handleLoadMore} disabled={loadingMore} className="mx-auto rounded-full border border-border px-3 py-1 text-xs text-muted-foreground hover:bg-muted">
              {loadingMore ? <Loader2 className="size-3.5 animate-spin" /> : "Load earlier messages"}
            </button>
          )}
          {messages.length === 0 && <p className="py-6 text-center text-sm text-muted-foreground">No messages yet -- say hello or ask dispatch a question.</p>}
          {messages.map((m) => (
            <div key={m.id} className={m.senderType === "driver" ? "ml-auto max-w-[85%] rounded-2xl rounded-br-sm bg-primary px-3 py-2 text-primary-foreground" : "mr-auto max-w-[85%] rounded-2xl rounded-bl-sm bg-muted px-3 py-2"}>
              {m.senderType === "staff" && <p className="text-[11px] font-semibold opacity-70">{m.senderName ?? "Dispatch"}</p>}
              <p className="whitespace-pre-wrap break-words text-sm">{m.body}</p>
              <p className={`mt-0.5 text-[10px] ${m.senderType === "driver" ? "text-primary-foreground/70" : "text-muted-foreground"}`}>{new Date(m.createdAt).toLocaleString()}</p>
            </div>
          ))}
        </div>
      </div>

      {error && <p className="text-xs text-danger">{error}</p>}

      <div className="flex items-end gap-2">
        <textarea
          value={text}
          onChange={(e) => setText(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === "Enter" && !e.shiftKey) {
              e.preventDefault();
              handleSend();
            }
          }}
          rows={2}
          maxLength={2000}
          placeholder="Message dispatch..."
          className="flex-1 rounded-2xl border border-border bg-card px-3 py-2 text-sm outline-none focus-visible:border-primary"
        />
        <button
          type="button"
          onClick={handleSend}
          disabled={sending || !text.trim()}
          className="flex size-10 shrink-0 items-center justify-center rounded-full bg-primary text-primary-foreground disabled:opacity-50"
          aria-label="Send"
        >
          {sending ? <Loader2 className="size-4 animate-spin" /> : <Send className="size-4" />}
        </button>
      </div>
    </div>
  );
}
