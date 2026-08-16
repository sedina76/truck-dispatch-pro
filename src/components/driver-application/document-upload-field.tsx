"use client";

import { useState } from "react";
import { CheckCircle2, Loader2, Upload } from "lucide-react";

export type UploadedDocument = {
  label: string;
  storage_path: string;
  file_name: string;
  uploaded_at: string;
};

export function DocumentUploadField({
  label,
  applicationId,
  onUploaded,
}: {
  label: string;
  applicationId: string;
  onUploaded: (doc: UploadedDocument) => void;
}) {
  const [status, setStatus] = useState<"idle" | "uploading" | "done" | "error">("idle");
  const [fileName, setFileName] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  async function handleChange(e: React.ChangeEvent<HTMLInputElement>) {
    const file = e.target.files?.[0];
    if (!file) return;

    setStatus("uploading");
    setError(null);
    setFileName(file.name);

    const formData = new FormData();
    formData.append("file", file);
    formData.append("application_id", applicationId);
    formData.append("label", label);

    try {
      const res = await fetch("/api/driver-application/upload", { method: "POST", body: formData });
      const body = await res.json();
      if (!res.ok) throw new Error(body?.error ?? "Upload failed.");
      onUploaded(body.document);
      setStatus("done");
    } catch (err) {
      setStatus("error");
      setError(err instanceof Error ? err.message : "Upload failed.");
    }
  }

  return (
    <div className="space-y-1.5">
      <label className="text-sm font-medium text-foreground">{label}</label>
      <label
        className="flex h-10 w-full cursor-pointer items-center gap-2 rounded-lg border border-dashed border-border bg-card px-3.5 text-sm text-muted-foreground transition-colors hover:border-primary/40"
      >
        {status === "uploading" ? (
          <Loader2 className="size-4 shrink-0 animate-spin" />
        ) : status === "done" ? (
          <CheckCircle2 className="size-4 shrink-0 text-success" />
        ) : (
          <Upload className="size-4 shrink-0" />
        )}
        <span className="truncate">
          {fileName ?? "Choose a file (PDF, JPEG, PNG -- 10 MB max)"}
        </span>
        <input type="file" accept=".pdf,.jpg,.jpeg,.png,.heic" className="hidden" onChange={handleChange} />
      </label>
      {error && <p className="text-xs text-danger">{error}</p>}
    </div>
  );
}
