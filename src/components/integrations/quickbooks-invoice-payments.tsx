"use client";

import { useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import Link from "next/link";
import { Loader2, CheckCircle2, AlertTriangle, RefreshCw } from "lucide-react";
import {
  refreshQuickbooksInvoiceStatus,
  importQuickbooksPayment,
} from "@/app/(app)/settings/integrations/quickbooks-payment-actions";
import type { PaymentImportView } from "@/lib/integrations/quickbooks/payment-reads";

type PaymentRow = {
  quickbooksPaymentId: string;
  txnDate: string | null;
  appliedToInvoice: number;
  totalAmt: number;
  referenceNumber: string | null;
  paymentMethod: string | null;
  voided: boolean;
  importState: "none" | "pending" | "imported" | "failed";
  reconciliationState: "ok" | "reconciliation_required";
  localPaymentId: string | null;
  importedAt: string | null;
};

function money(n: number): string {
  return `$${Number(n).toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
}
function fmtDate(iso: string | null): string {
  return iso ? new Date(iso).toLocaleDateString() : "--";
}
function fmtDateTime(iso: string | null): string {
  return iso ? new Date(iso).toLocaleString(undefined, { dateStyle: "medium", timeStyle: "short" }) : "--";
}

// Invoice detail "QuickBooks" panel -- payment sync section. Only rendered
// once the invoice is synced to QuickBooks. "Refresh QuickBooks Status" is
// READ-ONLY. "Import Payment" is the only action that creates a local
// payment, and disappears once imported.
export function QuickbooksInvoicePayments({
  invoiceId,
  initialImports,
}: {
  invoiceId: string;
  initialImports: PaymentImportView[];
}) {
  const router = useRouter();
  const [pending, start] = useTransition();
  const [importingId, setImportingId] = useState<string | null>(null);
  const [msg, setMsg] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [qboInvoice, setQboInvoice] = useState<{ docNumber: string | null; totalAmt: number; balance: number } | null>(null);
  const [payments, setPayments] = useState<PaymentRow[] | null>(null);
  const [loadedOnce, setLoadedOnce] = useState(false);

  // Seed from the durable import rows so the imported state shows before a
  // refresh is ever clicked.
  const importedRows = initialImports.filter((r) => r.importState === "imported");
  const reconRows = initialImports.filter((r) => r.reconciliationState === "reconciliation_required");

  function refresh() {
    setMsg(null);
    setErr(null);
    start(async () => {
      const r = await refreshQuickbooksInvoiceStatus(invoiceId);
      setLoadedOnce(true);
      if (!r.ok) {
        setErr(r.message);
        return;
      }
      setQboInvoice(r.qboInvoice);
      setPayments(r.payments);
      router.refresh();
    });
  }

  function doImport(qboPaymentId: string) {
    setMsg(null);
    setErr(null);
    setImportingId(qboPaymentId);
    start(async () => {
      const r = await importQuickbooksPayment(invoiceId, qboPaymentId);
      setImportingId(null);
      if (!r.ok) {
        setErr(r.message);
        if (r.code === "IN_PROGRESS" || r.code === "PARTIAL_IMPORT") refresh();
        return;
      }
      setMsg(r.alreadyImported ? "That payment was already imported." : `Imported ${money(r.appliedAmount)} from QuickBooks.`);
      // Re-pull live state and the server-rendered payment history.
      refresh();
    });
  }

  const rows = payments ?? [];

  return (
    <section className="min-w-0 space-y-3 rounded-md border border-desktop-border bg-card p-4">
      <div className="flex items-center justify-between gap-3">
        <h2 className="font-semibold">QuickBooks payments</h2>
        <button
          type="button"
          onClick={refresh}
          disabled={pending}
          className="inline-flex h-8 items-center gap-1.5 rounded-sm border border-desktop-border px-3 text-[13px] font-medium hover:bg-muted disabled:opacity-50"
        >
          {pending && !importingId ? <Loader2 className="size-3.5 animate-spin" /> : <RefreshCw className="size-3.5" />}
          Refresh QuickBooks Status
        </button>
      </div>

      {qboInvoice && (
        <p className="text-[13px] text-muted-foreground">
          QuickBooks invoice <span className="font-medium text-desktop-text">{qboInvoice.docNumber ?? "(auto-numbered)"}</span> · total{" "}
          {money(qboInvoice.totalAmt)} · <span className="font-medium text-desktop-text">balance {money(qboInvoice.balance)}</span>
        </p>
      )}

      {/* Durable imported rows (shown even before a refresh). */}
      {importedRows.length > 0 && (
        <ul className="space-y-1.5">
          {importedRows.map((r) => (
            <li key={r.id} className="rounded-sm border border-desktop-border bg-muted/40 p-2.5 text-[12.5px]">
              <p className="flex items-center gap-1.5 font-medium text-desktop-success">
                <CheckCircle2 className="size-4" /> Payment imported
              </p>
              <p className="text-muted-foreground">
                Applied to this invoice: <span className="font-medium text-desktop-text">{money(r.appliedAmount)}</span>
                {" · "}Date: {fmtDate(r.quickbooksTxnDate)}
                {r.quickbooksReference ? ` · Reference: ${r.quickbooksReference}` : ""}
              </p>
              <p className="text-muted-foreground">
                {r.localPaymentId ? (
                  <Link href={`/payments/${r.localPaymentId}`} className="text-primary hover:underline">
                    View local payment
                  </Link>
                ) : (
                  "Local payment link pending -- run Refresh."
                )}
                {" · "}Imported: {fmtDateTime(r.importedAt)}
              </p>
              {r.reconciliationState === "reconciliation_required" && (
                <p className="mt-1 flex items-start gap-1.5 text-desktop-warning">
                  <AlertTriangle className="mt-0.5 size-3.5 shrink-0" />
                  Reconciliation required{r.reconciliationDetail ? `: ${r.reconciliationDetail}` : "."}
                </p>
              )}
            </li>
          ))}
        </ul>
      )}

      {reconRows.length > 0 && importedRows.length === 0 && (
        <p className="flex items-start gap-1.5 rounded-sm border border-desktop-warning/30 bg-desktop-warning/5 p-2 text-[12px] text-desktop-warning">
          <AlertTriangle className="mt-0.5 size-3.5 shrink-0" />
          Reconciliation required on a previously imported QuickBooks payment. Run Refresh for details.
        </p>
      )}

      {/* Live discovery results (after a refresh). */}
      {loadedOnce && !err && (
        <>
          {rows.length === 0 ? (
            <p className="text-[12.5px] text-muted-foreground">No QuickBooks payments found for this invoice.</p>
          ) : (
            <ul className="space-y-1.5">
              {rows.map((p) => (
                <li key={p.quickbooksPaymentId} className="rounded-sm border border-desktop-border p-2.5 text-[12.5px]">
                  <div className="flex flex-wrap items-center justify-between gap-2">
                    <div>
                      <p className="font-medium text-desktop-text">QuickBooks Payment</p>
                      <p className="text-muted-foreground">
                        Date: {fmtDate(p.txnDate)} · Applied to this invoice:{" "}
                        <span className="font-medium text-desktop-text">{money(p.appliedToInvoice)}</span>
                        {Math.abs(p.totalAmt - p.appliedToInvoice) > 0.005 ? ` (of ${money(p.totalAmt)} total)` : ""}
                        {p.referenceNumber ? ` · Reference: ${p.referenceNumber}` : ""}
                        {p.paymentMethod ? ` · ${p.paymentMethod}` : ""}
                      </p>
                    </div>
                    <div className="shrink-0">
                      {p.voided ? (
                        <span className="text-desktop-warning">Voided in QuickBooks</span>
                      ) : p.importState === "imported" ? (
                        <span className="inline-flex items-center gap-1 font-medium text-desktop-success">
                          <CheckCircle2 className="size-3.5" /> Imported
                        </span>
                      ) : p.importState === "pending" ? (
                        <span className="text-muted-foreground">Import in progress…</span>
                      ) : (
                        <button
                          type="button"
                          onClick={() => doImport(p.quickbooksPaymentId)}
                          disabled={pending}
                          className="inline-flex h-7 items-center gap-1.5 rounded-sm bg-primary px-2.5 text-[12.5px] font-medium text-primary-foreground hover:bg-primary-hover disabled:opacity-50"
                        >
                          {importingId === p.quickbooksPaymentId ? <Loader2 className="size-3 animate-spin" /> : null}
                          {p.importState === "failed" ? "Retry import" : "Import Payment"}
                        </button>
                      )}
                    </div>
                  </div>
                  {p.reconciliationState === "reconciliation_required" && (
                    <p className="mt-1 flex items-start gap-1.5 text-desktop-warning">
                      <AlertTriangle className="mt-0.5 size-3.5 shrink-0" /> Reconciliation required.
                    </p>
                  )}
                </li>
              ))}
            </ul>
          )}
        </>
      )}

      {!loadedOnce && importedRows.length === 0 && (
        <p className="text-[12px] text-muted-foreground">
          Click “Refresh QuickBooks Status” to check for payments applied in QuickBooks. This only reads QuickBooks — it never records
          a payment on its own.
        </p>
      )}

      {msg && (
        <p className="flex items-start gap-1.5 rounded-sm border border-desktop-success/30 bg-desktop-success/5 p-2 text-[12px] text-desktop-success">
          <CheckCircle2 className="mt-0.5 size-3.5 shrink-0" />
          {msg}
        </p>
      )}
      {err && (
        <p className="flex items-start gap-1.5 rounded-sm border border-danger/30 bg-danger/5 p-2 text-[12px] text-danger">
          <AlertTriangle className="mt-0.5 size-3.5 shrink-0" />
          {err}
        </p>
      )}
      <p className="text-[11px] text-muted-foreground">
        Read-only discovery. Importing creates one ordinary Truck Dispatch Pro payment (Source: QuickBooks) and never changes anything
        in QuickBooks. Sandbox.
      </p>
    </section>
  );
}
