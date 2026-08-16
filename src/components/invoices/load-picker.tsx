"use client";

import { useRouter } from "next/navigation";

// "Select Load first" (spec section 3): a plain client-side nav, not local
// form state -- picking a load re-requests /invoices/new?load_id=X, which
// re-renders the page as a Server Component with that load's broker/
// customer/rate/terms already resolved server-side. No client-side
// duplication of the billing-party/due-date logic that lives in
// src/lib/billing/party.ts and the page itself.
export function LoadPicker({
  loads,
}: {
  loads: { id: string; load_number: string; rate: number }[];
}) {
  const router = useRouter();

  return (
    <div className="space-y-1">
      <label htmlFor="load_picker" className="text-[12px] font-medium text-desktop-text">
        Select Load (optional)
      </label>
      <select
        id="load_picker"
        onChange={(e) => {
          if (e.target.value) router.push(`/invoices/new?load_id=${e.target.value}`);
        }}
        defaultValue=""
        className="h-8 w-full rounded-sm border border-desktop-border bg-card px-2.5 text-[13px] shadow-elevation-1 outline-none transition-[box-shadow,border-color] focus-visible:border-primary focus-visible:ring-2 focus-visible:ring-primary/20"
      >
        <option value="">Manual entry -- no load</option>
        {loads.map((l) => (
          <option key={l.id} value={l.id}>
            {l.load_number} -- ${Number(l.rate).toLocaleString()}
          </option>
        ))}
      </select>
      <p className="text-[11px] text-muted-foreground">
        Picking a load automatically fills in its billing party, rate, and payment terms below.
      </p>
    </div>
  );
}
