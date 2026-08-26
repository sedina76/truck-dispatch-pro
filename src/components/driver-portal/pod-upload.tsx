"use client";

import { useRouter } from "next/navigation";
import { useState } from "react";
import { AlertTriangle, CheckCircle2, Camera, Loader2, Upload } from "lucide-react";
import { StatusBadge } from "@/components/ui/status-badge";
import { DocumentScanner } from "@/components/documents/document-scanner";
import type { PodStatus } from "@/lib/documents/pod-status";

export function PodUpload({ loadId, status, rejectionReason }: { loadId: string; status: PodStatus; rejectionReason?: string | null }) {
  const router = useRouter();
  const [uploading, setUploading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [scannerOpen, setScannerOpen] = useState(false);

  // Shared by the plain file picker below and by the scanner's onCapture
  // (Phase 2Q.1) -- a scanned POD is just another File reaching this exact
  // same fetch to the exact same trusted route
  // (/api/driver-portal/upload-pod), which still does its own real
  // ownership check (dispatches.driver_id == the cookie-session driver,
  // never a client-supplied id), magic-byte validation, and safe-filename
  // storage write. The scanner has no way to bypass any of that -- it only
  // produces the File this function already knew how to send.
  async function uploadFile(file: File) {
    setUploading(true);
    setError(null);

    const formData = new FormData();
    formData.append("file", file);
    formData.append("load_id", loadId);

    try {
      const res = await fetch("/api/driver-portal/upload-pod", { method: "POST", body: formData });
      const body = await res.json();
      if (!res.ok) throw new Error(body?.error ?? "Upload failed.");
      router.refresh();
    } catch (err) {
      setError(err instanceof Error ? err.message : "Upload failed.");
      throw err; // re-thrown so the scanner keeps the scan on screen and offers Retry (Section L)
    } finally {
      setUploading(false);
    }
  }

  async function handleChange(e: React.ChangeEvent<HTMLInputElement>) {
    const file = e.target.files?.[0];
    if (!file) return;
    try {
      await uploadFile(file);
    } catch {
      // already surfaced via setError above
    }
  }

  return (
    <div className="border-t border-border pt-3">
      <div className="flex items-center justify-between">
        <p className="text-sm font-medium">Proof of Delivery</p>
        <StatusBadge status={status} />
      </div>
      {status === "verified" ? (
        <p className="mt-2 flex items-center gap-1.5 text-xs text-success">
          <CheckCircle2 className="size-3.5" /> POD verified -- nothing more needed.
        </p>
      ) : (
        <>
          {status === "rejected" && rejectionReason && (
            <p className="mt-2 flex items-start gap-1.5 rounded-lg border border-danger/30 bg-danger/5 px-3 py-2 text-xs text-danger">
              <AlertTriangle className="mt-0.5 size-3.5 shrink-0" />
              Rejected: {rejectionReason}
            </p>
          )}
        <div className="mt-2 flex gap-2">
          <button
            type="button"
            disabled={uploading}
            onClick={() => setScannerOpen(true)}
            className="flex h-11 flex-1 items-center justify-center gap-1.5 rounded-xl border border-dashed border-border bg-card text-xs font-medium text-muted-foreground disabled:opacity-60"
          >
            {uploading ? <Loader2 className="size-4 animate-spin" /> : <Camera className="size-4" />}
            Scan POD
          </button>
          <label className="flex h-11 flex-1 cursor-pointer items-center justify-center gap-1.5 rounded-xl border border-dashed border-border bg-card text-xs font-medium text-muted-foreground">
            <Upload className="size-4" />
            {status === "rejected" ? "Replace File" : "Choose File"}
            <input type="file" accept=".pdf,.jpg,.jpeg,.png" className="hidden" onChange={handleChange} disabled={uploading} />
          </label>
        </div>
        <DocumentScanner
          open={scannerOpen}
          onOpenChange={setScannerOpen}
          onCapture={uploadFile}
          multiPage
          documentLabel="POD"
        />
        </>
      )}
      {error && <p className="mt-1 text-xs text-danger">{error}</p>}
    </div>
  );
}
