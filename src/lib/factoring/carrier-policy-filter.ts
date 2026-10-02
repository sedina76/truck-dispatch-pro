// Carrier Factoring Policy panel: summary counts + filter/search, so the
// list stays compact however many carriers an organization has.

export type PolicyFilter = "needs_setup" | "factored" | "direct" | "all";

type CarrierLike = { legal_name: string; is_active: boolean; factoring_mode: string | null };

export function policyOf(c: CarrierLike): "factored" | "direct" | "unconfigured" {
  return c.factoring_mode === "factored" || c.factoring_mode === "direct" ? c.factoring_mode : "unconfigured";
}

export function policyCounts(carriers: CarrierLike[]) {
  const active = carriers.filter((c) => c.is_active);
  return {
    factored: active.filter((c) => policyOf(c) === "factored").length,
    direct: active.filter((c) => policyOf(c) === "direct").length,
    needsSetup: active.filter((c) => policyOf(c) === "unconfigured").length,
    active: active.length,
  };
}

/** Default tab: what needs action if anything does, otherwise everything. */
export function defaultPolicyFilter(carriers: CarrierLike[]): PolicyFilter {
  return policyCounts(carriers).needsSetup > 0 ? "needs_setup" : "all";
}

export function filterCarriers<T extends CarrierLike>(carriers: T[], filter: PolicyFilter, query: string, includeInactive: boolean): T[] {
  const q = query.trim().toLowerCase();
  return carriers
    .filter((c) => includeInactive || c.is_active)
    // Historical (inactive) carriers never "need setup" -- they cannot change policy.
    .filter((c) => filter === "all" || (filter === "needs_setup" ? c.is_active && policyOf(c) === "unconfigured" : policyOf(c) === filter))
    .filter((c) => !q || c.legal_name.toLowerCase().includes(q))
    .sort((a, b) => a.legal_name.localeCompare(b.legal_name));
}
