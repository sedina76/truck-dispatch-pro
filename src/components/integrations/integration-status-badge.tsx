import { cn } from "@/lib/utils";
import type { StatusResult } from "@/lib/integrations/status";

// Same compact dot+text convention as StatusBadge
// (src/components/ui/status-badge.tsx), but fed the already-computed
// {label, tone} from deriveIntegrationStatus() directly instead of
// deriving a label from a raw status string -- the integration status
// vocabulary ("Needs Attention", "API Access Required") doesn't fit
// StatusBadge's generic split-and-title-case transform, and this domain
// is different enough (9 states, never derived from a boolean) to warrant
// its own small component rather than stretching a shared one.
const TONE_TEXT_CLASSES: Record<StatusResult["tone"], string> = {
  neutral: "text-muted-foreground",
  success: "text-desktop-success",
  warning: "text-desktop-warning",
  danger: "text-desktop-danger",
};
const TONE_DOT_CLASSES: Record<StatusResult["tone"], string> = {
  neutral: "bg-muted-foreground",
  success: "bg-desktop-success",
  warning: "bg-desktop-warning",
  danger: "bg-desktop-danger",
};

export function IntegrationStatusBadge({ result }: { result: StatusResult }) {
  return (
    <span className={cn("inline-flex items-center gap-1.5 whitespace-nowrap text-[12px] font-semibold uppercase tracking-wide", TONE_TEXT_CLASSES[result.tone])}>
      <span className={cn("size-1.5 shrink-0 rounded-full", TONE_DOT_CLASSES[result.tone])} />
      {result.label}
    </span>
  );
}
