"use client";

import { useActionState } from "react";
import { createOrganization, type ActionState } from "@/lib/supabase/actions";
import { Input } from "@/components/ui/input";
import { Button } from "@/components/ui/button";

const initialState: ActionState = { error: null };

export function OnboardingForm() {
  const [state, formAction, pending] = useActionState(createOrganization, initialState);

  return (
    <form action={formAction} className="space-y-4">
      <div className="space-y-1">
        <label htmlFor="name" className="text-sm font-medium">
          Company name
        </label>
        <Input id="name" name="name" type="text" placeholder="Northbound Logistics" required />
      </div>

      {state.error && <p className="text-sm text-red-600">{state.error}</p>}

      <Button type="submit" disabled={pending} className="w-full">
        {pending ? "Creating…" : "Create organization"}
      </Button>
    </form>
  );
}
