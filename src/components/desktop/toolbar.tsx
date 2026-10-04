"use client";

import { useState } from "react";
import Link from "next/link";
import { useRouter } from "next/navigation";
import {
  ArrowLeft,
  ArrowRight,
  RotateCw,
  PackagePlus,
  KanbanSquare,
  Receipt,
  Wallet,
  PhoneCall,
  HandCoins,
  ShieldAlert,
  UserCog,
  Printer,
  Mail,
  HelpCircle,
  Radio,
  ClipboardCheck,
  ChevronDown,
  ListChecks,
} from "lucide-react";
import { DropdownMenu, DropdownMenuContent, DropdownMenuItem, DropdownMenuTrigger } from "@/components/ui/dropdown-menu";
import { useOrgRole } from "@/components/auth/role-context";
import { hrefAllowedForRole } from "@/lib/auth/billing-access";
import { cn } from "@/lib/utils";
import { openCommandPalette } from "@/components/nav/command-palette";
import { NotificationsMenu } from "@/components/nav/notifications-menu";
import { FullscreenToggle } from "@/components/desktop/fullscreen-toggle";
import { useDesktopActions } from "@/components/desktop/actions-context";
import { DesktopExportMenu } from "@/components/desktop/export-menu";
import { DesktopEmailDialog } from "@/components/desktop/email-dialog";

type NotificationRow = {
  id: string;
  title: string;
  body: string | null;
  type: string;
  entity_type: string | null;
  entity_id: string | null;
  exception_id: string | null;
  read_at: string | null;
  created_at: string;
};

// Persistent action toolbar. Back/Forward/Refresh/New-record shortcuts are
// fixed, real navigation as before. Print/Export/Email are context-aware:
// they read whatever the CURRENT page registered via
// RegisterDesktopActions (see actions-context.tsx) -- a page that
// registers nothing gets the same safe defaults as before this feature
// (Print falls back to window.print(), Export/Email stay disabled with a
// truthful reason), so nothing regresses on pages not yet wired up.
// The four collections shortcuts in one menu (they were four toolbar buttons;
// "Promise" claimed to log a promise but only opened the page).
const COLLECTION_VIEWS = [
  { label: "Follow-ups due", href: "/collections?filter=follow_up_due", icon: PhoneCall },
  { label: "Promises to pay", href: "/collections?status=promise_to_pay", icon: HandCoins },
  { label: "Disputed invoices", href: "/collections?filter=disputed", icon: ShieldAlert },
  { label: "Unassigned accounts", href: "/collections?filter=unassigned", icon: UserCog },
  { label: "All collections", href: "/collections", icon: ListChecks },
];

export function DesktopToolbar({ notifications }: { notifications: NotificationRow[] }) {
  const router = useRouter();
  const role = useOrgRole();
  const allowed = (href: string) => hrefAllowedForRole(href, role);
  const { actions } = useDesktopActions();
  const [emailOpen, setEmailOpen] = useState(false);

  function handlePrint() {
    if (actions?.printHref) {
      window.open(actions.printHref, "_blank", "noopener,noreferrer");
      return;
    }
    window.print();
  }

  const emailDisabledReason = actions?.emailDisabledReason ?? (actions?.email ? undefined : "Email is not available for this view");

  return (
    <div className="flex h-9 shrink-0 items-center gap-0.5 border-b border-desktop-border bg-desktop-panel px-1.5">
      <ToolbarIconButton title="Back" onClick={() => router.back()}>
        <ArrowLeft className="size-4" />
      </ToolbarIconButton>
      <ToolbarIconButton title="Forward" onClick={() => router.forward()}>
        <ArrowRight className="size-4" />
      </ToolbarIconButton>
      <ToolbarIconButton title="Refresh" onClick={() => router.refresh()}>
        <RotateCw className="size-4" />
      </ToolbarIconButton>

      <Sep />

      {/* The work in order: book -> dispatch -> track | bill -> get paid | chase. */}
      <ToolbarLinkButton href="/loads/new" title="New Load" icon={PackagePlus} label="New Load" />
      <ToolbarLinkButton href="/dispatch/board" title="Dispatch Board" icon={KanbanSquare} label="Dispatch" />
      <ToolbarLinkButton href="/tracking" title="Live Tracking map" icon={Radio} label="Tracking" />

      {allowed("/billing/ready-to-bill") && <Sep />}
      {allowed("/billing/ready-to-bill") && <ToolbarLinkButton href="/billing/ready-to-bill" title="Delivered loads ready to bill" icon={ClipboardCheck} label="Ready to Bill" />}
      {allowed("/invoices/new") && <ToolbarLinkButton href="/invoices/new" title="New Invoice (yours or the carrier's)" icon={Receipt} label="Invoice" />}
      {allowed("/payments/new") && <ToolbarLinkButton href="/payments/new" title="Record Payment" icon={Wallet} label="Payment" />}

      {allowed("/collections") && (
        <>
          <Sep />
          <DropdownMenu>
            <DropdownMenuTrigger asChild>
              <button
                type="button"
                title="Collections"
                className="inline-flex shrink-0 items-center gap-1.5 rounded-sm border border-transparent px-2 py-1 text-[12px] font-medium text-desktop-text/90 outline-none transition-colors hover:border-desktop-border hover:bg-desktop-muted data-[state=open]:border-desktop-border data-[state=open]:bg-desktop-muted"
              >
                <PhoneCall className="size-4 text-primary" />
                <span className="hidden lg:inline">Collections</span>
                <ChevronDown className="size-3 text-muted-foreground" />
              </button>
            </DropdownMenuTrigger>
            <DropdownMenuContent align="start" className="w-52 rounded-sm p-1 text-[12.5px]">
              {COLLECTION_VIEWS.map((v) => (
                <DropdownMenuItem key={v.href} asChild className="rounded-sm text-[12.5px]">
                  <Link href={v.href} className="flex items-center gap-2">
                    <v.icon className="size-3.5 text-primary" /> {v.label}
                  </Link>
                </DropdownMenuItem>
              ))}
            </DropdownMenuContent>
          </DropdownMenu>
        </>
      )}

      <Sep />

      <ToolbarIconButton title={actions?.printHref ? `Print ${actions.title}` : "Print current page"} onClick={handlePrint}>
        <Printer className="size-4" />
      </ToolbarIconButton>
      <DesktopExportMenu />
      <ToolbarIconButton
        title={emailDisabledReason ?? `Email ${actions?.title ?? ""}`}
        onClick={actions?.email ? () => setEmailOpen(true) : undefined}
        disabled={!actions?.email}
      >
        <Mail className="size-4" />
      </ToolbarIconButton>
      <DesktopEmailDialog open={emailOpen} onOpenChange={setEmailOpen} />

      <div className="ml-auto flex items-center gap-0.5">
        <FullscreenToggle />
        <NotificationsMenu notifications={notifications} />
        <ToolbarIconButton title="Search / Help" onClick={openCommandPalette}>
          <HelpCircle className="size-4" />
        </ToolbarIconButton>
      </div>
    </div>
  );
}

function Sep() {
  return <div className="mx-1 h-5 w-px shrink-0 bg-desktop-border" />;
}

function ToolbarIconButton({
  title,
  onClick,
  disabled,
  className,
  children,
}: {
  title: string;
  onClick?: () => void;
  disabled?: boolean;
  className?: string;
  children: React.ReactNode;
}) {
  return (
    <button
      type="button"
      title={title}
      aria-label={title}
      onClick={onClick}
      disabled={disabled}
      className={cn(
        "inline-flex size-7 shrink-0 items-center justify-center rounded-sm border border-transparent text-desktop-text/80 transition-colors hover:border-desktop-border hover:bg-desktop-muted disabled:pointer-events-none disabled:opacity-35",
        className
      )}
    >
      {children}
    </button>
  );
}

function ToolbarLinkButton({
  href,
  title,
  icon: Icon,
  label,
}: {
  href: string;
  title: string;
  icon: React.ComponentType<{ className?: string }>;
  label: string;
}) {
  return (
    <Link
      href={href}
      title={title}
      className="inline-flex shrink-0 items-center gap-1.5 rounded-sm border border-transparent px-2 py-1 text-[12px] font-medium text-desktop-text/90 transition-colors hover:border-desktop-border hover:bg-desktop-muted"
    >
      <Icon className="size-4 text-primary" />
      <span className="hidden lg:inline">{label}</span>
    </Link>
  );
}
