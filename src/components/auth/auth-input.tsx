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
export function AuthInput({ className, ...props }: InputHTMLAttributes<HTMLInputElement>) {
  return (
    <Input
      className={cn(
        "h-10 border-[#d8d8d2] bg-white text-[#1a1a18] placeholder:text-[#b0b0a8] focus-visible:border-[#1c54b8] focus-visible:ring-[#1c54b8]/15",
        className
      )}
      {...props}
    />
  );
}
