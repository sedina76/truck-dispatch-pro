"use client";

import { useRouter } from "next/navigation";
import { useState } from "react";
import { AlertTriangle, CheckCircle2, Loader2, Upload } from "lucide-react";
import { StatusBadge } from "@/components/ui/status-badge";
import type { PodStatus } from "@/lib/documents/pod-status";

export function PodUpload({ loadId, status, rejectionReason }: { loadId: string; status: PodStatus; rejectionReason?: string | null }) {
  const router = useRouter();
  const [uploading, setUploading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function handleChange(e: React.ChangeEvent<HTMLInputElement>) {
    const file = e.target.files?.[0];
    if (!file) return;
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
    } finally {
      setUploading(false);
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
        <label className="mt-2 flex h-11 w-full cursor-pointer items-center gap-2 rounded-xl border border-dashed border-border bg-card px-3 text-xs text-muted-foreground">
          {uploading ? <Loader2 className="size-4 animate-spin" /> : <Upload className="size-4" />}
          {status === "rejected" ? "Replace POD (PDF, JPG, PNG)" : "Upload POD (PDF, JPG, PNG)"}
          <input type="file" accept=".pdf,.jpg,.jpeg,.png" className="hidden" onChange={handleChange} disabled={uploading} />
        </label>
        </>
      )}
      {error && <p className="mt-1 text-xs text-danger">{error}</p>}
    </div>
  );
}
