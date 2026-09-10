import { type InputHTMLAttributes } from "react";
import { Input } from "@/components/ui/input";
import { cn } from "@/lib/utils";

// The shared <Input> uses theme-reactive tokens that flip dark under the
// app's normal .dark class -- inside AuthCard's deliberately-fixed
// off-white surface, a theme-reactive input would render a dark box on a
// light card for any visitor in OS dark mode. This wrapper pins the
// visible colors to the same fixed palette as the card (a warm neutral
// scale, not the app's cool "slate" tokens) -- premium input states:
// crisp white fill against the card's slightly warmer off-white, a
// refined focus ring, without forking <Input> itself.
export function AuthInput({ className, dark = false, ...props }: InputHTMLAttributes<HTMLInputElement> & { dark?: boolean }) {
  return (
    <Input
      className={cn(
        "h-12 rounded-lg focus-visible:border-[#2680ff] focus-visible:ring-[#2680ff]/20",
        dark
          ? "border-white/20 bg-white/[0.045] text-white placeholder:text-[#8291aa]"
          : "border-[#d8d8d2] bg-white text-[#1a1a18] placeholder:text-[#b0b0a8]",
        className
      )}
      {...props}
    />
  );
}
