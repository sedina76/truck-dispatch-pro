"use client";

import { cn } from "@/lib/utils";

// A real, computed-from-the-actual-value heuristic -- never a fixed/fake
// bar. Scores length + character-class variety; this is presentational
// feedback only, it does not replace or loosen the real server-side
// minimum (8 characters, enforced in src/lib/supabase/actions.ts).
function scorePassword(password: string): { label: string; ratio: number; colorClass: string } {
  if (!password) return { label: "", ratio: 0, colorClass: "bg-transparent" };

  let score = 0;
  if (password.length >= 8) score++;
  if (password.length >= 12) score++;
  if (/[a-z]/.test(password) && /[A-Z]/.test(password)) score++;
  if (/\d/.test(password)) score++;
  if (/[^A-Za-z0-9]/.test(password)) score++;

  if (score <= 1) return { label: "Weak", ratio: 0.33, colorClass: "bg-danger" };
  if (score <= 3) return { label: "Fair", ratio: 0.66, colorClass: "bg-warning" };
  return { label: "Strong", ratio: 1, colorClass: "bg-success" };
}

export function PasswordStrength({ password }: { password: string }) {
  const { label, ratio, colorClass } = scorePassword(password);
  if (!password) return null;

  return (
    <div className="flex items-center gap-2">
      <div className="h-1.5 flex-1 overflow-hidden rounded-full bg-slate-100">
        <div className={cn("h-full rounded-full transition-all duration-200", colorClass)} style={{ width: `${ratio * 100}%` }} />
      </div>
      <span
        className={cn(
          "w-10 shrink-0 text-right text-xs font-medium",
          label === "Weak" && "text-danger",
          label === "Fair" && "text-warning",
          label === "Strong" && "text-success"
        )}
      >
        {label}
      </span>
    </div>
  );
}
