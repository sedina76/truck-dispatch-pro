import { DriverPortalBottomNav } from "@/components/driver-portal/bottom-nav";
import { getMyUnreadMessageCount } from "@/app/driver-portal/actions";

// Mobile-first: full width on phones, centered ~576px (spec section 29:
// "approximately 500-700px") on tablet/desktop rather than stretching
// driver cards across a wide monitor. Bottom padding clears the fixed
// bottom nav (spec section 27) so the last card is never hidden behind it.
export default async function DriverPortalLayout({ children }: { children: React.ReactNode }) {
  // Phase 2I.1A section H -- best-effort initial seed for the bottom-nav
  // badge. getMyUnreadMessageCount() itself resolves identity from the
  // session cookie and throws "Not signed in." pre-login (this layout
  // also wraps /driver-portal/login) -- caught here rather than letting
  // an unauthenticated visit to the login screen 500.
  let initialUnreadMessageCount = 0;
  try {
    initialUnreadMessageCount = await getMyUnreadMessageCount();
  } catch {
    // not signed in -- badge stays at 0, matches every other
    // not-signed-in default in this portal.
  }

  return (
    <div className="min-h-screen bg-background">
      <div className="mx-auto flex min-h-screen w-full max-w-xl flex-col px-4 pb-24 pt-6">{children}</div>
      <DriverPortalBottomNav initialUnreadMessageCount={initialUnreadMessageCount} />
    </div>
  );
}
