"use client";

import Link from "next/link";
import { Search, Plus } from "lucide-react";
import { Button } from "@/components/ui/button";
import { ThemeToggle } from "@/components/nav/theme-toggle";
import { NotificationsMenu } from "@/components/nav/notifications-menu";
import { openCommandPalette, useCommandPaletteHint } from "@/components/nav/command-palette";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";

const QUICK_CREATE = [
  { label: "New Load", href: "/loads/new" },
  { label: "New Dispatch", href: "/dispatch/new" },
  { label: "New Carrier", href: "/carriers/new" },
  { label: "New Driver", href: "/drivers/new" },
  { label: "New Invoice", href: "/invoices/new" },
  { label: "Record Payment", href: "/payments/new" },
  { label: "Add Advance", href: "/advances/new" },
];

type NotificationRow = {
  id: string;
  title: string;
  body: string | null;
  type: string;
  entity_type: string | null;
  entity_id: string | null;
  read_at: string | null;
  created_at: string;
};

export function Topbar({ notifications }: { notifications: NotificationRow[] }) {
  const shortcutHint = useCommandPaletteHint();

  return (
    <header className="flex h-16 shrink-0 items-center gap-4 border-b border-border bg-card/70 px-6 backdrop-blur-md">
      <button
        onClick={openCommandPalette}
        className="flex h-10 w-full max-w-sm items-center gap-2.5 rounded-lg border border-border bg-muted/60 px-3.5 text-sm text-muted-foreground transition-colors hover:border-primary/40 hover:bg-muted"
      >
        <Search className="size-4 shrink-0" />
        <span className="flex-1 text-left">Search or jump to...</span>
        <kbd className="rounded border border-border bg-card px-1.5 py-0.5 text-[10px] font-medium">{shortcutHint}</kbd>
      </button>

      <div className="ml-auto flex items-center gap-1.5">
        <DropdownMenu>
          <DropdownMenuTrigger asChild>
            <Button type="button" variant="primary" size="sm" className="gap-1">
              <Plus className="size-4" />
              Create
            </Button>
          </DropdownMenuTrigger>
          <DropdownMenuContent align="end" className="w-48">
            {QUICK_CREATE.map((item) => (
              <DropdownMenuItem key={item.href} asChild>
                <Link href={item.href}>{item.label}</Link>
              </DropdownMenuItem>
            ))}
          </DropdownMenuContent>
        </DropdownMenu>

        <NotificationsMenu notifications={notifications} />
        <ThemeToggle />
      </div>
    </header>
  );
}
