"use client";

import Link from "next/link";
import { MoreVertical, Eye, Pencil, Users, CreditCard, ShieldOff, ShieldCheck, Loader2 } from "lucide-react";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import { useSuspendCompanyAction, SuspendConfirmDialog } from "./suspend-company-control";

// Every item here routes to a real existing page/tab (the dedicated Edit
// Company page, the Company Detail's Admins/Subscription tabs) or calls
// setCompanySuspended() via the SAME
// useSuspendCompanyAction hook the Company Detail page's Suspend/
// Reactivate button uses -- one shared confirmation flow, not a
// second bypassable path to the same destructive action.
export function CompanyActionsMenu({ orgId, companyName, suspended }: { orgId: string; companyName: string; suspended: boolean }) {
  const { submitting, confirming, error, requestToggle, confirmSuspend, cancelConfirm } = useSuspendCompanyAction(orgId, suspended);

  return (
    <>
      <DropdownMenu>
        <DropdownMenuTrigger asChild>
          <button
            type="button"
            disabled={submitting}
            className="flex size-7 items-center justify-center rounded-md text-slate-400 hover:bg-slate-800 hover:text-slate-200 disabled:opacity-50"
          >
            {submitting ? <Loader2 className="size-3.5 animate-spin" /> : <MoreVertical className="size-3.5" />}
          </button>
        </DropdownMenuTrigger>
        <DropdownMenuContent align="end" className="w-56">
          <DropdownMenuItem asChild>
            <Link href={`/admin/companies/${orgId}`} className="flex items-center gap-2">
              <Eye className="size-3.5" /> View Company
            </Link>
          </DropdownMenuItem>
          <DropdownMenuItem asChild>
            <Link href={`/admin/companies/${orgId}/edit`} className="flex items-center gap-2">
              <Pencil className="size-3.5" /> Edit Company Profile
            </Link>
          </DropdownMenuItem>
          <DropdownMenuItem asChild>
            <Link href={`/admin/companies/${orgId}?tab=admins`} className="flex items-center gap-2">
              <Users className="size-3.5" /> Manage Admins &amp; Credentials
            </Link>
          </DropdownMenuItem>
          <DropdownMenuItem asChild>
            <Link href={`/admin/companies/${orgId}?tab=subscription`} className="flex items-center gap-2">
              <CreditCard className="size-3.5" /> Manage Subscription
            </Link>
          </DropdownMenuItem>
          <DropdownMenuSeparator />
          <DropdownMenuItem
            onSelect={(e) => {
              e.preventDefault();
              requestToggle();
            }}
            className={suspended ? "text-emerald-400 focus:text-emerald-400" : "text-red-400 focus:text-red-400"}
          >
            <span className="flex items-center gap-2">
              {suspended ? <ShieldCheck className="size-3.5" /> : <ShieldOff className="size-3.5" />}
              {suspended ? "Reactivate Company" : "Suspend Company"}
            </span>
          </DropdownMenuItem>
        </DropdownMenuContent>
      </DropdownMenu>
      {confirming && <SuspendConfirmDialog companyName={companyName} submitting={submitting} error={error} onConfirm={confirmSuspend} onCancel={cancelConfirm} />}
    </>
  );
}
