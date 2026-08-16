import { cn } from "@/lib/utils";

type Tone = "neutral" | "success" | "warning" | "danger" | "info";

const TONE_BY_STATUS: Record<string, Tone> = {
  // success
  active: "success",
  valid: "success",
  paid: "success",
  completed: "success",
  delivered: "success",
  approved: "success",
  pod_received: "success",
  closed: "success",
  converted: "success",
  hired: "success",
  verified: "success",
  // warning
  incomplete: "warning",
  paused: "warning",
  expiring_soon: "warning",
  pending: "warning",
  draft: "warning",
  booked: "warning",
  assigned: "warning",
  sent: "warning",
  open: "warning",
  in_progress: "warning",
  partially_paid: "warning",
  on_hold: "warning",
  applicant: "warning",
  in_maintenance: "warning",
  under_review: "warning",
  // info
  in_transit: "info",
  dispatched: "info",
  posted: "info",
  viewed: "info",
  accepted: "info",
  en_route_to_pickup: "info",
  en_route_to_delivery: "info",
  at_pickup: "info",
  at_delivery: "info",
  loaded: "info",
  trialing: "info",
  invoiced: "info",
  submitted: "info",
  interview: "info",
  uploaded: "info",
  // collections: collection_status
  not_started: "neutral",
  contacted: "info",
  follow_up: "warning",
  promise_to_pay: "info",
  escalated: "danger",
  resolved: "success",
  // collections: payment_promises.status (effective)
  kept: "success",
  partially_kept: "warning",
  broken: "danger",
  // collections: priority (invoice_collection_priority())
  urgent: "danger",
  high: "warning",
  normal: "info",
  low: "neutral",
  // danger
  expired: "danger",
  cancelled: "danger",
  void: "danger",
  disputed: "danger",
  terminated: "danger",
  out_of_service: "danger",
  overdue: "danger",
  problem: "danger",
  past_due: "danger",
  rejected: "danger",
  // neutral
  inactive: "neutral",
  missing: "neutral",
  waived: "neutral",
  on_leave: "neutral",
  // subscription_status (0001) uses American spelling "canceled" (single
  // L) -- distinct string from the existing "cancelled" (double L) used
  // elsewhere in this app; both need their own entry.
  canceled: "neutral",
  // profitability_status (get_load_profitability) -- uppercase, unlike
  // every other enum here, so kept as distinct keys rather than lowered.
  COMPLETE: "success",
  ESTIMATED: "info",
  MISSING_COST: "warning",
  MISSING_REVENUE: "warning",
  NOT_DELIVERED: "neutral",
};

// Compact desktop-grid status indicator: a small square swatch + colored
// text, not a rounded "SaaS pill" -- reads as a real WinForms/Explorer
// list-view status column at dense row heights.
const TONE_TEXT_CLASSES: Record<Tone, string> = {
  neutral: "text-muted-foreground",
  success: "text-desktop-success",
  warning: "text-desktop-warning",
  danger: "text-desktop-danger",
  info: "text-secondary",
};

const TONE_DOT_CLASSES: Record<Tone, string> = {
  neutral: "bg-muted-foreground",
  success: "bg-desktop-success",
  warning: "bg-desktop-warning",
  danger: "bg-desktop-danger",
  info: "bg-secondary",
};

export function StatusBadge({ status }: { status: string | null | undefined }) {
  if (!status) return <span className="text-xs text-muted-foreground">--</span>;

  const tone = TONE_BY_STATUS[status] ?? "neutral";
  const label = status
    .split("_")
    .map((w) => w.charAt(0).toUpperCase() + w.slice(1))
    .join(" ");

  return (
    <span className={cn("inline-flex items-center gap-1.5 whitespace-nowrap text-[12px] font-medium", TONE_TEXT_CLASSES[tone])}>
      <span className={cn("size-1.5 shrink-0", TONE_DOT_CLASSES[tone])} />
      {label}
    </span>
  );
}
