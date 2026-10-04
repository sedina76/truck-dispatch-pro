function money(n: number): string {
  return `$${Number(n).toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
}

export type BrokerPays = "dispatcher_receives_funds" | "carrier_paid_directly" | null;

// The dispatch's money, in dispatch-service terms (one place, used by the
// dispatch panel and the dispatch page): the load rate belongs to the carrier;
// your income is the dispatch fee. Who the broker pays decides how the money
// moves -- you collect the rate and pass the carrier its share, or the carrier
// is paid directly and you bill it the fee. Values are the trigger-computed
// dispatch_financials columns (0009/0068); no second formula. The Load page's
// Profitability section adds other direct expenses on top.
export function InternalFinancialsPanel({
  loadRate,
  feePercentage,
  feeAmount,
  carrierNet,
  brokerPays = null,
  compact = false,
}: {
  loadRate: number | null;
  feePercentage: number;
  feeAmount: number | null;
  carrierNet: number | null;
  brokerPays?: BrokerPays;
  compact?: boolean;
}) {
  if (loadRate === null || Number.isNaN(loadRate)) {
    return <p className="text-[12.5px] text-desktop-text-muted">The load rate, dispatch fee and carrier&apos;s share are calculated automatically once this dispatch is created.</p>;
  }
  const fee = feeAmount ?? 0;
  const share = carrierNet ?? 0;
  const pct = Number(feePercentage);
  const pctLabel = Number.isInteger(pct) ? `${pct}%` : `${pct.toFixed(2)}%`;

  return (
    <div className={`${compact ? "" : "max-w-sm "}space-y-1 text-[13px]`} data-testid="dispatch-money">
      <Row label="Load Rate (from broker)" value={money(loadRate)} />
      <Row label="Carrier's Share" value={money(share)} />
      <div className="flex items-center justify-between border-t border-desktop-border pt-1.5 font-semibold text-desktop-text">
        <span>Your Dispatch Fee ({pctLabel})</span>
        <span className={fee < 0 ? "text-danger" : "text-desktop-success"}>{money(fee)}</span>
      </div>
      {brokerPays && (
        <p className="pt-0.5 text-[11.5px] text-desktop-text-muted">
          {brokerPays === "carrier_paid_directly"
            ? `The broker pays the carrier ${money(loadRate)}; you bill the carrier your ${money(fee)} fee.`
            : `The broker pays you ${money(loadRate)}; you pay the carrier ${money(share)} and keep ${money(fee)}.`}
        </p>
      )}
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
