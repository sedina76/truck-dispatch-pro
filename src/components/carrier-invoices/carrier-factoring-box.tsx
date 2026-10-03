"use client";

import { useMemo, useState } from "react";
import { useRouter } from "next/navigation";
import { Loader2 } from "lucide-react";
import { Card, CardContent, CardHeader, CardTitle, CardDescription } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { setUpCarrierFactoring, stopCarrierFactoring } from "@/app/(app)/carrier-invoices/factoring-setup-actions";

// Factoring, right on the carrier's invoice: shows who the broker pays and,
// for an owner/admin, sets factoring up (or stops it) without going to
// Settings -> Factoring. The form runs the same six database-checked steps.

export type FactoringCompanyOption = { id: string; name: string; email: string | null; phone: string | null; address: string | null; city: string | null; state: string | null; zip: string | null };
export type CurrentFactor = { companyName: string; remittance: string | null; method: string | null; destination: string | null; noaReference: string | null; advancePct: number | null; feePct: number | null };

const input = "h-9 w-full rounded-md border border-border bg-card px-3 text-sm";
const label = "text-[12px] font-medium text-desktop-text";

function remitText(name: string, address: string | null, city: string | null, state: string | null, zip: string | null): string {
  const cityLine = [city, [state, zip].filter(Boolean).join(" ")].filter((s) => s && String(s).trim()).join(", ");
  return [name, address, cityLine].filter((s) => s && String(s).trim()).join("\n");
}

export function CarrierFactoringBox({
  invoiceId,
  carrierId,
  carrierName,
  factors,
  current,
  canEdit,
  issuedBeforeFactoring,
  companies,
}: {
  invoiceId: string;
  carrierId: string;
  carrierName: string;
  factors: boolean;
  current: CurrentFactor | null;
  canEdit: boolean;
  /** The invoice was issued while the carrier did not factor (it still says "pay the carrier"). */
  issuedBeforeFactoring: boolean;
  companies: FactoringCompanyOption[];
}) {
  const router = useRouter();
  const [open, setOpen] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [note, setNote] = useState<string | null>(null);

  const [companyId, setCompanyId] = useState(companies[0]?.id ?? "new");
  const [newCo, setNewCo] = useState({ name: "", email: "", phone: "", address: "", city: "", state: "", zip: "" });
  const picked = companies.find((c) => c.id === companyId) ?? null;
  const coName = picked?.name ?? newCo.name;
  const suggestedRemit = useMemo(
    () => (picked ? remitText(picked.name, picked.address, picked.city, picked.state, picked.zip) : remitText(newCo.name, newCo.address, newCo.city, newCo.state, newCo.zip)),
    [picked, newCo]
  );
  const [remit, setRemit] = useState<string | null>(null); // null = follow the suggestion
  const [method, setMethod] = useState<"secure_email" | "portal_manual">("secure_email");
  const [email, setEmail] = useState<string | null>(null);
  const suggestedEmail = picked?.email ?? newCo.email;
  const today = new Date().toISOString().slice(0, 10);

  async function submit(form: HTMLFormElement) {
    setBusy(true);
    setError(null);
    try {
      const fd = new FormData(form);
      const r = await setUpCarrierFactoring(carrierId, invoiceId, fd);
      if (!r.ok) {
        setError(r.error);
        return;
      }
      setOpen(false);
      setNote(`${carrierName} now factors with ${coName}. Brokers pay ${coName}.`);
      router.refresh();
    } catch {
      setError("We couldn't reach the server. Refresh the page to see what was saved, then try again.");
    } finally {
      setBusy(false);
    }
  }

  async function stop() {
    if (!window.confirm(`Stop factoring for ${carrierName}? New invoices will tell brokers to pay ${carrierName} directly.`)) return;
    setBusy(true);
    setError(null);
    const r = await stopCarrierFactoring(carrierId, invoiceId);
    setBusy(false);
    if (!r.ok) return setError(r.error);
    setNote(`${carrierName} no longer factors.`);
    router.refresh();
  }

  return (
    <Card>
      <CardHeader className="flex-row items-center justify-between space-y-0">
        <div>
          <CardTitle>Factoring</CardTitle>
          <CardDescription>Who the broker pays for this carrier&apos;s invoices.</CardDescription>
        </div>
        <span className={`rounded-full px-3 py-1 text-xs font-semibold ${factors ? "bg-success/10 text-success" : "bg-muted text-muted-foreground"}`}>{factors ? "FACTORS" : "DOESN'T FACTOR"}</span>
      </CardHeader>
      <CardContent className="space-y-3 text-sm">
        {note && <p className="text-success">{note}</p>}
        {factors && current ? (
          <div className="space-y-1">
            <p>
              {carrierName} factors with <span className="font-medium">{current.companyName}</span>. Brokers pay {current.companyName}.
            </p>
            <dl className="grid grid-cols-[auto,1fr] gap-x-4 gap-y-1 text-[13px]">
              {current.remittance && (<><dt className="text-muted-foreground">Remit-to</dt><dd className="whitespace-pre-line">{current.remittance}</dd></>)}
              <dt className="text-muted-foreground">Paperwork</dt>
              <dd>{current.method === "secure_email" ? `Email to ${current.destination ?? "--"}` : current.method === "portal_manual" ? "Upload on their website" : (current.method ?? "--")}</dd>
              {current.advancePct != null && (<><dt className="text-muted-foreground">Terms</dt><dd>{current.advancePct}% advance, {current.feePct ?? 0}% fee</dd></>)}
              {current.noaReference && (<><dt className="text-muted-foreground">NOA</dt><dd>Approved ({current.noaReference})</dd></>)}
            </dl>
            {issuedBeforeFactoring && (
              <p className="rounded-md border border-warning/30 bg-warning/5 px-3 py-2 text-[12.5px] text-warning">
                This invoice was issued before factoring was set up, so it still tells the broker to pay {carrierName}. Use <span className="font-medium">Reissue invoice</span> in the Next step box at the top: it voids this one and issues a copy payable to {current.companyName}.
              </p>
            )}
          </div>
        ) : (
          <p>{carrierName} doesn&apos;t factor: brokers pay {carrierName} directly.</p>
        )}

        {canEdit && !open && (
          <div className="flex flex-wrap gap-2">
            {!factors && <Button type="button" size="sm" onClick={() => setOpen(true)} disabled={busy}>Set up factoring</Button>}
            {factors && <Button type="button" size="sm" variant="outline" onClick={stop} disabled={busy}>{busy ? <Loader2 className="size-3.5 animate-spin" /> : null}Stop factoring</Button>}
          </div>
        )}
        {!canEdit && !factors && <p className="text-xs text-muted-foreground">An owner or admin can set up factoring here.</p>}
        {error && !open && <p className="text-xs text-danger">{error}</p>}

        {open && (
          <form
            className="space-y-4 rounded-md border border-border p-3"
            onSubmit={(e) => {
              e.preventDefault();
              void submit(e.currentTarget);
            }}
          >
            <div className="space-y-2">
              <p className="font-medium">1. Factoring company</p>
              <select name="company_id" value={companyId} onChange={(e) => setCompanyId(e.target.value)} className={input}>
                {companies.map((c) => (
                  <option key={c.id} value={c.id}>{c.name}</option>
                ))}
                <option value="new">+ New factoring company</option>
              </select>
              {companyId === "new" && (
                <div className="grid grid-cols-1 gap-2 sm:grid-cols-2">
                  <label className="space-y-1 sm:col-span-2"><span className={label}>Name *</span><input name="company_name" required className={input} value={newCo.name} onChange={(e) => setNewCo({ ...newCo, name: e.target.value })} /></label>
                  <label className="space-y-1"><span className={label}>Email</span><input name="company_email" type="email" className={input} value={newCo.email} onChange={(e) => setNewCo({ ...newCo, email: e.target.value })} /></label>
                  <label className="space-y-1"><span className={label}>Phone</span><input name="company_phone" className={input} value={newCo.phone} onChange={(e) => setNewCo({ ...newCo, phone: e.target.value })} /></label>
                  <label className="space-y-1 sm:col-span-2"><span className={label}>Address</span><input name="company_address" className={input} value={newCo.address} onChange={(e) => setNewCo({ ...newCo, address: e.target.value })} /></label>
                  <label className="space-y-1"><span className={label}>City</span><input name="company_city" className={input} value={newCo.city} onChange={(e) => setNewCo({ ...newCo, city: e.target.value })} /></label>
                  <div className="grid grid-cols-2 gap-2">
                    <label className="space-y-1"><span className={label}>State</span><input name="company_state" className={input} value={newCo.state} onChange={(e) => setNewCo({ ...newCo, state: e.target.value })} /></label>
                    <label className="space-y-1"><span className={label}>ZIP</span><input name="company_zip" className={input} value={newCo.zip} onChange={(e) => setNewCo({ ...newCo, zip: e.target.value })} /></label>
                  </div>
                </div>
              )}
            </div>

            <div className="space-y-2">
              <p className="font-medium">2. Terms</p>
              <div className="grid grid-cols-2 gap-2 sm:grid-cols-4">
                <label className="space-y-1"><span className={label}>Advance %</span><input name="advance_pct" type="number" step="0.01" min="0" max="100" defaultValue="97" className={input} /></label>
                <label className="space-y-1"><span className={label}>Fee %</span><input name="fee_pct" type="number" step="0.01" min="0" max="100" defaultValue="3" className={input} /></label>
                <label className="space-y-1"><span className={label}>Reserve %</span><input name="reserve_pct" type="number" step="0.01" min="0" max="100" defaultValue="0" className={input} /></label>
                <label className="space-y-1"><span className={label}>Recourse</span>
                  <select name="recourse_type" defaultValue="recourse" className={input}><option value="recourse">Recourse</option><option value="non_recourse">Non-recourse</option></select>
                </label>
              </div>
            </div>

            <div className="space-y-2">
              <p className="font-medium">3. Where brokers send payment</p>
              <textarea name="remittance_instructions" rows={3} className="w-full rounded-md border border-border bg-card p-2 text-sm" value={remit ?? suggestedRemit} onChange={(e) => setRemit(e.target.value)} placeholder="The factor's remit-to address (printed on the invoice)" />
            </div>

            <div className="space-y-2">
              <p className="font-medium">4. How the factor takes paperwork</p>
              <div className="flex flex-wrap gap-4">
                <label className="flex items-center gap-1.5"><input type="radio" name="submission_method" value="secure_email" checked={method === "secure_email"} onChange={() => setMethod("secure_email")} /> Email</label>
                <label className="flex items-center gap-1.5"><input type="radio" name="submission_method" value="portal_manual" checked={method === "portal_manual"} onChange={() => setMethod("portal_manual")} /> Upload on their website</label>
              </div>
              {method === "secure_email" && (
                <input name="submission_email" type="email" required className={input} value={email ?? suggestedEmail} onChange={(e) => setEmail(e.target.value)} placeholder="Where the billing packet is emailed" />
              )}
            </div>

            <div className="space-y-2">
              <p className="font-medium">5. Notice of Assignment (NOA)</p>
              <div className="grid grid-cols-1 gap-2 sm:grid-cols-2">
                <label className="space-y-1"><span className={label}>NOA reference</span><input name="noa_reference" required className={input} key={`ref-${coName}`} defaultValue={coName ? `${coName} NOA` : ""} placeholder="e.g. Apex NOA v1" /></label>
                <label className="space-y-1"><span className={label}>Effective date</span><input name="noa_effective_date" type="date" required className={input} defaultValue={today} /></label>
              </div>
              <textarea
                name="noa_text"
                rows={3}
                required
                className="w-full rounded-md border border-border bg-card p-2 text-sm"
                defaultValue={`${carrierName} has assigned its accounts receivable to ${coName || "the factoring company"}. Remit all payments to the address above.`}
                key={coName}
              />
              <label className="flex items-start gap-2 text-[13px]">
                <input type="checkbox" name="noa_confirmed" required className="mt-0.5" />
                I have the signed Notice of Assignment for {carrierName}.
              </label>
            </div>

            {error && <p className="text-xs text-danger">{error}</p>}
            <div className="flex gap-2">
              <Button type="submit" size="sm" disabled={busy}>{busy ? <Loader2 className="size-3.5 animate-spin" /> : null}Set up factoring</Button>
              <Button type="button" size="sm" variant="outline" onClick={() => setOpen(false)} disabled={busy}>Cancel</Button>
            </div>
          </form>
        )}
      </CardContent>
    </Card>
  );
}
