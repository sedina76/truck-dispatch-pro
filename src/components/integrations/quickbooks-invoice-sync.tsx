"use client";

import { useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import Link from "next/link";
import { Loader2, CheckCircle2, AlertTriangle } from "lucide-react";
import { sendInvoiceToQuickbooks } from "@/app/(app)/settings/integrations/quickbooks-sync-actions";

export type InvoiceSyncView = {
  status: "pending" | "synced" | "failed";
  docNumber: string | null;
  syncedAt: string | null;
  lastErrorMessage: string | null;
} | null;

const NON_RETRYABLE = new Set(["BAD_STATUS", "NO_PARTY", "ZERO_TOTAL", "NOT_SET_UP"]);

function fmt(iso: string | null): string {
  if (!iso) return "--";
  return new Date(iso).toLocaleString(undefined, { year: "numeric", month: "short", day: "numeric", hour: "numeric", minute: "2-digit" });
}

// Invoice detail "QuickBooks" panel. Send is always explicit; once synced,
// the Send button is replaced by the synced state (no duplicate path).
export function QuickbooksInvoiceSync({
  invoiceId,
  sync,
  eligibleReason,
  customerMapped,
  partyHref,
}: {
  invoiceId: string;
  sync: InvoiceSyncView;
  eligibleReason: string | null; // null = eligible
  customerMapped: boolean;
  partyHref: string | null;
}) {
  const router = useRouter();
  const [pending, start] = useTransition();
  const [msg, setMsg] = useState<string | null>(sync?.status === "failed" ? sync.lastErrorMessage : null);
  const [retryable, setRetryable] = useState(sync?.status === "failed");

  function send() {
    setMsg(null);
    start(async () => {
      const r = await sendInvoiceToQuickbooks(invoiceId);
      if (!r.ok) {
        setMsg(r.message);
        setRetryable(!NON_RETRYABLE.has(r.code) && r.code !== "IN_PROGRESS");
        if (r.code === "IN_PROGRESS") router.refresh();
        return;
      }
      router.refresh();
    });
  }

  return (
    <section className="min-w-0 space-y-2 rounded-md border border-desktop-border bg-card p-4">
      <h2 className="font-semibold">QuickBooks</h2>

      {sync?.status === "synced" ? (
        <div className="space-y-1 text-[13px]">
          <p className="flex items-center gap-1.5 font-medium text-desktop-success">
            <CheckCircle2 className="size-4" /> Synced to QuickBooks
          </p>
          <p className="text-muted-foreground">
            QuickBooks invoice <span className="font-medium text-desktop-text">{sync.docNumber ?? "(auto-numbered)"}</span> · synced {fmt(sync.syncedAt)}
          </p>
          <details className="pt-1">
            <summary className="cursor-pointer text-[12px] text-primary">View sync details</summary>
            <div className="mt-1 space-y-0.5 text-[11.5px] text-muted-foreground">
              <p>Status: synced</p>
              <p>Doc number: {sync.docNumber ?? "--"}</p>
              <p>Last synced: {fmt(sync.syncedAt)}</p>
            </div>
          </details>
        </div>
      ) : eligibleReason ? (
        <p className="text-[12.5px] text-muted-foreground">Send to QuickBooks is unavailable: {eligibleReason}</p>
      ) : !customerMapped ? (
        <p className="flex flex-wrap items-center gap-1.5 text-[12.5px] text-desktop-warning">
          <AlertTriangle className="size-4 shrink-0" />
          Map this customer to QuickBooks first.
          {partyHref && (
            <Link href={partyHref} className="font-medium text-primary hover:underline">
              Open the record
            </Link>
          )}
        </p>
      ) : (
        <>
          {sync?.status === "pending" && (
            <p className="text-[12px] text-muted-foreground">A send is in progress. Refresh in a moment.</p>
          )}
          <button
            type="button"
            onClick={send}
            disabled={pending}
            className="inline-flex h-8 items-center gap-1.5 rounded-sm bg-primary px-3 text-[13px] font-medium text-primary-foreground hover:bg-primary-hover disabled:opacity-50"
          >
            {pending ? <Loader2 className="size-3.5 animate-spin" /> : null}
            {sync?.status === "failed" || retryable ? "Retry send to QuickBooks" : "Send to QuickBooks"}
          </button>
          <p className="text-[11px] text-muted-foreground">
            Creates one QuickBooks invoice for the mapped customer. No taxes, no settlements or payables. Sandbox.
          </p>
        </>
      )}

      {msg && sync?.status !== "synced" && (
        <p className="flex items-start gap-1.5 rounded-sm border border-danger/30 bg-danger/5 p-2 text-[12px] text-danger">
          <AlertTriangle className="mt-0.5 size-3.5 shrink-0" />
          {msg}
        </p>
      )}
    </section>
  );
}
