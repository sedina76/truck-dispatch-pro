import type { BillingAccessResult, BillingFacts } from "@/lib/billing/access-policy";

// What a company can actually do in the app right now, in the Platform
// Console's words. Built on the SAME resolveBillingAccess() the middleware
// uses, so the console can never say "Free access" for a company the app
// is really locking out (the exact gap that left companies stuck on the
// "access paused" screen with the console only saying "No subscription").

export type CompanyAccessKey = "suspended" | "locked" | "paying" | "trial" | "free" | "legacy" | "grace";

export type CompanyAccess = {
  key: CompanyAccessKey;
  /** Short badge text. */
  label: string;
  /** One line of explanation for tooltips / reports. */
  detail: string;
  /** true when the company's users can use the TMS. */
  canUseApp: boolean;
};

export type CompanyAccessFacts = {
  isActive: boolean | null;
  billingRequired: boolean | null;
  status: string | null;
  grandfatheredAt: string | null;
  pastDueSince: string | null;
  trialEnd: string | null;
  now?: Date;
};

function shortDate(iso: string): string {
  return new Date(iso).toLocaleDateString("en-US", { month: "short", day: "numeric", year: "numeric", timeZone: "UTC" });
}

/** The resolver input for a company's facts (feed it to resolveBillingAccess). */
export function toBillingFacts(f: CompanyAccessFacts): BillingFacts {
  return {
    suspended: f.isActive === false,
    billingRequired: f.billingRequired !== false, // column is NOT NULL default true
    subscriptionExists: f.status !== null,
    grandfatheredAt: f.grandfatheredAt,
    status: f.status,
    pastDueSince: f.pastDueSince,
    now: f.now ?? new Date(),
  };
}

/**
 * Pure: turns the resolver's decision into console wording. No runtime
 * imports, so it loads under `node --test`; use companyAccess() (in
 * company-access-resolve.ts) in app code.
 */
export function describeAccess(decision: BillingAccessResult, f: CompanyAccessFacts): CompanyAccess {
  if (decision.reason === "suspended") {
    return { key: "suspended", label: "Suspended", detail: "Suspended from the Platform Console. Nobody at this company can use the app.", canUseApp: false };
  }
  if (decision.access === "billing_only") {
    if (f.status === "paused") {
      return { key: "suspended", label: "Suspended", detail: "Subscription is paused, so the app is blocked for this company.", canUseApp: false };
    }
    const why = f.status === null ? "no subscription was ever started" : `subscription status is ${f.status.replace(/_/g, " ")}`;
    return {
      key: "locked",
      label: "Locked out",
      detail: `Needs a subscription but ${why}. Its users only see the "access paused" screen. Give free access or fix the subscription.`,
      canUseApp: false,
    };
  }

  switch (decision.reason) {
    case "billing_not_required":
      return { key: "free", label: "Free access", detail: "Does not need a subscription. Full access, not billed.", canUseApp: true };
    case "grandfathered":
      return { key: "legacy", label: "Legacy access", detail: "Grandfathered from before Stripe billing. Full access, not billed through Stripe.", canUseApp: true };
    case "status_trialing":
      return {
        key: "trial",
        label: f.trialEnd ? `Trial to ${shortDate(f.trialEnd)}` : "Trial",
        detail: f.trialEnd ? `On a free trial that ends ${shortDate(f.trialEnd)}.` : "On a free trial with no end date recorded.",
        canUseApp: true,
      };
    case "past_due_grace":
      return { key: "grace", label: "Past due (grace)", detail: "Payment failed. Still has access during the 7-day grace period.", canUseApp: true };
    default:
      return { key: "paying", label: "Paying", detail: "Active paid subscription.", canUseApp: true };
  }
}

/** Badge colors for the console's dark theme. */
export const ACCESS_STYLE: Record<CompanyAccessKey, string> = {
  paying: "bg-emerald-500/10 text-emerald-400",
  trial: "bg-blue-500/10 text-blue-400",
  free: "bg-cyan-500/10 text-cyan-300",
  legacy: "bg-slate-500/15 text-slate-300",
  grace: "bg-amber-500/10 text-amber-400",
  locked: "bg-red-500/15 text-red-400",
  suspended: "bg-red-500/10 text-red-300",
};
