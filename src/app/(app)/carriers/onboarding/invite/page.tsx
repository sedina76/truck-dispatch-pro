import { DesktopWorkspaceTabs } from "@/components/desktop/workspace-tabs";
import { InviteCarrierForm } from "./invite-form";

export default function InviteCarrierPage() {
  return (
    <div className="space-y-3">
      <DesktopWorkspaceTabs
        tabs={[
          { label: "Carrier Onboarding", href: "/carriers/onboarding" },
          { label: "Invite Carrier", href: "/carriers/onboarding/invite" },
        ]}
      />
      <div>
        <h1 className="text-[15px] font-semibold tracking-tight text-desktop-text">Invite Carrier</h1>
        <p className="mt-0.5 text-xs text-muted-foreground">Send a secure onboarding link so the carrier can complete their own packet.</p>
      </div>
      <InviteCarrierForm />
    </div>
  );
}
