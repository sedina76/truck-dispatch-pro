"use client";

import { useState } from "react";
import { FileText, Loader2 } from "lucide-react";

// getUrl must be a bound server action reference (e.g.
// getApplicationDocumentUrl.bind(null, applicationId, storagePath)) --
// generates a short-lived signed URL server-side each time it's clicked
// rather than embedding a long-lived link, since the bucket is private.
export function DocumentLinkButton({ label, getUrl }: { label: string; getUrl: () => Promise<string> }) {
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function handleClick() {
    setLoading(true);
    setError(null);
    try {
      const url = await getUrl();
      window.open(url, "_blank", "noopener,noreferrer");
    } catch (e) {
      setError(e instanceof Error ? e.message : "Could not open this document.");
    } finally {
      setLoading(false);
    }
  }

  return (
    <div className="flex items-center gap-2">
      <button
        type="button"
        onClick={handleClick}
        disabled={loading}
        className="inline-flex items-center gap-1.5 rounded-lg border border-border bg-card px-3 py-1.5 text-sm font-medium transition-colors hover:bg-muted disabled:opacity-60"
      >
        {loading ? <Loader2 className="size-3.5 animate-spin" /> : <FileText className="size-3.5" />}
        {label}
      </button>
      {error && <span className="text-xs text-danger">{error}</span>}
    </div>
  );
}
