"use client";

import { useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { Loader2, Copy, CheckCircle2 } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { useToast } from "@/components/ui/toast";
import { inviteDriverApplication } from "../applications/actions";
import { WORKER_TYPE_LABELS, type DriverWorkerType } from "@/lib/driver-w9/types";

function Field({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <label className="block space-y-1 text-[12px] font-medium text-desktop-text">
      {label}
      {children}
    </label>
  );
}

type Carrier = { id: string; legal_name: string };

// Phase 2Q.2B: carrier selection. If the org has exactly one active
// carrier it's preselected and the dropdown is hidden (Section B: "hiding
// the selector is acceptable if UX remains clear") -- with 2+, a real
// choice is required, defaulting to nothing rather than silently picking
// the first/oldest one. worker_type defaults to Company Driver (the
// no-W-9 case) so a staff member who doesn't think about tax
// classification at all gets the safer, non-blocking default.
export function InviteDriverForm({ carriers }: { carriers: Carrier[] }) {
  const router = useRouter();
  const toast = useToast();
  const [pending, startTransition] = useTransition();
  const [firstName, setFirstName] = useState("");
  const [lastName, setLastName] = useState("");
  const [email, setEmail] = useState("");
  const [phone, setPhone] = useState("");
  const [carrierId, setCarrierId] = useState(carriers.length === 1 ? carriers[0].id : "");
  const [workerType, setWorkerType] = useState<DriverWorkerType>("company_driver");
  const [error, setError] = useState<string | null>(null);
  const [sent, setSent] = useState<{ url: string; emailSent: boolean; applicationId: string } | null>(null);

  function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    setError(null);
    if (carriers.length > 1 && !carrierId) {
      setError("Select which carrier this driver will work for.");
      return;
    }
    startTransition(async () => {
      const fd = new FormData();
      fd.set("first_name", firstName);
      fd.set("last_name", lastName);
      fd.set("email", email);
      fd.set("phone", phone);
      fd.set("carrier_id", carrierId);
      fd.set("worker_type", workerType);
      const result = await inviteDriverApplication(fd);
      if (!result.ok) { setError(result.error); return; }
      setSent(result);
      toast.show("success", result.emailSent ? "Invitation sent." : "Invitation created (no email delivered -- copy the link below).");
    });
  }

  if (sent) {
    return (
      <div className="space-y-4 rounded-md border border-desktop-border bg-card p-4">
        <div className="flex items-center gap-2 text-desktop-success">
          <CheckCircle2 className="size-5 shrink-0" />
          <p className="text-[14px] font-semibold text-desktop-text">Invitation created</p>
        </div>
        <p className="text-[13px] text-muted-foreground">
          {sent.emailSent ? "An email with the onboarding link was sent." : "No email delivery could be confirmed -- share this link directly."}
        </p>
        <div className="flex items-center gap-2 rounded-sm border border-desktop-border bg-desktop-bg px-3 py-2">
          <code className="min-w-0 flex-1 truncate text-[12px]">{sent.url}</code>
          <button
            type="button"
            onClick={() => { navigator.clipboard.writeText(sent.url); toast.show("success", "Link copied."); }}
            className="shrink-0 text-muted-foreground hover:text-desktop-text"
            aria-label="Copy invitation link"
          >
            <Copy className="size-4" />
          </button>
        </div>
        <div className="flex flex-wrap gap-2">
          <Button type="button" onClick={() => router.push(`/drivers/applications/${sent.applicationId}`)}>View Application</Button>
          <Button type="button" variant="outline" onClick={() => { setSent(null); setFirstName(""); setLastName(""); setEmail(""); setPhone(""); }}>
            Invite Another Driver
          </Button>
        </div>
      </div>
    );
  }

  return (
    <form onSubmit={handleSubmit} className="space-y-4 rounded-md border border-desktop-border bg-card p-4">
      {carriers.length === 0 ? (
        <p className="rounded-sm border border-warning/40 bg-warning/10 p-3 text-[12.5px] text-desktop-text">
          Add an active carrier before inviting a driver -- every driver must be assigned to one.
        </p>
      ) : carriers.length > 1 ? (
        <Field label="Carrier">
          <select value={carrierId} onChange={(e) => setCarrierId(e.target.value)} required className="h-9 w-full rounded-md border border-desktop-border bg-card px-2 text-[13px]">
            <option value="" disabled>Select a carrier...</option>
            {carriers.map((c) => (
              <option key={c.id} value={c.id}>{c.legal_name}</option>
            ))}
          </select>
        </Field>
      ) : (
        <p className="text-[12.5px] text-muted-foreground">Carrier: <span className="font-medium text-desktop-text">{carriers[0].legal_name}</span></p>
      )}

      <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
        <Field label="First name"><Input value={firstName} onChange={(e) => setFirstName(e.target.value)} required className="w-full" /></Field>
        <Field label="Last name"><Input value={lastName} onChange={(e) => setLastName(e.target.value)} required className="w-full" /></Field>
        <Field label="Email"><Input type="email" value={email} onChange={(e) => setEmail(e.target.value)} className="w-full" /></Field>
        <Field label="Phone"><Input type="tel" value={phone} onChange={(e) => setPhone(e.target.value)} className="w-full" /></Field>
      </div>
      <p className="text-[11.5px] text-muted-foreground">At least one of email or phone is required to deliver the invitation.</p>

      <Field label="Worker type">
        <select value={workerType} onChange={(e) => setWorkerType(e.target.value as DriverWorkerType)} className="h-9 w-full rounded-md border border-desktop-border bg-card px-2 text-[13px]">
          {(Object.entries(WORKER_TYPE_LABELS) as [DriverWorkerType, string][]).map(([value, label]) => (
            <option key={value} value={value}>{label}</option>
          ))}
        </select>
      </Field>
      <p className="text-[11.5px] text-muted-foreground">Determines whether the driver is asked to complete a Form W-9 during onboarding (1099 workers only).</p>

      {error && <p className="text-[12.5px] text-danger">{error}</p>}
      <div className="flex justify-end gap-2">
        <Button type="button" variant="outline" onClick={() => router.push("/drivers")}>Cancel</Button>
        <Button type="submit" disabled={pending || carriers.length === 0}>
          {pending ? <Loader2 className="size-3.5 animate-spin" /> : null} Send Invitation
        </Button>
      </div>
    </form>
  );
}
