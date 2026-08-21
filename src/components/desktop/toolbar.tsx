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
} from "lucide-react";
import { cn } from "@/lib/utils";
import { openCommandPalette } from "@/components/nav/command-palette";
import { NotificationsMenu } from "@/components/nav/notifications-menu";
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
export function DesktopToolbar({ notifications }: { notifications: NotificationRow[] }) {
  const router = useRouter();
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

      <ToolbarLinkButton href="/loads/new" title="New Load" icon={PackagePlus} label="New Load" />
      <ToolbarLinkButton href="/dispatch/board" title="Dispatch Board" icon={KanbanSquare} label="Dispatch" />
      <ToolbarLinkButton href="/invoices/new" title="New Invoice" icon={Receipt} label="Invoice" />
      <ToolbarLinkButton href="/payments/new" title="Record Payment" icon={Wallet} label="Payment" />

      <Sep />

      <ToolbarLinkButton href="/collections?filter=follow_up_due" title="Follow-ups due" icon={PhoneCall} label="Follow-Up" />
      <ToolbarLinkButton href="/collections" title="Log a promise to pay" icon={HandCoins} label="Promise" />
      <ToolbarLinkButton href="/collections?filter=disputed" title="Disputed invoices" icon={ShieldAlert} label="Dispute" />
      <ToolbarLinkButton href="/collections?filter=unassigned" title="Unassigned accounts" icon={UserCog} label="Assign" />

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
