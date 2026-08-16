"use client";

import { useState } from "react";
import { Copy, Check, AlertTriangle } from "lucide-react";

// Shown exactly once, immediately after a temporary password is
// generated (company creation, admin creation, or a password reset) --
// spec: "Do NOT display a generated password again after the creation
// confirmation." This component only ever receives a password its caller
// just got back from a server action's return value; nothing here reads
// or stores it anywhere.
export function TempPasswordReveal({ email, password, onClose }: { email: string; password: string; onClose: () => void }) {
  const [copied, setCopied] = useState(false);

  async function copy() {
    await navigator.clipboard.writeText(password);
    setCopied(true);
    setTimeout(() => setCopied(false), 2000);
  }

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/60 p-4">
      <div className="w-full max-w-md rounded-xl border border-slate-800 bg-slate-900 p-5 shadow-2xl">
        <div className="mb-3 flex items-center gap-2 text-amber-400">
          <AlertTriangle className="size-4" />
          <p className="text-sm font-semibold">Save this password now</p>
        </div>
        <p className="mb-4 text-[12.5px] text-slate-400">
          This is the only time this password will be shown. It is not stored anywhere in plaintext.
        </p>
        <div className="space-y-2">
          <div>
            <p className="text-[10.5px] font-medium uppercase tracking-wide text-slate-500">Email</p>
            <p className="text-sm text-slate-200">{email}</p>
          </div>
          <div>
            <p className="text-[10.5px] font-medium uppercase tracking-wide text-slate-500">Temporary Password</p>
            <div className="flex items-center gap-2">
              <code className="flex-1 rounded-lg border border-slate-700 bg-slate-950 px-3 py-2 font-mono text-[13px] text-emerald-400">{password}</code>
              <button type="button" onClick={copy} className="flex size-9 shrink-0 items-center justify-center rounded-lg border border-slate-700 text-slate-400 hover:text-slate-200">
                {copied ? <Check className="size-4 text-emerald-400" /> : <Copy className="size-4" />}
              </button>
            </div>
          </div>
        </div>
        <button
          type="button"
          onClick={onClose}
          className="mt-5 flex h-10 w-full items-center justify-center rounded-lg bg-blue-500 text-sm font-semibold text-white hover:bg-blue-600"
        >
          I&apos;ve saved this password
        </button>
      </div>
    </div>
  );
}
