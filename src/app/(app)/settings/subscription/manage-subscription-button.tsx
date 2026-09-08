"use client";

import { useState, useTransition } from "react";
import { Button } from "@/components/ui/button";
import { createStripeCustomerPortalSession } from "./actions";

export function ManageSubscriptionButton() {
  const [pending, startTransition] = useTransition();
  const [error, setError] = useState<string | null>(null);

  function openPortal() {
    if (pending) return;
    setError(null);

    startTransition(async () => {
      try {
        const result = await createStripeCustomerPortalSession();
        if (result.ok) {
          window.location.assign(result.url);
          return;
        }
        setError(result.message);
      } catch {
        setError("Could not open billing management. Please try again.");
      }
    });
  }

  return (
    <div className="mt-3">
      <Button type="button" size="sm" onClick={openPortal} disabled={pending}>
        {pending ? "Opening Stripe..." : "Manage subscription"}
      </Button>
      {error && <p className="mt-2 text-sm text-danger">{error}</p>}
    </div>
  );
}
