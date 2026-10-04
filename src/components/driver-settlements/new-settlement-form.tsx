"use client";

import Link from "next/link";
import { useActionState } from "react";
import { Button } from "@/components/ui/button";
import { FormField, FormGrid, FormSelect } from "@/components/ui/form-field";
import { createDriverSettlement, type CreateSettlementState } from "@/app/(app)/driver-settlements/actions";

// New driver settlement. Shows the real reason when a settlement can't be
// made (no pay rate, no delivered loads in the period) instead of the
// generic error page.
export function NewSettlementForm({ drivers, defaultStart, defaultEnd }: { drivers: { value: string; label: string }[]; defaultStart: string; defaultEnd: string }) {
  const [state, action, pending] = useActionState<CreateSettlementState, FormData>(createDriverSettlement, { error: null });
  return (
    <form action={action} className="space-y-4" data-testid="new-driver-settlement">
      {state.error && (
        <p role="alert" className="rounded-sm border border-danger/40 bg-danger/5 px-3 py-2 text-[12.5px] text-danger">
          {state.error}
        </p>
      )}
      <FormGrid>
        <FormSelect label="Driver" name="driver_id" required options={drivers} />
        <FormField label="Period Start" name="period_start" type="date" defaultValue={defaultStart} required />
        <FormField label="Period End" name="period_end" type="date" defaultValue={defaultEnd} required />
      </FormGrid>
      <div className="flex items-center justify-end gap-2 border-t border-desktop-border pt-3">
        <Link href="/driver-settlements" className="inline-flex h-8 items-center rounded-sm px-3 text-[13px] font-medium text-muted-foreground transition-colors hover:bg-muted">
          Cancel
        </Link>
        <Button type="submit" disabled={pending}>
          {pending ? "Creating..." : "Create Settlement"}
        </Button>
      </div>
    </form>
  );
}
