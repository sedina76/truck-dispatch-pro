"use client";

import { useRef, useState } from "react";
import { useRouter } from "next/navigation";
import { Camera, Loader2 } from "lucide-react";
import { Button } from "@/components/ui/button";
import { uploadLoadDocument } from "@/app/(app)/loads/pod-actions";
import { MAX_UPLOAD_BYTES, ALLOWED_UPLOAD_MIME_TYPES } from "@/lib/documents/upload-limits";
import { DocumentScanner } from "@/components/documents/document-scanner";

// Calls uploadLoadDocument()/uploadPod() directly rather than via a plain
// <form action={...}> -- same reasoning as GeneratePacketButton
// (src/components/invoices/generate-packet-button.tsx): the action now
// RETURNS {ok:false, error} for every expected validation failure (invalid
// PDF signature, oversized file, unsupported type, ...) instead of
// throwing, specifically so this component can show that message inline
// next to the form instead of Next's generic "Application error" page
// replacing the whole load detail view. Authorization, RLS, Storage, and
// document-row behavior are all unchanged -- only how a failure is
// reported changed, never what's allowed.
export function UploadDocumentForm({
  loadId,
  documentType,
  label,
  compact = false,
  buttonVariant,
  onUploaded,
}: {
  loadId: string;
  documentType: string;
  label: string;
  /** Matches simple-document-slot.tsx's tighter row layout instead of the POD section's spacious one. */
  compact?: boolean;
  buttonVariant?: "outline";
  // Phase 2I.1 live-verification defect fix: router.refresh() below only
  // re-renders this ROUTE's own Server Components -- correct and
  // sufficient for the Load Detail page (every caller until now), which
  // has no other data source. The Dispatch Drawer's DocumentsPanel
  // (Part C) is different -- it renders inside a client component that
  // fetches its own data via a separate getDispatchDrawerData() call
  // stored in local state, which router.refresh() cannot reach. Without
  // this, a real upload/replace succeeded (confirmed at the DB layer)
  // but the drawer's POD status/Billing Readiness/toolbar count stayed
  // silently stale until the drawer was closed and reopened -- worse
  // than a cosmetic issue, since nothing on screen indicated the upload
  // had actually worked. Optional and additive: every existing caller
  // (Load Detail's own Billing Documents section) doesn't pass this, so
  // its behavior is byte-for-byte unchanged.
  onUploaded?: () => void | Promise<void>;
}) {
  const router = useRouter();
  const inputRef = useRef<HTMLInputElement>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [scannerOpen, setScannerOpen] = useState(false);

  // Shared by the plain <input>'s submit below and by the scanner's
  // onCapture (Phase 2Q.1) -- both paths end at uploadLoadDocument(), so a
  // scanned document is validated, stored, and logged exactly like a
  // chosen one. Throws on failure so the scanner (when it's the caller)
  // keeps the scan on screen and offers Retry instead of losing it.
  async function submitFile(file: File) {
    setError(null);

    // Pre-check size/type client-side, BEFORE ever sending the request --
    // not a replacement for the server-side checks (pod-actions.ts's own
    // checks remain authoritative and un-loosened; a client-side check
    // alone is never trustworthy on its own), but this specifically avoids
    // a real Next.js platform limitation found live: a large file sent
    // straight to a Server Action can hit Next's OWN generic "Server
    // Components render" error before this app's "File is too large"
    // check ever runs, even with next.config.ts's serverActions.
    // bodySizeLimit raised. Rejecting oversized/wrong-type files here
    // means that request is never sent at all, so that platform boundary
    // never comes into play for the common case. A scanner-produced File
    // is always a real image/jpeg or application/pdf blob, so it always
    // passes this unchanged.
    if (file.size > MAX_UPLOAD_BYTES) {
      const msg = "File is too large (15 MB max).";
      setError(msg);
      throw new Error(msg);
    }
    if (!(ALLOWED_UPLOAD_MIME_TYPES as readonly string[]).includes(file.type)) {
      const msg = "Unsupported file type. Use PDF, JPG, or PNG.";
      setError(msg);
      throw new Error(msg);
    }

    setLoading(true);
    const formData = new FormData();
    formData.append("file", file);

    let result: Awaited<ReturnType<typeof uploadLoadDocument>>;
    try {
      result = await uploadLoadDocument(loadId, documentType, formData);
    } catch (e) {
      // Belt-and-suspenders: uploadLoadDocument() no longer throws for any
      // expected validation failure, but a genuinely unexpected error
      // (e.g. a network drop mid-request) still could -- never let that
      // hang the button silently or crash the page.
      const msg = e instanceof Error ? e.message : "Could not upload this file.";
      setError(msg);
      setLoading(false);
      throw new Error(msg);
    }
    setLoading(false);
    if (!result.ok) {
      setError(result.error);
      throw new Error(result.error);
    }
    if (inputRef.current) inputRef.current.value = "";
    router.refresh();
    await onUploaded?.();
  }

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    const file = inputRef.current?.files?.[0];
    if (!file) return;
    try {
      await submitFile(file);
    } catch {
      // already surfaced via setError above
    }
  }

  return (
    <form onSubmit={handleSubmit} className="flex flex-wrap items-center gap-2">
      <input
        ref={inputRef}
        type="file"
        name="file"
        accept=".pdf,.jpg,.jpeg,.png"
        required
        disabled={loading}
        className={
          compact
            ? "w-32 text-[11px] text-[var(--color-text-muted)] file:mr-1 file:rounded file:border-0 file:bg-muted file:px-1.5 file:py-0.5 file:text-[10px] disabled:opacity-60"
            : "text-xs text-[var(--color-text-muted)] file:mr-2 file:rounded-md file:border-0 file:bg-primary file:px-3 file:py-1.5 file:text-xs file:font-medium file:text-primary-foreground disabled:opacity-60"
        }
      />
      <Button type="submit" size="sm" variant={buttonVariant} disabled={loading}>
        {loading ? <Loader2 className="size-3.5 animate-spin" /> : null}
        {label}
      </Button>
      <Button type="button" size="sm" variant="outline" disabled={loading} onClick={() => setScannerOpen(true)}>
        <Camera className="size-3.5" />
        Scan
      </Button>
      <DocumentScanner
        open={scannerOpen}
        onOpenChange={setScannerOpen}
        onCapture={submitFile}
        multiPage
        documentLabel={documentType.replace(/_/g, " ")}
      />
      {error && <span className="w-full text-xs text-danger">{error}</span>}
    </form>
  );
}
