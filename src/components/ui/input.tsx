import { type InputHTMLAttributes } from "react";
import { cn } from "@/lib/utils";

export function Input({ className, ...props }: InputHTMLAttributes<HTMLInputElement>) {
  return (
    <input
      className={cn(
        "flex h-8 w-full rounded-sm border border-desktop-border bg-card px-2.5 py-1 text-[13px] text-foreground shadow-elevation-1",
        "transition-[box-shadow,border-color] duration-150 placeholder:text-muted-foreground/70",
        "outline-none focus-visible:border-primary focus-visible:ring-2 focus-visible:ring-primary/20",
        "disabled:cursor-not-allowed disabled:opacity-50",
        className
      )}
      {...props}
    />
  );
}
