"use client";

import { useEffect, useState } from "react";

// Persistent bottom status bar. "Connected Session" rather than
// "Database: Live" -- a client component can't truthfully attest to
// database health, only that it holds an authenticated session; claiming
// more than that would be exactly the kind of unverifiable status the
// spec warns against. Every other field is the real signed-in user/org
// passed down from the server layout.
export function DesktopStatusBar({
  fullName,
  role,
  organizationName,
}: {
  fullName: string;
  role: string;
  organizationName: string;
}) {
  return (
    <div className="flex h-6 shrink-0 items-center gap-3 border-t border-desktop-border bg-desktop-panel px-3 text-[11px] text-muted-foreground">
      <StatusItem label="Ready" />
      <Divider />
      <StatusItem label="Connected Session" />
      <Divider />
      <StatusItem label={`User: ${fullName}`} />
      <Divider />
      <StatusItem label={`Role: ${role}`} className="capitalize" />
      <Divider />
      <StatusItem label={`Organization: ${organizationName}`} />
      <div className="ml-auto flex items-center gap-3">
        <LiveClock />
      </div>
    </div>
  );
}

function StatusItem({ label, className }: { label: string; className?: string }) {
  return <span className={className}>{label}</span>;
}

function Divider() {
  return <span className="text-desktop-border">|</span>;
}

// Client-ticking clock -- the one piece of this bar that's genuinely live,
// not a fixed server-render timestamp that would go stale on a long
// session.
function LiveClock() {
  const [now, setNow] = useState<Date | null>(null);

  useEffect(() => {
    setNow(new Date());
    const id = setInterval(() => setNow(new Date()), 1000 * 30);
    return () => clearInterval(id);
  }, []);

  if (!now) return null;
  return (
    <span suppressHydrationWarning>
      {now.toLocaleDateString(undefined, { month: "short", day: "numeric", year: "numeric" })}{" "}
      {now.toLocaleTimeString(undefined, { hour: "numeric", minute: "2-digit" })}
    </span>
  );
}
