import { Truck } from "lucide-react";
import { cn } from "@/lib/utils";

// The ONE place the product name/wordmark is assembled for auth surfaces.
// `size="lg"` (the auth shell header) gives the brand real presence --
// the earlier draft's small fixed lockup read as an afterthought, not a
// confident brand entrance.
export function Logo({
  className,
  subtitle = false,
  dark = false,
  size = "md",
}: {
  className?: string;
  subtitle?: boolean;
  dark?: boolean;
  size?: "md" | "lg";
}) {
  const lg = size === "lg";
  return (
    <div className={cn("flex items-center", lg ? "gap-3.5" : "gap-2.5", className)}>
      <div
        className={cn(
          "flex shrink-0 items-center justify-center rounded-lg border",
          lg ? "size-12" : "size-9",
          dark ? "border-white/20 bg-white/5 text-white" : "border-primary/25 bg-primary/5 text-primary"
        )}
      >
        <Truck className={lg ? "size-6" : "size-5"} />
      </div>
      <div className="leading-tight">
        <div className={cn("font-bold uppercase tracking-wide", lg ? "text-xl" : "text-[15px]", dark ? "text-white" : "text-foreground")}>
          Truck Dispatch <span className="text-primary">Pro</span>
        </div>
        {subtitle && (
          <div className={cn(lg ? "text-[13px]" : "text-[11px]", dark ? "text-white/55" : "text-muted-foreground")}>
            Transportation Management System
          </div>
        )}
      </div>
    </div>
  );
}
