import { cn } from "@/lib/utils";

// Creative-director pass: dropped the earlier draft's rounded-xl + flat
// drop-shadow + colored top accent bar (read as a generic template
// card). This version: a sophisticated off-white surface (not stark
// white), a more restrained radius, a thin border, and depth from a
// soft ambient glow behind the card (it reads as lit BY the environment
// it sits in, not pasted on top of it) rather than a heavy drop-shadow.
//
// Deliberately hardcoded to fixed light colors, not the app's
// theme-reactive --color-surface/--color-foreground tokens -- see this
// file's own reasoning carried over from the prior round: this is a
// standalone, committed look for the auth entry point, not a themed app
// surface, and a dark-mode visitor's flipped tokens would otherwise
// erase all contrast against the dark canvas.
export function AuthCard({ children, className, dark = false }: { children: React.ReactNode; className?: string; dark?: boolean }) {
  return (
    <div className="relative">
      <div className={cn("absolute -inset-6 -z-10 rounded-[28px] blur-2xl", dark ? "bg-[#1976ff]/20" : "bg-[#3a63d8]/10")} />
      <div className={cn(
        "w-full max-w-[29rem] rounded-2xl border shadow-[0_1px_2px_rgba(0,0,0,0.08),0_30px_70px_-22px_rgba(0,0,0,0.8)]",
        dark ? "border-[#2680ff]/65 bg-[#081426]/92 backdrop-blur-xl" : "border-[#e4e4e0] bg-[#faf9f7]",
        className
      )}>
        <div className="p-8 sm:p-10">{children}</div>
      </div>
    </div>
  );
}
