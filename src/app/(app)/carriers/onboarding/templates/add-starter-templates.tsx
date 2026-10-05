"use client";

import { useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { FileSignature, Loader2 } from "lucide-react";
import { Button } from "@/components/ui/button";
import { addStarterTemplates } from "./actions";

// One click: the standard agreements as drafts with this company's name and
// state filled in. Shown to owners/admins while any of them is missing.
export function AddStarterTemplates({ missing }: { missing: string[] }) {
  const router = useRouter();
  const [pending, start] = useTransition();
  const [message, setMessage] = useState<{ tone: "ok" | "error"; text: string } | null>(null);

  function add() {
    setMessage(null);
    start(async () => {
      const r = await addStarterTemplates();
      if (!r.ok) return setMessage({ tone: "error", text: r.error });
      setMessage({ tone: "ok", text: r.added.length ? `Added as drafts: ${r.added.join(", ")}.` : "You already have all of them." });
      router.refresh();
    });
  }

  return (
    <div className="rounded-md border border-primary/30 bg-primary/5 p-3 text-[12.5px]" data-testid="starter-templates">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div className="max-w-2xl">
          <p className="flex items-center gap-1.5 font-semibold text-desktop-text">
            <FileSignature className="size-4 text-primary" /> Standard dispatch agreements
          </p>
          <p className="mt-1 text-muted-foreground">
            Add ready-made drafts of {missing.join(", ")}, with your company name and state filled in. They are written for
            carriers paid directly by the broker who pay you a weekly dispatch fee. Review and edit each one, have your attorney
            read it, then publish. Publishing locks the text.
          </p>
        </div>
        <Button type="button" size="sm" onClick={add} disabled={pending}>
          {pending ? <Loader2 className="size-3.5 animate-spin" /> : "Add standard agreements"}
        </Button>
      </div>
      {message && (
        <p role={message.tone === "error" ? "alert" : "status"} className={message.tone === "error" ? "mt-2 text-danger" : "mt-2 text-desktop-success"}>
          {message.text}
        </p>
      )}
    </div>
  );
}
