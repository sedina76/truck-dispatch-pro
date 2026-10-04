// When the billing packet goes to the factoring company by itself (pure, tested).
// The packet's own readiness (issued + every POD verified) is checked again by
// the same rule the Email button uses, right before sending.

export function shouldAutoSendToFactor(p: { issuanceStatus: string; who: "carrier" | "factor" | "broker" | "factor_portal"; to: string; alreadySent: boolean }): { send: boolean; reason: string } {
  if (p.issuanceStatus !== "issued") return { send: false, reason: "not issued" };
  if (p.who === "carrier") return { send: false, reason: "the carrier sends its own paperwork" };
  if (p.who === "broker") return { send: false, reason: "carrier doesn't factor (goes to the broker)" };
  if (p.who === "factor_portal") return { send: false, reason: "factor takes uploads on its website" };
  if (!p.to.trim()) return { send: false, reason: "no factor email" };
  if (p.alreadySent) return { send: false, reason: "already sent" };
  return { send: true, reason: "ok" };
}
