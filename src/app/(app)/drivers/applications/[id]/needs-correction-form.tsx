"use client";

import { useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { Loader2 } from "lucide-react";
import { Button } from "@/components/ui/button";
import { useToast } from "@/components/ui/toast";

type ActionResult = { ok: true } | { ok: false; error: string };

export function NeedsCorrectionForm({
  applicationId,
  action,
}: {
  applicationId: string;
  action: (applicationId: string, formData: FormData) => Promise<ActionResult>;
}) {
  const router = useRouter();
  const toast = useToast();
  const [pending, startTransition] = useTransition();
  const [reason, setReason] = useState("");

  function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    if (!reason.trim()) { toast.show("error", "A reason is required."); return; }
    startTransition(async () => {
      const fd = new FormData();
      fd.set("correction_reason", reason.trim());
      const result = await action(applicationId, fd);
      if (!result.ok) { toast.show("error", result.error); return; }
      toast.show("success", "Sent back to the driver for correction.");
      setReason("");
      router.refresh();
    });
  }

  return (
    <form onSubmit={handleSubmit} className="space-y-3">
      <textarea
        value={reason}
        onChange={(e) => setReason(e.target.value)}
        rows={3}
        maxLength={2000}
        placeholder="e.g. The CDL photo is blurry -- please re-scan and resubmit."
        className="w-full rounded-lg border border-border bg-card px-3.5 py-2.5 text-sm shadow-elevation-1 outline-none focus-visible:border-primary focus-visible:ring-2 focus-visible:ring-primary/20"
      />
      <Button type="submit" variant="outline" disabled={pending} className="w-full">
        {pending ? <Loader2 className="size-3.5 animate-spin" /> : null} Send Back for Correction
      </Button>
    </form>
  );
}
