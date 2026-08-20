import { type ButtonHTMLAttributes } from "react";
import { Button } from "@/components/ui/button";
import { cn } from "@/lib/utils";

// The one primary-action button style for every auth form -- guarantees
// "same button style" across all six screens rather than copy-pasting the
// same override classes six times. Stronger treatment than the app's
// default Button variant=primary: taller, a subtle inset highlight +
// colored glow shadow for real depth, slightly heavier weight.
export function AuthButton({ className, ...props }: ButtonHTMLAttributes<HTMLButtonElement>) {
  return (
    <Button
      {...props}
      size="lg"
      className={cn(
        "h-11 w-full bg-[#1c54b8] text-[15px] font-semibold shadow-[0_1px_0_rgba(255,255,255,0.15)_inset,0_8px_20px_-6px_rgba(28,84,184,0.55)] hover:bg-[#164291]",
        className
      )}
    />
  );
}
