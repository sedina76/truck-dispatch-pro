import Link from "next/link";
import { UserCheck } from "lucide-react";

// Bookend page, outside the numbered step sequence (mirrors carrier
// onboarding's own welcome/page.tsx). getMyDriverApplication() isn't
// needed here -- the layout already resolved/validated the session and
// shows the inviting organization's name in its own header.
export default function DriverOnboardingWelcomePage() {
  return (
    <div className="space-y-4 rounded-md border border-desktop-border bg-card p-5 text-center sm:p-8">
      <UserCheck className="mx-auto size-8 text-primary" />
      <div>
        <h2 className="text-[17px] font-semibold text-desktop-text">You&apos;ve been invited to complete your driver onboarding</h2>
        <p className="mx-auto mt-2 max-w-md text-[13.5px] text-muted-foreground">
          This should only take a few minutes. You&apos;ll enter your personal information, license and medical card details, and
          upload or scan a few required documents. You can save your progress and come back to this same link at any time.
        </p>
      </div>
      <Link
        href="/driver-onboarding/personal"
        className="inline-flex h-11 items-center rounded-sm bg-primary px-5 text-[14px] font-medium text-primary-foreground shadow-elevation-1 transition-colors hover:bg-primary-hover"
      >
        Begin
      </Link>
    </div>
  );
}
