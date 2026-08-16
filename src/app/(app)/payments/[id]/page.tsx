import Link from "next/link";
import { notFound } from "next/navigation";
import { AlertTriangle, FileText, CheckCircle2, Ban } from "lucide-react";
import { createClient } from "@/lib/supabase/server";
import { Button } from "@/components/ui/button";
import { StatusBadge } from "@/components/ui/status-badge";
import { voidPayment } from "../actions";
import { RegisterDesktopActions } from "@/components/desktop/actions-context";

export default async function PaymentDetailPage({
  params,
  searchParams,
}: {
  params: Promise<{ id: string }>;
  searchParams: Promise<{ error?: string }>;
}) {
  const { id } = await params;
  const { error } = await searchParams;
  const supabase = await createClient();

  const { data: payment } = await supabase.from("payments").select("*").eq("id", id).single();
  if (!payment) notFound();

  const { data: invoice } = await supabase
    .from("invoices")
    .select("id, invoice_number, bill_to_name, total_amount, balance_due")
    .eq("id", payment.invoice_id)
    .single();

  const profileIds = [payment.recorded_by, payment.voided_by].filter((v): v is string => !!v);
  const { data: profiles } = profileIds.length
    ? await supabase.from("profiles").select("id, full_name").in("id", profileIds)
    : { data: [] as { id: string; full_name: string }[] };
  const nameById = new Map((profiles ?? []).map((p) => [p.id, p.full_name]));

  const isVoided = payment.status === "voided";

  return (
    <div className="space-y-6">
      <RegisterDesktopActions
        title={`Payment ${payment.payment_number}`}
        printHref={`/payments/${id}/receipt`}
        exportOptions={[{ label: "Export PDF Receipt", href: `/payments/${id}/receipt` }]}
        email={{ entityType: "payment", entityId: id }}
      />
      <div>
        <Link href={`/invoices/${payment.invoice_id}`} className="text-sm font-medium text-primary hover:underline">
          &larr; Back to {invoice?.invoice_number ?? "invoice"}
        </Link>
      </div>

      {error && (
        <div className="flex items-start gap-2 rounded-lg border border-danger/30 bg-danger/5 px-3 py-2 text-sm text-danger">
          <AlertTriangle className="mt-0.5 size-4 shrink-0" />
          <span>{error}</span>
        </div>
      )}

      <div className="rounded-xl border border-border bg-card p-6 shadow-elevation-1">
        <div className="flex items-start justify-between">
          <div>
            <h1 className="text-2xl font-semibold tracking-tight">{payment.payment_number}</h1>
            <p className="mt-1 text-sm text-muted-foreground">
              Payment against {invoice?.invoice_number ?? "--"} ({invoice?.bill_to_name})
            </p>
          </div>
          <StatusBadge status={payment.status} />
        </div>

        {isVoided && (
          <div className="mt-4 flex items-start gap-2 rounded-lg border border-danger/30 bg-danger/5 px-3 py-2 text-sm">
            <Ban className="mt-0.5 size-4 shrink-0 text-danger" />
            <div>
              <p className="font-medium text-danger">
                Voided {payment.voided_at && new Date(payment.voided_at).toLocaleString()}
                {payment.voided_by && ` by ${nameById.get(payment.voided_by) ?? "a team member"}`}
              </p>
              <p className="mt-0.5 text-muted-foreground">Reason: {payment.void_reason}</p>
              <p className="mt-1 text-xs text-muted-foreground">
                This payment no longer counts toward the invoice balance, but the record is preserved for audit history.
              </p>
            </div>
          </div>
        )}

        <dl className="mt-5 grid grid-cols-2 gap-x-6 gap-y-4 text-sm sm:grid-cols-3">
          <Field label="Payment date" value={new Date(payment.received_at).toLocaleDateString()} />
          <Field label="Amount" value={`$${Number(payment.amount).toLocaleString(undefined, { minimumFractionDigits: 2 })}`} />
          <Field label="Method" value={<span className="capitalize">{String(payment.method).replace(/_/g, " ")}</span>} />
          <Field label="Reference / confirmation #" value={payment.reference_number ?? "--"} />
          <Field label="Check #" value={payment.check_number ?? "--"} />
          <Field label="Bank reference" value={payment.bank_reference ?? "--"} />
          <Field label="Recorded by" value={payment.recorded_by ? (nameById.get(payment.recorded_by) ?? "--") : "--"} />
          <Field label="Recorded at" value={new Date(payment.created_at).toLocaleString()} />
        </dl>

        {payment.notes && (
          <div className="mt-4 border-t border-border pt-4 text-sm">
            <p className="text-xs font-medium uppercase tracking-wide text-muted-foreground">Notes</p>
            <p className="mt-1">{payment.notes}</p>
          </div>
        )}

        <div className="mt-6 flex flex-wrap items-center gap-2 border-t border-border pt-4">
          <Link
            href={`/payments/${id}/receipt`}
            target="_blank"
            className="inline-flex items-center gap-1.5 rounded-lg border border-border bg-card px-3 py-1.5 text-sm font-medium transition-colors hover:bg-muted"
          >
            <FileText className="size-4" />
            View Receipt
          </Link>
          <a
            href={`/payments/${id}/receipt?autoprint=1`}
            target="_blank"
            className="inline-flex items-center gap-1.5 rounded-lg border border-border bg-card px-3 py-1.5 text-sm font-medium transition-colors hover:bg-muted"
          >
            <FileText className="size-4" />
            Download Receipt
          </a>

          {!isVoided && (
            <details className="ml-auto">
              <summary className="inline-flex cursor-pointer list-none items-center gap-1.5 rounded-lg border border-danger/30 px-3 py-1.5 text-sm font-medium text-danger transition-colors hover:bg-danger/10">
                <Ban className="size-4" />
                Void Payment
              </summary>
              <form action={voidPayment.bind(null, id, payment.invoice_id)} className="mt-3 w-80 space-y-2 rounded-lg border border-border bg-muted/50 p-3">
                <label className="text-xs font-medium">
                  Reason (required) <span className="text-danger">*</span>
                </label>
                <textarea
                  name="void_reason"
                  required
                  rows={2}
                  className="w-full rounded-lg border border-border bg-card px-2.5 py-1.5 text-sm shadow-elevation-1 outline-none focus-visible:border-primary focus-visible:ring-2 focus-visible:ring-primary/20"
                  placeholder="e.g. Entered in error, duplicate payment, wrong invoice..."
                />
                <Button type="submit" variant="danger" size="sm" className="w-full">
                  Confirm Void
                </Button>
              </form>
            </details>
          )}
          {isVoided && (
            <span className="ml-auto inline-flex items-center gap-1.5 text-xs text-muted-foreground">
              <CheckCircle2 className="size-3.5" />
              Voided payments cannot be edited or re-voided.
            </span>
          )}
        </div>
      </div>
    </div>
  );
}

function Field({ label, value }: { label: string; value: React.ReactNode }) {
  return (
    <div>
      <p className="text-xs font-medium uppercase tracking-wide text-muted-foreground">{label}</p>
      <p className="mt-0.5">{value}</p>
    </div>
  );
}
