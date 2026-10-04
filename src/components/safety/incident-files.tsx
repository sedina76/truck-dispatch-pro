"use client";

import { useRef, useState } from "react";
import { useRouter } from "next/navigation";
import { FileText, ImagePlus } from "lucide-react";
import { Button } from "@/components/ui/button";
import { DocumentLinkButton } from "@/components/drivers/document-link-button";
import type { SafetyActionState } from "@/app/(app)/safety/actions";

export type IncidentFile = { id: string; name: string; isPhoto: boolean; url: string | null; addedAt: string };

// A request to the server can't be much over ~4 MB on the hosting platform,
// so files go up one at a time and big phone photos are shrunk first
// (longest side 2400 px, JPEG) -- still plenty sharp for damage photos.
const SEND_LIMIT = 4 * 1024 * 1024;
const SHRINK_OVER = 1.5 * 1024 * 1024;
const MAX_EDGE = 2400;

async function shrinkPhoto(file: File): Promise<File> {
  if (!file.type.startsWith("image/") || file.size <= SHRINK_OVER) return file;
  const url = URL.createObjectURL(file);
  try {
    const img = await new Promise<HTMLImageElement>((resolve, reject) => {
      const el = new Image();
      el.onload = () => resolve(el);
      el.onerror = () => reject(new Error(`Could not read ${file.name}.`));
      el.src = url;
    });
    const scale = Math.min(1, MAX_EDGE / Math.max(img.naturalWidth, img.naturalHeight));
    const canvas = document.createElement("canvas");
    canvas.width = Math.max(1, Math.round(img.naturalWidth * scale));
    canvas.height = Math.max(1, Math.round(img.naturalHeight * scale));
    const ctx = canvas.getContext("2d");
    if (!ctx) return file;
    ctx.drawImage(img, 0, 0, canvas.width, canvas.height);
    const blob = await new Promise<Blob | null>((resolve) => canvas.toBlob(resolve, "image/jpeg", 0.85));
    if (!blob || blob.size >= file.size) return file;
    return new File([blob], file.name.replace(/\.(png|jpe?g)$/i, "") + ".jpg", { type: "image/jpeg" });
  } finally {
    URL.revokeObjectURL(url);
  }
}

// Photos and papers (police report, ticket, claim letter, inspection report)
// for one incident: thumbnails for photos, a View button for PDFs, and one
// picker that takes several files at once (on a phone it offers the camera).
export function IncidentFiles({
  files,
  upload,
  openFile,
  canUpload = true,
}: {
  canUpload?: boolean;
  files: IncidentFile[];
  upload: (prev: SafetyActionState, formData: FormData) => Promise<SafetyActionState>;
  openFile: (documentId: string) => Promise<string | { error: string }>;
}) {
  const router = useRouter();
  const inputRef = useRef<HTMLInputElement>(null);
  const [busy, setBusy] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [done, setDone] = useState<string | null>(null);

  async function send(e: React.FormEvent) {
    e.preventDefault();
    const picked = Array.from(inputRef.current?.files ?? []);
    if (picked.length === 0) return setError("Choose at least one photo or file.");
    setError(null);
    setDone(null);
    let sent = 0;
    try {
      for (const [i, original] of picked.entries()) {
        setBusy(`Uploading ${i + 1} of ${picked.length}...`);
        const file = await shrinkPhoto(original);
        if (file.size > SEND_LIMIT) throw new Error(`${original.name} is larger than 4 MB. Use a smaller file (or a photo instead of a scan).`);
        const fd = new FormData();
        fd.append("files", file);
        const res = await upload({ error: null }, fd);
        if (res.error) throw new Error(res.error);
        sent++;
      }
      setDone(sent === 1 ? "Added 1 file." : `Added ${sent} files.`);
      if (inputRef.current) inputRef.current.value = "";
    } catch (err) {
      setError((sent > 0 ? `Added ${sent}, then stopped: ` : "") + (err instanceof Error ? err.message : "Upload failed."));
    } finally {
      setBusy(null);
      if (sent > 0) router.refresh();
    }
  }

  const photos = files.filter((f) => f.isPhoto);
  const papers = files.filter((f) => !f.isPhoto);

  return (
    <div className="space-y-3" data-testid="incident-files">
      {files.length === 0 && <p className="text-[12.5px] text-muted-foreground">No photos or papers yet.</p>}
      {photos.length > 0 && (
        <div className="grid grid-cols-3 gap-2 sm:grid-cols-5">
          {photos.map((p) =>
            p.url ? (
              <a key={p.id} href={p.url} target="_blank" rel="noopener noreferrer" className="group block overflow-hidden rounded-sm border border-desktop-border bg-muted" title={p.name}>
                {/* eslint-disable-next-line @next/next/no-img-element -- short-lived signed URL from private storage */}
                <img src={p.url} alt={p.name} className="aspect-square w-full object-cover transition-transform group-hover:scale-105" loading="lazy" />
              </a>
            ) : (
              <div key={p.id} className="flex aspect-square items-center justify-center rounded-sm border border-desktop-border bg-muted p-1 text-center text-[10.5px] text-muted-foreground">
                {p.name}
              </div>
            )
          )}
        </div>
      )}
      {papers.length > 0 && (
        <ul className="divide-y divide-desktop-border rounded-sm border border-desktop-border">
          {papers.map((f) => (
            <li key={f.id} className="flex items-center justify-between gap-2 px-2.5 py-1.5 text-[12.5px]">
              <span className="flex min-w-0 items-center gap-1.5">
                <FileText className="size-3.5 shrink-0 text-muted-foreground" />
                <span className="truncate">{f.name}</span>
              </span>
              <DocumentLinkButton label="View" getUrl={() => openFile(f.id)} />
            </li>
          ))}
        </ul>
      )}

      {canUpload && (
      <form onSubmit={send} className="flex flex-wrap items-center gap-2 border-t border-desktop-border pt-3">
        <label className="inline-flex cursor-pointer items-center gap-1.5 text-[12.5px] font-medium text-desktop-text">
          <ImagePlus className="size-4 text-primary" />
          <input
            ref={inputRef}
            type="file"
            name="files"
            multiple
            required
            accept="image/jpeg,image/png,application/pdf"
            className="w-56 text-[11.5px] text-muted-foreground file:mr-1.5 file:rounded file:border-0 file:bg-muted file:px-2 file:py-1 file:text-[11px]"
          />
        </label>
        <Button type="submit" size="sm" variant="outline" disabled={!!busy}>
          {busy ?? "Add photos / files"}
        </Button>
        <span className="text-[11px] text-muted-foreground">JPG, PNG or PDF. Big photos are shrunk automatically.</span>
        {error && (
          <p role="alert" className="w-full text-[12px] text-danger">
            {error}
          </p>
        )}
        {done && !busy && (
          <p role="status" className="w-full text-[12px] text-desktop-success">
            {done}
          </p>
        )}
      </form>
      )}
    </div>
  );
}
