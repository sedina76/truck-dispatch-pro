import { Truck } from "lucide-react";

// Persistent top title strip. "Truck Dispatch Pro - Transportation
// Management System (Live)" is fixed product branding text, not a claimed
// live-data/connection state (see DesktopStatusBar for the honest
// connection indicator) -- organizationName is the one real, per-session
// value threaded through.
export function DesktopTitleBar({ organizationName }: { organizationName: string }) {
  return (
    <div className="flex h-8 shrink-0 items-center gap-2 border-b border-desktop-border bg-desktop-header px-3 text-desktop-header-text">
      <Truck className="size-3.5 shrink-0 opacity-90" />
      <span className="text-[12.5px] font-semibold tracking-tight">
        Truck Dispatch Pro <span className="font-normal opacity-80">- Transportation Management System (Live)</span>
      </span>
      <span className="ml-auto truncate text-[11.5px] opacity-90">{organizationName}</span>
    </div>
  );
}
