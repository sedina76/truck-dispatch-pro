import Link from "next/link";
import { Inbox, Plus } from "lucide-react";

export function EmptyState({
  title,
  description,
  action,
}: {
  title: string;
  description: string;
  action?: { label: string; href: string };
}) {
  return (
    <div className="flex flex-col items-center justify-center gap-2 rounded-md border border-dashed border-desktop-border bg-card/50 px-6 py-10 text-center">
      <div className="flex size-9 items-center justify-center rounded-sm bg-muted text-muted-foreground">
        <Inbox className="size-4.5" />
      </div>
      <div>
        <p className="text-[13px] font-medium">{title}</p>
        <p className="mt-0.5 text-xs text-muted-foreground">{description}</p>
      </div>
      {action && (
        <Link
          href={action.href}
          className="mt-1 inline-flex h-8 items-center gap-1.5 rounded-sm bg-primary px-3 text-[13px] font-medium text-primary-foreground shadow-elevation-1 transition-colors hover:bg-primary-hover"
        >
          <Plus className="size-3.5" />
          {action.label}
        </Link>
      )}
    </div>
  );
}
