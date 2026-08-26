// Phase 2P.3 -- Carrier Compliance UI types. Mirrors the exact JSON shape
// returned by carrier_dispatch_readiness() (0102) verbatim -- this module
// adds no fields, invents no statuses, and recomputes nothing. The RPC is
// the sole source of truth; everything here is presentation-only (labels,
// grouping, tone mapping).

export type ComplianceOverallStatus = "READY" | "WARNING" | "NOT_READY" | "SUSPENDED";

export type ComplianceRequirementStatus = "VALID" | "EXPIRING_SOON" | "EXPIRED" | "MISSING" | "UNVERIFIED";

export type ComplianceClassification = "blocking" | "warning" | "optional" | "informational";

export type ComplianceEnforcementMode = "audit_only" | "warning" | "enforced";

export type ComplianceReasonEntry = {
  requirement_key: string | null;
  display_name: string;
  reason: string;
};

export type ComplianceRequirement = {
  requirement_key: string;
  display_name: string;
  classification: ComplianceClassification;
  status: ComplianceRequirementStatus;
  overridable: boolean;
  verification_required: boolean;
  has_active_override: boolean;
};

export type CarrierComplianceReadiness = {
  carrier_id: string;
  status: ComplianceOverallStatus;
  allowed: boolean;
  enforcement_mode: ComplianceEnforcementMode;
  blocking_reasons: ComplianceReasonEntry[];
  warnings: ComplianceReasonEntry[];
  requirements: ComplianceRequirement[];
};

// UI-only presentation mapping keyed by the 7 known system requirement_key
// values (0102 PART 7 seed). An organization-specific or future key not
// present here safely falls into "Other" -- this map never blocks a
// requirement from rendering, it only decides which section it appears
// under.
export const REQUIREMENT_GROUPS: { title: string; keys: string[] }[] = [
  { title: "Tax", keys: ["w9"] },
  { title: "Agreements", keys: ["carrier_agreement"] },
  {
    title: "Insurance",
    keys: ["cargo_insurance", "general_liability_insurance", "workers_compensation_insurance", "physical_damage_insurance"],
  },
  { title: "Authority / Identity", keys: ["operating_identifier"] },
];

export const OTHER_GROUP_TITLE = "Manual / Other";

export function groupRequirements(requirements: ComplianceRequirement[]) {
  const byKey = new Map(requirements.map((r) => [r.requirement_key, r]));
  const used = new Set<string>();
  const groups: { title: string; requirements: ComplianceRequirement[] }[] = [];

  for (const group of REQUIREMENT_GROUPS) {
    const items = group.keys.map((k) => byKey.get(k)).filter((r): r is ComplianceRequirement => Boolean(r));
    items.forEach((r) => used.add(r.requirement_key));
    if (items.length > 0) groups.push({ title: group.title, requirements: items });
  }

  const remaining = requirements.filter((r) => !used.has(r.requirement_key));
  if (remaining.length > 0) groups.push({ title: OTHER_GROUP_TITLE, requirements: remaining });

  return groups;
}

export const ENFORCEMENT_MODE_LABELS: Record<ComplianceEnforcementMode, string> = {
  audit_only: "Audit Only",
  warning: "Warning",
  enforced: "Enforced",
};

export const ENFORCEMENT_MODE_DESCRIPTIONS: Record<ComplianceEnforcementMode, string> = {
  audit_only: "Compliance is calculated but does not affect dispatch.",
  warning: "Compliance issues are surfaced but dispatch is not blocked yet.",
  enforced: "Reserved for a future dispatch-enforcement phase. Dispatch is not blocked yet.",
};
