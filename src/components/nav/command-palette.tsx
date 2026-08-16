"use client";

import { useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import {
  LayoutDashboard,
  Truck,
  Users,
  Building2,
  UserRound,
  Container,
  Package,
  KanbanSquare,
  FileText,
  ShieldCheck,
  Receipt,
  Wallet,
  HandCoins,
  BarChart3,
  Settings,
  Plus,
  Wrench,
  Fuel,
  BadgeDollarSign,
  Radio,
  ReceiptText,
} from "lucide-react";
import {
  CommandDialog,
  CommandInput,
  CommandList,
  CommandEmpty,
  CommandGroup,
  CommandItem,
  CommandSeparator,
  CommandShortcut,
} from "@/components/ui/command";

const NAV_ITEMS = [
  { label: "Dashboard", href: "/dashboard", icon: LayoutDashboard },
  { label: "Dispatch Board", href: "/dispatch/board", icon: KanbanSquare },
  { label: "Live Tracking", href: "/tracking", icon: Radio },
  { label: "Loads", href: "/loads", icon: Package },
  { label: "Carriers", href: "/carriers", icon: Truck },
  { label: "Brokers", href: "/brokers", icon: Building2 },
  { label: "Customers", href: "/customers", icon: Users },
  { label: "Drivers", href: "/drivers", icon: UserRound },
  { label: "Trucks", href: "/trucks", icon: Truck },
  { label: "Trailers", href: "/trailers", icon: Container },
  { label: "Maintenance", href: "/maintenance", icon: Wrench },
  { label: "Fuel Logs", href: "/fuel", icon: Fuel },
  { label: "Documents", href: "/documents", icon: FileText },
  { label: "Compliance", href: "/compliance", icon: ShieldCheck },
  { label: "Invoices", href: "/invoices", icon: Receipt },
  { label: "Payments", href: "/payments", icon: Wallet },
  { label: "Carrier Settlements", href: "/settlements", icon: HandCoins },
  { label: "Advances", href: "/advances", icon: BadgeDollarSign },
  { label: "Expenses", href: "/expenses", icon: ReceiptText },
  { label: "Reports", href: "/reports", icon: BarChart3 },
  { label: "Settings", href: "/settings/organization", icon: Settings },
];

const QUICK_CREATE = [
  { label: "New Load", href: "/loads/new" },
  { label: "New Dispatch", href: "/dispatch/new" },
  { label: "New Carrier", href: "/carriers/new" },
  { label: "New Driver", href: "/drivers/new" },
  { label: "New Invoice", href: "/invoices/new" },
  { label: "Record Payment", href: "/payments/new" },
  { label: "Add Advance", href: "/advances/new" },
  { label: "New Expense", href: "/expenses/new" },
];

export function CommandPalette() {
  const [open, setOpen] = useState(false);
  const router = useRouter();

  useEffect(() => {
    function onKeyDown(e: KeyboardEvent) {
      if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === "k") {
        e.preventDefault();
        setOpen((prev) => !prev);
      }
    }
    function onOpenRequest() {
      setOpen(true);
    }
    document.addEventListener("keydown", onKeyDown);
    document.addEventListener("open-command-palette", onOpenRequest);
    return () => {
      document.removeEventListener("keydown", onKeyDown);
      document.removeEventListener("open-command-palette", onOpenRequest);
    };
  }, []);

  function go(href: string) {
    setOpen(false);
    router.push(href);
  }

  return (
    <CommandDialog open={open} onOpenChange={setOpen}>
      <CommandInput placeholder="Search modules, or type a command..." />
      <CommandList>
        <CommandEmpty>No results found.</CommandEmpty>
        <CommandGroup heading="Quick Create">
          {QUICK_CREATE.map((item) => (
            <CommandItem key={item.href} onSelect={() => go(item.href)}>
              <Plus className="size-4 text-muted-foreground" />
              {item.label}
            </CommandItem>
          ))}
        </CommandGroup>
        <CommandSeparator />
        <CommandGroup heading="Go to">
          {NAV_ITEMS.map((item) => (
            <CommandItem key={item.href} onSelect={() => go(item.href)}>
              <item.icon className="size-4 text-muted-foreground" />
              {item.label}
            </CommandItem>
          ))}
        </CommandGroup>
      </CommandList>
      <div className="flex items-center justify-end border-t border-border px-4 py-2 text-xs text-muted-foreground">
        <span className="flex items-center gap-1">
          Press <CommandShortcut>Esc</CommandShortcut> to close
        </span>
      </div>
    </CommandDialog>
  );
}

export function useCommandPaletteHint() {
  return typeof navigator !== "undefined" && /Mac|iPod|iPhone|iPad/.test(navigator.platform) ? "⌘K" : "Ctrl+K";
}

export function openCommandPalette() {
  document.dispatchEvent(new Event("open-command-palette"));
}
