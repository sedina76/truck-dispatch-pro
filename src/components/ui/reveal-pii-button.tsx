"use client";

import { useState } from "react";
import { Eye, EyeOff, Loader2 } from "lucide-react";
import { Button } from "@/components/ui/button";

// Generic reveal-on-demand control for encrypted PII (SSNs, bank account
// numbers, ...). `onReveal` must be a bound server action reference (e.g.
// `revealDriverPii.bind(null, driverId, "ssn")`) passed down from a Server
// Component -- a plain closure can't cross the client boundary, but a
// "use server" function reference can.
export function RevealPiiButton({
  maskedValue,
  onReveal,
  promptForReason = false,
}: {
  maskedValue: string;
  onReveal: (reason?: string) => Promise<string | null>;
  promptForReason?: boolean;
}) {
  const [revealed, setRevealed] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function handleReveal() {
    setError(null);
    let reason: string | undefined;
    if (promptForReason) {
      reason = window.prompt("Reason for viewing this (recorded in the access log):") ?? undefined;
      if (reason === undefined) return;
    }
    setLoading(true);
    try {
      const value = await onReveal(reason);
      setRevealed(value ?? "Not on file");
    } catch (e) {
      setError(e instanceof Error ? e.message : "Could not reveal this value.");
    } finally {
      setLoading(false);
    }
  }

  return (
    <div className="flex items-center gap-2">
      <span className="font-mono text-sm">{revealed ?? maskedValue}</span>
      {error && <span className="text-xs text-danger">{error}</span>}
      {revealed ? (
        <Button type="button" variant="ghost" size="sm" onClick={() => setRevealed(null)} className="h-7 gap-1 px-2 text-xs">
          <EyeOff className="size-3.5" />
          Hide
        </Button>
      ) : (
        <Button type="button" variant="ghost" size="sm" onClick={handleReveal} disabled={loading} className="h-7 gap-1 px-2 text-xs">
          {loading ? <Loader2 className="size-3.5 animate-spin" /> : <Eye className="size-3.5" />}
          Reveal
        </Button>
      )}
    </div>
  );
}
