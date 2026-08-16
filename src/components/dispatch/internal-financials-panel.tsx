function money(n: number): string {
  return `$${Number(n).toLocaleString(undefined, { minimumFractionDigits: 2 })}`;
}

// Reuses the existing trigger-computed columns verbatim (dispatches.
// load_rate/dispatch_fee_percentage/dispatch_fee_amount/carrier_net_amount,
// sync_dispatch_financials(), 0009) -- no second margin formula. This is
// deliberately NOT the canonical company-margin figure the Load Detail
// page's Profitability section shows (get_load_profitability, which also
// factors in other direct expenses) -- it's the simpler, real
// dispatch-level breakdown the spec's own mockup shows. A link to the
// fuller Profitability view is offered alongside it, not duplicated here.
export function InternalFinancialsPanel({
  loadRate,
  feePercentage,
  feeAmount,
  carrierNet,
}: {
  loadRate: number | null;
  feePercentage: number;
  feeAmount: number | null;
  carrierNet: number | null;
}) {
  if (loadRate === null) {
    return <p className="text-[12.5px] text-desktop-text-muted">Load revenue, dispatch fee, and carrier pay are calculated automatically once this dispatch is created.</p>;
  }

  return (
    <div className="max-w-sm space-y-1 text-[13px]">
      <Row label="Load Revenue" value={money(loadRate)} />
      <Row label={`Dispatch Fee (${Number(feePercentage).toFixed(2)}%)`} value={money(feeAmount ?? 0)} />
      <Row label="Carrier Pay" value={money(carrierNet ?? 0)} />
      <div className="flex items-center justify-between border-t border-desktop-border pt-1.5 font-semibold">
        <span>Company Gross Margin</span>
        <span>{money(feeAmount ?? 0)}</span>
      </div>
    </div>
  );
}

function Row({ label, value }: { label: string; value: string }) {
  return (
    <div className="flex items-center justify-between text-desktop-text">
      <span className="text-desktop-text-muted">{label}</span>
      <span>{value}</span>
    </div>
  );
}
