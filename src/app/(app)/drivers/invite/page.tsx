import { createClient } from "@/lib/supabase/server";
import { InviteDriverForm } from "./invite-driver-form";

// Phase 2Q.2 -- the primary driver onboarding entry point (business
// decision: carrier-initiated invitation, not a staff member filling out
// the driver's entire file). Deliberately asks for only the fields needed
// to send an invitation -- everything else (personal info, license,
// medical card, documents, tax/W-9 when required, agreement) is collected
// by the driver themselves in the onboarding portal.
//
// Phase 2Q.2B: carrier selection added -- an organization can manage
// multiple carriers, and every invitation must be bound to exactly one of
// them (see inviteDriverApplication()'s own header comment for why the
// old carrier-less design was a real defect, not a style choice).
export default async function InviteDriverPage() {
  const supabase = await createClient();
  const { data: carriers } = await supabase.from("carriers").select("id, legal_name").eq("is_active", true).order("legal_name");

  return (
    <div className="mx-auto max-w-lg space-y-3">
      <div>
        <h1 className="text-[15px] font-semibold tracking-tight text-desktop-text">Invite Driver</h1>
        <p className="mt-0.5 text-xs text-muted-foreground">
          Send a secure onboarding link. The driver will complete their own personal information, license, medical card, and
          required documents.
        </p>
      </div>
      <InviteDriverForm carriers={carriers ?? []} />
    </div>
  );
}
