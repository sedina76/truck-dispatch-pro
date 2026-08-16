import { DriverPortalBottomNav } from "@/components/driver-portal/bottom-nav";

// Mobile-first: full width on phones, centered ~576px (spec section 29:
// "approximately 500-700px") on tablet/desktop rather than stretching
// driver cards across a wide monitor. Bottom padding clears the fixed
// bottom nav (spec section 27) so the last card is never hidden behind it.
export default function DriverPortalLayout({ children }: { children: React.ReactNode }) {
  return (
    <div className="min-h-screen bg-background">
      <div className="mx-auto flex min-h-screen w-full max-w-xl flex-col px-4 pb-24 pt-6">{children}</div>
      <DriverPortalBottomNav />
    </div>
  );
}
