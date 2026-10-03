"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { Loader2, CheckCircle2, XCircle, Star, Copy, Check, RotateCcw } from "lucide-react";
import { Button } from "@/components/ui/button";
import {
  addEmailDomain,
  checkEmailDomainVerification,
  removeEmailDomain,
  setDefaultEmailDomain,
  addEmailSender,
  updateEmailSender,
  setDefaultEmailSender,
  type EmailActionResult,
} from "./actions";
import type { DomainRow, SenderRow } from "./page";
import { dnsRecordStatusLabel } from "@/lib/email/domain-setup";

const STATUS_LABEL: Record<string, string> = {
  not_started: "Not Started",
  pending: "Pending DNS",
  verified: "Verified",
  failed: "Failed",
  partially_verified: "Partially Verified",
  partially_failed: "Partially Failed",
  disabled: "Disabled",
};
const STATUS_TONE: Record<string, string> = {
  not_started: "text-muted-foreground",
  pending: "text-warning",
  verified: "text-success",
  failed: "text-danger",
  partially_verified: "text-warning",
  partially_failed: "text-danger",
  disabled: "text-muted-foreground",
};

// Small shared helper: run a typed-result action, surface its error
// inline, refresh on success. Same pattern as UploadDocumentForm (spec:
// "Do not turn expected business errors into route-boundary exceptions").
function useAction() {
  const router = useRouter();
  const [pendingKey, setPendingKey] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  async function run(key: string, fn: () => Promise<EmailActionResult>) {
    setPendingKey(key);
    setError(null);
    const result = await fn();
    setPendingKey(null);
    if (!result.ok) {
      setError(result.error);
      return false;
    }
    router.refresh();
    return true;
  }

  return { run, pendingKey, error, setError };
}

export function AddDomainForm() {
  const { run, pendingKey, error } = useAction();
  const [domain, setDomain] = useState("");
  const [sendingDomainOverride, setSendingDomainOverride] = useState("");

  return (
    <form
      onSubmit={async (e) => {
        e.preventDefault();
        const fd = new FormData();
        fd.set("domain", domain);
        fd.set("sending_domain", sendingDomainOverride);
        const ok = await run("add-domain", () => addEmailDomain(fd));
        if (ok) {
          setDomain("");
          setSendingDomainOverride("");
        }
      }}
      className="rounded-md border border-[var(--color-border)] bg-card p-4"
    >
      <p className="text-sm font-semibold">Add Business Sending Domain</p>
      <p className="mt-1 text-xs text-muted-foreground">
        We recommend a dedicated sending subdomain (e.g. mail.yourcompany.com) so your normal company email/website setup is never disrupted.
      </p>
      <div className="mt-3 flex flex-wrap items-end gap-2">
        <label className="flex flex-col gap-1 text-xs font-medium text-muted-foreground">
          Business Domain
          <input
            value={domain}
            onChange={(e) => setDomain(e.target.value)}
            placeholder="yourcompany.com"
            required
            className="h-8 w-56 rounded-md border border-border bg-card px-2 text-sm shadow-elevation-1 outline-none focus-visible:border-primary focus-visible:ring-2 focus-visible:ring-primary/20"
          />
        </label>
        <label className="flex flex-col gap-1 text-xs font-medium text-muted-foreground">
          Sending Subdomain (optional -- defaults to mail.&lt;domain&gt;)
          <input
            value={sendingDomainOverride}
            onChange={(e) => setSendingDomainOverride(e.target.value)}
            placeholder="mail.yourcompany.com"
            className="h-8 w-64 rounded-md border border-border bg-card px-2 text-sm shadow-elevation-1 outline-none focus-visible:border-primary focus-visible:ring-2 focus-visible:ring-primary/20"
          />
        </label>
        <Button type="submit" size="sm" disabled={pendingKey === "add-domain"}>
          {pendingKey === "add-domain" ? <Loader2 className="size-3.5 animate-spin" /> : null}
          Add Domain
        </Button>
      </div>
      {error && <p className="mt-2 text-xs text-danger">{error}</p>}
    </form>
  );
}

export function EmailDomainsSection({ domains, isAdmin }: { domains: DomainRow[]; isAdmin: boolean }) {
  // A REMOVED domain (disabled_at set) keeps its row for send history, but
  // its provider registration is gone -- its old DNS records are useless,
  // so it is listed separately, compactly, with "Set up again".
  const active = domains.filter((d) => !d.disabled_at);
  const removed = domains.filter((d) => d.disabled_at);
  if (domains.length === 0 || (active.length === 0 && removed.length === 0)) {
    return <p className="rounded-md border border-dashed border-[var(--color-border)] p-4 text-sm text-muted-foreground">No sending domain configured yet. Business email will use the Truck Dispatch Pro platform address, branded with your company name.</p>;
  }
  return (
    <div className="space-y-3">
      {active.length === 0 && (
        <p className="rounded-md border border-dashed border-[var(--color-border)] p-4 text-sm text-muted-foreground">No active sending domain. Business email uses the Truck Dispatch Pro platform address, branded with your company name.</p>
      )}
      {active.map((d) => (
        <DomainCard key={d.id} domain={d} isAdmin={isAdmin} />
      ))}
      {removed.length > 0 && <RemovedDomains domains={removed} isAdmin={isAdmin} />}
    </div>
  );
}

function RemovedDomains({ domains, isAdmin }: { domains: DomainRow[]; isAdmin: boolean }) {
  const { run, pendingKey, error } = useAction();
  return (
    <div className="rounded-md border border-[var(--color-border)] bg-card p-3">
      <p className="text-xs font-semibold text-muted-foreground">Removed domains</p>
      <ul className="mt-1 divide-y divide-[var(--color-border)]">
        {domains.map((d) => (
          <li key={d.id} className="flex flex-wrap items-center justify-between gap-2 py-1.5 text-sm">
            <span>
              <span className="font-medium">{d.domain}</span>
              <span className="text-xs text-muted-foreground">
                {" "}· {d.sending_domain} · removed {d.disabled_at ? new Date(d.disabled_at).toLocaleDateString() : ""} -- not used for sending
              </span>
            </span>
            {isAdmin && (
              <Button
                type="button"
                size="sm"
                variant="outline"
                disabled={pendingKey === d.id}
                onClick={() => {
                  const fd = new FormData();
                  fd.set("domain", d.domain);
                  fd.set("sending_domain", d.sending_domain);
                  run(d.id, () => addEmailDomain(fd));
                }}
              >
                {pendingKey === d.id ? <Loader2 className="size-3.5 animate-spin" /> : <RotateCcw className="size-3.5" />}
                Set up again
              </Button>
            )}
          </li>
        ))}
      </ul>
      {error && <p className="mt-1 text-xs text-danger">{error}</p>}
    </div>
  );
}

function CopyButton({ value, label }: { value: string; label: string }) {
  const [copied, setCopied] = useState(false);
  return (
    <button
      type="button"
      aria-label={`Copy ${label}`}
      title={`Copy ${label}`}
      onClick={() => {
        navigator.clipboard?.writeText(value).then(() => {
          setCopied(true);
          setTimeout(() => setCopied(false), 1500);
        });
      }}
      className="ml-1 inline-flex size-5 shrink-0 items-center justify-center rounded-sm text-muted-foreground hover:bg-desktop-muted hover:text-foreground"
    >
      {copied ? <Check className="size-3 text-success" /> : <Copy className="size-3" />}
    </button>
  );
}

function DomainCard({ domain, isAdmin }: { domain: DomainRow; isAdmin: boolean }) {
  const { run, pendingKey, error } = useAction();
  const disabled = domain.status === "disabled";

  return (
    <div className="rounded-md border border-[var(--color-border)] bg-card p-4">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <div>
          <p className="text-sm font-semibold">
            {domain.domain} {domain.is_default && <span className="ml-1 inline-flex items-center gap-0.5 text-xs font-normal text-primary"><Star className="size-3 fill-current" /> Default</span>}
          </p>
          <p className="text-xs text-muted-foreground">Sending domain: {domain.sending_domain}</p>
        </div>
        <div className="text-right">
          <span className={`block text-xs font-semibold ${STATUS_TONE[domain.status] ?? ""}`}>{STATUS_LABEL[domain.status] ?? domain.status}</span>
          {/* Spec review item 2 -- shown separately from `status` since
              they can genuinely diverge (e.g. partially_verified overall
              but sending already enabled). This is the field
              resolveEmailSender() actually gates on. */}
          <span className={`block text-[11px] ${domain.sending_enabled ? "text-success" : "text-muted-foreground"}`}>
            {domain.sending_enabled ? "Sending Enabled" : "Sending Not Yet Enabled"}
          </span>
        </div>
      </div>

      {domain.dns_records.length > 0 && !domain.sending_enabled && (
        <p className="mt-3 rounded-sm bg-desktop-muted/60 px-2.5 py-2 text-xs text-muted-foreground">
          Add these {domain.dns_records.length} records in the DNS settings where <span className="font-medium text-foreground">{domain.domain}</span> is
          managed (for example GoDaddy, Namecheap or Cloudflare). Enter each Name/Host exactly as shown -- most providers add
          <span className="font-mono"> .{domain.domain}</span> automatically. Then click <span className="font-medium text-foreground">Check Verification</span>;
          DNS changes can take a few minutes to a few hours.
        </p>
      )}
      {domain.dns_records.length > 0 && (
        <div className="mt-3 overflow-x-auto">
          <table className="w-full table-fixed text-xs">
            <colgroup>
              <col className="w-14" />
              <col className="w-[26%]" />
              <col />
              <col className="w-32" />
            </colgroup>
            <thead>
              <tr className="text-left text-muted-foreground">
                <th className="pb-1 pr-3 font-medium">Type</th>
                <th className="pb-1 pr-3 font-medium">Name / Host</th>
                <th className="pb-1 pr-3 font-medium">Value</th>
                <th className="pb-1 font-medium">Status</th>
              </tr>
            </thead>
            <tbody>
              {domain.dns_records.map((r, i) => (
                <tr key={i} className="border-t border-[var(--color-border)] align-top">
                  <td className="py-1.5 pr-3 font-mono">
                    {r.type}
                    {r.priority != null && <span className="block text-[10px] text-muted-foreground">priority {r.priority}</span>}
                  </td>
                  <td className="py-1.5 pr-3">
                    <span className="flex items-start">
                      <span className="break-all font-mono">{r.name}</span>
                      <CopyButton value={r.name} label="name" />
                    </span>
                  </td>
                  <td className="py-1.5 pr-3">
                    <span className="flex items-start">
                      <span className="break-all font-mono">{r.value}</span>
                      <CopyButton value={r.value} label="value" />
                    </span>
                  </td>
                  <td className="py-1.5">
                    {r.status === "verified" ? (
                      <span className="inline-flex items-center gap-0.5 text-success"><CheckCircle2 className="size-3" /> Verified</span>
                    ) : (
                      <span className="inline-flex items-center gap-0.5 text-muted-foreground"><XCircle className="size-3" /> {dnsRecordStatusLabel(r.status)}</span>
                    )}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}

      {isAdmin && !disabled && (
        <div className="mt-3 flex flex-wrap gap-2 border-t border-[var(--color-border)] pt-3">
          <Button type="button" size="sm" variant="outline" disabled={pendingKey === "verify"} onClick={() => run("verify", () => checkEmailDomainVerification(domain.id))}>
            {pendingKey === "verify" ? <Loader2 className="size-3.5 animate-spin" /> : null}
            Check Verification
          </Button>
          {domain.sending_enabled && !domain.is_default && (
            <Button type="button" size="sm" variant="outline" disabled={pendingKey === "default"} onClick={() => run("default", () => setDefaultEmailDomain(domain.id))}>
              Set Default
            </Button>
          )}
          <Button type="button" size="sm" variant="danger" disabled={pendingKey === "remove"} onClick={() => { if (confirm(`Remove ${domain.domain}? Future email will use the platform sender instead.`)) run("remove", () => removeEmailDomain(domain.id)); }}>
            Remove Domain
          </Button>
        </div>
      )}
      {error && <p className="mt-2 text-xs text-danger">{error}</p>}
    </div>
  );
}

export function EmailSendersSection({ senders, verifiedDomains, isAdmin }: { senders: SenderRow[]; verifiedDomains: DomainRow[]; isAdmin: boolean }) {
  return (
    <div className="space-y-3">
      <SectionSubheading title="Sender Identities" description="Named From addresses under your verified domain (e.g. billing@mail.yourcompany.com)." />
      {isAdmin && verifiedDomains.length > 0 && <AddSenderForm domains={verifiedDomains} />}
      {senders.length === 0 ? (
        <p className="rounded-md border border-dashed border-[var(--color-border)] p-4 text-sm text-muted-foreground">
          {verifiedDomains.length === 0 ? "Verify a sending domain above to add a sender identity." : "No sender identities yet."}
        </p>
      ) : (
        senders.map((s) => <SenderCard key={s.id} sender={s} isAdmin={isAdmin} />)
      )}
    </div>
  );
}

function SectionSubheading({ title, description }: { title: string; description: string }) {
  return (
    <div>
      <p className="text-sm font-semibold">{title}</p>
      <p className="text-xs text-muted-foreground">{description}</p>
    </div>
  );
}

function AddSenderForm({ domains }: { domains: DomainRow[] }) {
  const { run, pendingKey, error } = useAction();
  const [domainId, setDomainId] = useState(domains[0]?.id ?? "");
  const [localPart, setLocalPart] = useState("");
  const [displayName, setDisplayName] = useState("");
  const [replyTo, setReplyTo] = useState("");
  const [senderType, setSenderType] = useState("general");

  return (
    <form
      onSubmit={async (e) => {
        e.preventDefault();
        const fd = new FormData();
        fd.set("email_domain_id", domainId);
        fd.set("local_part", localPart);
        fd.set("display_name", displayName);
        fd.set("reply_to", replyTo);
        fd.set("sender_type", senderType);
        const ok = await run("add-sender", () => addEmailSender(fd));
        if (ok) {
          setLocalPart("");
          setDisplayName("");
          setReplyTo("");
        }
      }}
      className="rounded-md border border-[var(--color-border)] bg-card p-4"
    >
      <div className="flex flex-wrap items-end gap-2">
        <label className="flex flex-col gap-1 text-xs font-medium text-muted-foreground">
          Display Name
          <input value={displayName} onChange={(e) => setDisplayName(e.target.value)} placeholder="Kali Freights Billing" required className="h-8 w-48 rounded-md border border-border bg-card px-2 text-sm shadow-elevation-1 outline-none focus-visible:border-primary focus-visible:ring-2 focus-visible:ring-primary/20" />
        </label>
        <label className="flex flex-col gap-1 text-xs font-medium text-muted-foreground">
          Mailbox
          <div className="flex items-center gap-1">
            <input value={localPart} onChange={(e) => setLocalPart(e.target.value)} placeholder="billing" required className="h-8 w-28 rounded-md border border-border bg-card px-2 text-sm shadow-elevation-1 outline-none focus-visible:border-primary focus-visible:ring-2 focus-visible:ring-primary/20" />
            <select value={domainId} onChange={(e) => setDomainId(e.target.value)} className="h-8 rounded-md border border-border bg-card px-2 text-sm shadow-elevation-1">
              {domains.map((d) => (
                <option key={d.id} value={d.id}>
                  @{d.sending_domain}
                </option>
              ))}
            </select>
          </div>
        </label>
        <label className="flex flex-col gap-1 text-xs font-medium text-muted-foreground">
          Type
          <select value={senderType} onChange={(e) => setSenderType(e.target.value)} className="h-8 rounded-md border border-border bg-card px-2 text-sm shadow-elevation-1">
            <option value="general">General</option>
            <option value="billing">Billing</option>
            <option value="dispatch">Dispatch</option>
            <option value="accounting">Accounting</option>
          </select>
        </label>
        <label className="flex flex-col gap-1 text-xs font-medium text-muted-foreground">
          Reply-To (optional)
          <input value={replyTo} onChange={(e) => setReplyTo(e.target.value)} placeholder="accounting@yourcompany.com" type="email" className="h-8 w-56 rounded-md border border-border bg-card px-2 text-sm shadow-elevation-1 outline-none focus-visible:border-primary focus-visible:ring-2 focus-visible:ring-primary/20" />
        </label>
        <Button type="submit" size="sm" disabled={pendingKey === "add-sender"}>
          {pendingKey === "add-sender" ? <Loader2 className="size-3.5 animate-spin" /> : null}
          Add Sender
        </Button>
      </div>
      {error && <p className="mt-2 text-xs text-danger">{error}</p>}
    </form>
  );
}

function SenderCard({ sender, isAdmin }: { sender: SenderRow; isAdmin: boolean }) {
  const { run, pendingKey, error } = useAction();

  return (
    <div className="flex flex-wrap items-center justify-between gap-2 rounded-md border border-[var(--color-border)] bg-card p-3">
      <div>
        <p className="text-sm font-medium">
          {sender.display_name} {sender.is_default && <Star className="ml-1 inline size-3 fill-current text-primary" />} {!sender.is_active && <span className="ml-1 text-xs text-muted-foreground">(inactive)</span>}
        </p>
        <p className="text-xs text-muted-foreground">
          {sender.email_address} &middot; {sender.sender_type}
          {sender.reply_to && ` · Reply-To: ${sender.reply_to}`}
        </p>
      </div>
      {isAdmin && sender.is_active && (
        <div className="flex gap-2">
          {!sender.is_default && (
            <Button type="button" size="sm" variant="outline" disabled={pendingKey === "default-sender"} onClick={() => run("default-sender", () => setDefaultEmailSender(sender.id))}>
              Set Default
            </Button>
          )}
          <Button
            type="button"
            size="sm"
            variant="outline"
            disabled={pendingKey === "deactivate"}
            onClick={() => {
              const fd = new FormData();
              fd.set("display_name", sender.display_name);
              fd.set("reply_to", sender.reply_to ?? "");
              fd.set("sender_type", sender.sender_type);
              fd.set("is_active", "0");
              run("deactivate", () => updateEmailSender(sender.id, fd));
            }}
          >
            Deactivate
          </Button>
        </div>
      )}
      {error && <p className="w-full text-xs text-danger">{error}</p>}
    </div>
  );
}
