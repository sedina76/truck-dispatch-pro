import { cn } from "@/lib/utils";

// The right-side context/detail panel. Only rendered by pages where a
// master/detail interaction genuinely exists (e.g. Collections) -- most
// pages simply don't pass one, and DesktopWorkspace collapses the column
// entirely rather than showing an empty pane.
export function DesktopInspector({ className, children }: { className?: string; children: React.ReactNode }) {
  return (
    <aside className={cn("flex h-full w-80 shrink-0 flex-col overflow-y-auto border-l border-desktop-border bg-desktop-panel", className)}>
      {children}
    </aside>
  );
}

export function DesktopInspectorSection({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <div className="border-b border-desktop-border">
      <div className="flex h-6 items-center bg-desktop-muted px-2.5 text-[10.5px] font-semibold uppercase tracking-wide text-muted-foreground">
        {title}
      </div>
      <div className="space-y-1.5 p-2.5 text-[12.5px]">{children}</div>
    </div>
  );
}

export function DesktopInspectorRow({ label, value }: { label: string; value: React.ReactNode }) {
  return (
    <div className="flex items-center justify-between gap-2">
      <span className="text-muted-foreground">{label}</span>
      <span className="truncate font-medium text-desktop-text">{value}</span>
    </div>
  );
}

export function DesktopInspectorEmpty({ message }: { message: string }) {
  return <p className="p-4 text-center text-[12.5px] text-muted-foreground">{message}</p>;
}
