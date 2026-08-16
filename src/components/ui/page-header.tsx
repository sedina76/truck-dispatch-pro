import Link from "next/link";
import { Plus } from "lucide-react";

export function PageHeader({
  title,
  description,
  primaryAction,
}: {
  title: string;
  description: string;
  primaryAction?: { label: string; href: string };
}) {
  return (
    <div className="flex flex-wrap items-start justify-between gap-3">
      <div>
        <h1 className="text-[15px] font-semibold tracking-tight text-desktop-text">{title}</h1>
        <p className="mt-0.5 text-xs text-muted-foreground">{description}</p>
      </div>
      {primaryAction && (
        <Link
          href={primaryAction.href}
          className="inline-flex h-8 shrink-0 items-center gap-1.5 rounded-sm bg-primary px-3 text-[13px] font-medium text-primary-foreground shadow-elevation-1 transition-colors hover:bg-primary-hover"
        >
          <Plus className="size-3.5" />
          {primaryAction.label}
        </Link>
      )}
    </div>
  );
}
