"use client";

import { useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { Button } from "@/components/ui/button";
import { startSubscriptionCheckout } from "./actions";
import {
  annualMonthlyEquivalent,
  formatUsd,
  refusalMessage,
  type BillingCycle,
  type PlanCardModel,
} from "./billing-view";

// PHASE D.2.8 -- the ONLY browser entry to self-service Stripe Checkout.
// It calls the REAL server action startSubscriptionCheckout({ tier,
// billing_cycle }); there is no alternate Stripe code here. Client state is
// purely UX (a Monthly/Annual toggle + a pending lock). The server action +
// src/lib/stripe/checkout.ts CAS/idempotency remain authoritative: a
// double-submit that slips past the disabled button still cannot mint a
// second Checkout Session.

// The CTA renders only when the org has no live subscription yet (the page's
// evaluateCheckoutGate allows checkout solely from incomplete /
// incomplete_expired / canceled / no-row), so every button is a first
// "Start 30-Day Free Trial" -- there is no "current plan" to contrast
// against. D.2.9: the trial is 30 days and needs no card to start; the
// trial length lives server-side in src/lib/stripe/checkout.ts.
export function CheckoutCta({ plans }: { plans: PlanCardModel[] }) {
  const router = useRouter();
  const [cycle, setCycle] = useState<BillingCycle>("monthly");
  const [pendingTier, setPendingTier] = useState<string | null>(null);
  const [pending, startTransition] = useTransition();
  const [error, setError] = useState<string | null>(null);

  function startCheckout(tier: PlanCardModel["tier"]) {
    if (pending) return; // guard the transition window itself
    setError(null);
    setPendingTier(tier);
    startTransition(async () => {
      try {
        const result = await startSubscriptionCheckout({ tier, billing_cycle: cycle });
        if (result.ok && result.kind === "redirect") {
          // External Stripe-hosted URL -- full navigation, not router.push.
          window.location.assign(result.url);
          return; // keep the button locked while the browser leaves
        }
        if (result.ok && result.kind === "already_completed") {
          router.refresh();
          return;
        }
        setError(
          refusalMessage(
            result.ok ? undefined : result.code,
            result.ok ? undefined : result.message
          )
        );
      } catch {
        setError(refusalMessage("internal_error"));
      } finally {
        setPendingTier(null);
      }
    });
  }

  return (
    <div className="space-y-4">
      <div className="flex items-center justify-between">
        <p className="text-sm font-medium">Choose a plan</p>
        <div
          role="group"
          aria-label="Billing cycle"
          className="inline-flex rounded-md border border-[var(--color-border)] p-0.5 text-xs"
        >
          {(["monthly", "annual"] as const).map((c) => (
            <button
              key={c}
              type="button"
              onClick={() => setCycle(c)}
              disabled={pending}
              aria-pressed={cycle === c}
              className={
                "rounded px-3 py-1 font-medium capitalize transition-colors disabled:opacity-50 " +
                (cycle === c
                  ? "bg-[var(--color-brand)] text-white"
                  : "text-[var(--color-text-muted)] hover:text-[var(--color-text)]")
              }
            >
              {c === "annual" ? "Annual" : "Monthly"}
            </button>
          ))}
        </div>
      </div>

      {error && (
        <div
          role="alert"
          className="rounded-lg border border-danger/30 bg-danger/10 p-3 text-sm text-danger"
        >
          {error}
        </div>
      )}

      <p className="text-sm text-[var(--color-text-muted)]">
        Start your 30-day free trial. No credit card required.
      </p>

      <div className="grid grid-cols-1 gap-4 md:grid-cols-2">
        {plans.map((plan) => {
          const priceCents = cycle === "annual" ? plan.annualCents : plan.monthlyCents;
          const thisPending = pending && pendingTier === plan.tier;
          return (
            <div
              key={plan.tier}
              className="flex flex-col rounded-lg border border-[var(--color-border)] p-4"
            >
              <p className="font-medium">{plan.name}</p>
              <p className="mt-1 text-2xl font-semibold">
                {formatUsd(priceCents)}
                <span className="text-sm font-normal text-[var(--color-text-muted)]">
                  {cycle === "annual" ? "/yr" : "/mo"}
                </span>
              </p>
              {cycle === "annual" && plan.annualCents > 0 && (
                <p className="mt-0.5 text-xs text-[var(--color-text-muted)]">
                  {annualMonthlyEquivalent(plan.annualCents)}/mo, billed yearly
                </p>
              )}
              {plan.description && (
                <p className="mt-2 text-sm text-[var(--color-text-muted)]">{plan.description}</p>
              )}
              {plan.features.length > 0 && (
                <ul className="mt-3 space-y-1 text-sm">
                  {plan.features.map((f) => (
                    <li key={f}>&bull; {f}</li>
                  ))}
                </ul>
              )}
              <div className="mt-4 pt-2">
                <Button
                  type="button"
                  size="sm"
                  className="w-full"
                  disabled={pending}
                  aria-busy={thisPending}
                  onClick={() => startCheckout(plan.tier)}
                >
                  {thisPending ? "Opening secure checkout…" : "Start 30-Day Free Trial"}
                </Button>
              </div>
            </div>
          );
        })}
      </div>

      <p className="text-xs text-[var(--color-text-muted)]">
        No credit card is required to start. You&apos;ll finish on Stripe&apos;s secure checkout page,
        and your trial is confirmed here once Stripe notifies us &mdash; the redirect back to this
        page does not activate it on its own. Add a payment method before day 30 to keep access after
        the trial.
      </p>
    </div>
  );
}
