"use client";

import { useActionState } from "react";
import { Button } from "@/components/ui/button";
import { createFuelExpense } from "@/app/(app)/fuel/actions";
import { FUEL_ACTION_INITIAL_STATE } from "@/lib/fuel/errors";

// useActionState (spec "ERROR UX"): "This fuel expense has already been
// recorded" (a double-click/race against the idempotency guarantee in
// createFuelExpense) is normal application feedback, shown inline, never
// the full-screen Runtime Error overlay.
export function CreateFuelExpenseForm({ id, amountLabel }: { id: string; amountLabel: string }) {
  const [state, formAction] = useActionState(createFuelExpense.bind(null, id), FUEL_ACTION_INITIAL_STATE);

  return (
    <form action={formAction} className="mt-3 border-t border-desktop-border pt-3">
      <p className="mb-1.5 text-[11.5px] text-muted-foreground">
        This creates exactly one company expense for this fuel purchase (category: Fuel). If Recovery is set to a
        settlement, that expense stays as the ONE real company cost -- the settlement deduction is a recovery, not a
        second expense.
      </p>
      {state.error && <p className="mb-1.5 rounded-md border border-danger/30 bg-danger/5 px-2.5 py-1.5 text-[12px] text-danger">{state.error}</p>}
      <Button type="submit" size="sm">
        Create Company Expense ({amountLabel})
      </Button>
    </form>
  );
}
