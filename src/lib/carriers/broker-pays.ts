// Who the broker pays, per carrier (0167). Stored as the carrier's
// load_proceeds_model; each dispatch keeps the arrangement it was made under.

export type BrokerPays = "carrier_paid_directly" | "dispatcher_receives_funds";

export const BROKER_PAYS_OPTIONS: { value: BrokerPays; label: string; help: string }[] = [
  {
    value: "carrier_paid_directly",
    label: "Broker pays the carrier",
    help: "No invoice to the broker. You bill the carrier your dispatch fee (plus advances, fuel and repairs you paid) on a Dispatch Fee Invoice.",
  },
  {
    value: "dispatcher_receives_funds",
    label: "Broker pays us",
    help: "You invoice the broker for the load and pay the carrier their share on a carrier settlement.",
  },
];

/** A carrier with no setting yet follows the default: the broker pays us. */
export function brokerPaysOf(value: string | null | undefined): BrokerPays {
  return value === "carrier_paid_directly" ? "carrier_paid_directly" : "dispatcher_receives_funds";
}

export function brokerPaysLabel(value: string | null | undefined): string {
  return BROKER_PAYS_OPTIONS.find((o) => o.value === brokerPaysOf(value))!.label;
}

export type BrokerPaysResult = { loads_switched: number; broker_drafts_removed: number; kept: string[] };

/** One plain sentence (or two) about what the change did to open loads. */
export function brokerPaysResultMessage(r: BrokerPaysResult): string {
  const parts: string[] = [];
  parts.push(r.loads_switched === 0 ? "No open loads needed to change." : `${r.loads_switched} open load${r.loads_switched === 1 ? "" : "s"} moved to the new setting.`);
  if (r.broker_drafts_removed > 0) parts.push(`${r.broker_drafts_removed} unsent draft broker invoice${r.broker_drafts_removed === 1 ? " was" : "s were"} removed.`);
  if (r.kept.length > 0) parts.push(`Kept as before: ${r.kept.join("; ")}.`);
  return parts.join(" ");
}
