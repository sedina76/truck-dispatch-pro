"use client";

import { useRef, useState } from "react";
import { Sparkles, Loader2, AlertTriangle, CheckCircle2 } from "lucide-react";
import { readRateConfirmation } from "@/app/(app)/loads/ai-actions";
import { fillForm, type Summary } from "@/components/loads/rate-con-fill";

// "Fill from rate confirmation" on New Load: upload the broker's rate con
// (PDF or photo), the AI reads it, and the form below is filled in. Filled
// fields get a blue outline, ones the AI wasn't sure about an amber one --
// nothing is saved until the dispatcher reviews and clicks Create Load. The
// same file is attached as the load's Rate Confirmation document.





export function RateConAutofill() {
  const boxRef = useRef<HTMLDivElement>(null);
  const fileRef = useRef<HTMLInputElement>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [summary, setSummary] = useState<Summary | null>(null);

  async function handleFile(file: File | undefined) {
    if (!file) return;
    setBusy(true);
    setError(null);
    setSummary(null);
    const fd = new FormData();
    fd.append("file", file);
    const result = await readRateConfirmation(fd).catch(() => ({ ok: false as const, error: "The document could not be read. Try again, or fill the form by hand." }));
    setBusy(false);
    if (fileRef.current) fileRef.current.value = "";
    if (!result.ok) {
      setError(result.error);
      return;
    }
    const form = boxRef.current?.closest("form");
    if (!form) return;
    setSummary(fillForm(form, result.load, result.brokerId, file));
  }

  return (
    <div ref={boxRef} className="rounded-sm border border-primary/30 bg-primary/5 px-3 py-2.5" data-testid="rate-con-autofill">
      <style>{`
        [data-ai-filled="1"] { box-shadow: 0 0 0 2px rgba(37, 99, 235, 0.45) !important; }
        [data-ai-filled="check"] { box-shadow: 0 0 0 2px rgba(217, 119, 6, 0.75) !important; background-color: rgba(217, 119, 6, 0.06) !important; }
      `}</style>
      <div className="flex flex-wrap items-center justify-between gap-2">
        <div className="min-w-0">
          <p className="flex items-center gap-1.5 text-[13px] font-semibold text-desktop-text">
            <Sparkles className="size-4 text-primary" /> Fill from rate confirmation
          </p>
          <p className="text-[11.5px] text-desktop-text-muted">Upload the broker&apos;s rate con (PDF or photo). The form fills itself -- review the outlined fields, then Create Load.</p>
        </div>
        <button
          type="button"
          disabled={busy}
          onClick={() => fileRef.current?.click()}
          className="inline-flex h-8 shrink-0 items-center gap-1.5 rounded-sm bg-primary px-3 text-[12.5px] font-medium text-primary-foreground hover:bg-primary-hover disabled:opacity-60"
        >
          {busy ? <Loader2 className="size-3.5 animate-spin" /> : <Sparkles className="size-3.5" />}
          {busy ? "Reading document..." : summary ? "Read another" : "Upload rate con"}
        </button>
        <input ref={fileRef} type="file" accept=".pdf,.jpg,.jpeg,.png" className="hidden" onChange={(e) => handleFile(e.target.files?.[0])} />
      </div>

      {busy && <p className="mt-2 text-[12px] text-desktop-text-muted">Reading the document -- this usually takes 10-30 seconds.</p>}
      {error && (
        <p className="mt-2 flex items-start gap-1.5 text-[12px] text-danger">
          <AlertTriangle className="mt-0.5 size-3.5 shrink-0" /> {error}
        </p>
      )}
      {summary && (
        <div className="mt-2 space-y-1 text-[12px]">
          <p className="flex items-center gap-1.5 font-medium text-desktop-success">
            <CheckCircle2 className="size-3.5" /> Filled {summary.filled} field{summary.filled === 1 ? "" : "s"}
            {summary.kind !== "rate_confirmation" && summary.kind !== "other" ? ` from a ${summary.kind.replace(/_/g, " ")}` : ""}. Review the outlined fields before saving.
          </p>
          {summary.check.length > 0 && (
            <p className="text-warning">
              Double-check (amber): {summary.check.join(", ")}.
            </p>
          )}
          {summary.brokerMissing && (
            <p className="text-warning">
              Broker &quot;{summary.brokerMissing}&quot; isn&apos;t in your list --{" "}
              <a href={`/brokers/new?legal_name=${encodeURIComponent(summary.brokerMissing)}${summary.brokerMc ? `&mc_number=${encodeURIComponent(summary.brokerMc)}` : ""}`} target="_blank" rel="noopener" className="font-medium text-primary hover:underline">
                add it (new tab)
              </a>
              , then reload this page and upload the rate con again so it&apos;s picked automatically.
            </p>
          )}
          {summary.extraStops > 0 && <p className="text-desktop-text-muted">{summary.extraStops} more stop{summary.extraStops === 1 ? "" : "s"} added under Additional Stops.</p>}
          {summary.notes.map((n) => (
            <p key={n} className="text-desktop-text-muted">
              Note: {n}
            </p>
          ))}
          <p className="text-desktop-text-muted">The document is attached as this load&apos;s Rate Confirmation.</p>
        </div>
      )}
    </div>
  );
}
