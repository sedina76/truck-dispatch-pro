"use client";

import { createContext, useContext, useEffect, useId, useState } from "react";
import { cn } from "@/lib/utils";

// Shared collapsible "group box" for long profile/detail pages -- Driver
// Profile is the first page to use it (per instructions, not yet rolled
// out elsewhere). Deliberately NOT built on Radix/any animated accordion
// library: no expand animation, no unmounting on collapse -- collapsed
// content stays in the DOM (just `hidden`), so it never resets form
// values, never drops fields from a FormData submit, and never re-fetches
// anything. A section is purely a visibility toggle over content that was
// already going to render.

type SectionsContextValue = {
  isOpen: (id: string) => boolean;
  toggle: (id: string) => void;
  setAll: (open: boolean) => void;
};

const SectionsContext = createContext<SectionsContextValue | null>(null);

// Wrap a group of DesktopCollapsibleSection instances in this to get
// shared Expand All / Collapse All control (CollapsibleSectionsToolbar)
// over exactly that group. `defaults` must list every section id in the
// group up front -- Expand All/Collapse All only ever touch known ids,
// nothing dynamic to register.
//
// `storageKey` is optional and additive: omit it (as every existing caller
// does) and behavior is unchanged -- in-memory only, resets on navigation.
// Pass it to persist open/closed state to localStorage across visits.
// Hydration-safe by construction: the first render (server AND the
// client's initial hydration pass) always uses `defaults` -- identical
// output both places, so there is nothing to mismatch. Only AFTER
// hydration completes does an effect read localStorage and apply a saved
// preference, which is a normal post-mount state update, not a hydration
// diff -- no suppressHydrationWarning needed. This means a saved
// preference can cause one brief visible flash from defaults to the
// restored layout; deliberately accepted rather than risk a real
// server/client mismatch for a cosmetic detail.
export function CollapsibleSectionsProvider({
  defaults,
  storageKey,
  children,
}: {
  defaults: Record<string, boolean>;
  storageKey?: string;
  children: React.ReactNode;
}) {
  const [openMap, setOpenMap] = useState<Record<string, boolean>>(defaults);

  useEffect(() => {
    if (!storageKey) return;
    try {
      const raw = window.localStorage.getItem(storageKey);
      if (!raw) return;
      const saved = JSON.parse(raw) as Record<string, boolean>;
      // Only accept keys this page actually declared -- a stale/foreign
      // value saved by a different section set (or a corrupted value)
      // can never introduce an unknown section id or a non-boolean.
      setOpenMap((m) => {
        const next = { ...m };
        for (const key of Object.keys(m)) {
          if (typeof saved[key] === "boolean") next[key] = saved[key];
        }
        return next;
      });
    } catch {
      // localStorage unavailable (private mode, disabled) or corrupted
      // JSON -- fall back to defaults silently, never throw.
    }
    // Only ever read once, on mount -- this is a one-time restore, not a
    // sync loop.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [storageKey]);

  function persist(next: Record<string, boolean>) {
    if (!storageKey) return;
    try {
      window.localStorage.setItem(storageKey, JSON.stringify(next));
    } catch {
      // Ignore write failures (quota, private mode) -- persistence is a
      // convenience, never a requirement for the page to work.
    }
  }

  const value: SectionsContextValue = {
    isOpen: (id) => openMap[id] ?? true,
    toggle: (id) =>
      setOpenMap((m) => {
        const next = { ...m, [id]: !(m[id] ?? true) };
        persist(next);
        return next;
      }),
    setAll: (open) =>
      setOpenMap((m) => {
        const next = Object.fromEntries(Object.keys(m).map((k) => [k, open]));
        persist(next);
        return next;
      }),
  };

  return <SectionsContext.Provider value={value}>{children}</SectionsContext.Provider>;
}

// Compact desktop toolbar pair -- only renders once inside a
// CollapsibleSectionsProvider (silently renders nothing otherwise, so it's
// safe to drop in speculatively).
export function CollapsibleSectionsToolbar({ className }: { className?: string }) {
  const ctx = useContext(SectionsContext);
  if (!ctx) return null;
  return (
    <div className={cn("flex items-center gap-1.5", className)}>
      <button
        type="button"
        onClick={() => ctx.setAll(true)}
        className="h-6 rounded-sm border border-desktop-border bg-desktop-panel px-2 text-[11px] font-medium text-desktop-text transition-colors hover:bg-desktop-muted"
      >
        Expand All
      </button>
      <button
        type="button"
        onClick={() => ctx.setAll(false)}
        className="h-6 rounded-sm border border-desktop-border bg-desktop-panel px-2 text-[11px] font-medium text-desktop-text transition-colors hover:bg-desktop-muted"
      >
        Collapse All
      </button>
    </div>
  );
}

export function DesktopCollapsibleSection({
  id,
  title,
  description,
  defaultOpen = true,
  badge,
  badgeTone = "neutral",
  children,
  className,
}: {
  /** Unique within the page/provider -- used as the Expand/Collapse-All key. */
  id: string;
  title: string;
  description?: string;
  /** Only used when this section is NOT inside a CollapsibleSectionsProvider. */
  defaultOpen?: boolean;
  /** Small real indicator, e.g. "18" or "1 expiring" -- never a fabricated count. */
  badge?: string | number;
  badgeTone?: "neutral" | "warning";
  children: React.ReactNode;
  className?: string;
}) {
  const ctx = useContext(SectionsContext);
  const [localOpen, setLocalOpen] = useState(defaultOpen);
  const open = ctx ? ctx.isOpen(id) : localOpen;
  const toggle = () => (ctx ? ctx.toggle(id) : setLocalOpen((o) => !o));
  const contentId = useId();

  return (
    <div className={cn("rounded-md border border-desktop-border bg-desktop-panel", className)}>
      <button
        type="button"
        onClick={toggle}
        aria-expanded={open}
        aria-controls={contentId}
        className="flex h-8 w-full items-center gap-2 rounded-t-md bg-desktop-header px-3 text-left text-desktop-header-text transition-colors hover:brightness-110"
      >
        <span aria-hidden className="w-3 shrink-0 text-[10px] leading-none">
          {open ? "▼" : "▶"}
        </span>
        <span className="shrink-0 text-[11px] font-semibold uppercase tracking-wide">{title}</span>
        {badge !== undefined && badge !== "" && (
          <span
            className={cn(
              "shrink-0 rounded-sm px-1.5 py-0.5 text-[10px] font-semibold leading-none",
              badgeTone === "warning" ? "bg-desktop-warning/90 text-white" : "bg-desktop-header-text/15 text-desktop-header-text"
            )}
          >
            {badge}
          </span>
        )}
        {description && <span className="hidden truncate text-[11px] font-normal normal-case text-desktop-header-text/70 sm:inline">{description}</span>}
      </button>
      {/* Always mounted -- `hidden` only, never conditionally rendered, so
          collapsing can never drop an input's value from the form. */}
      <div id={contentId} className={open ? "p-3" : "hidden"}>
        {children}
      </div>
    </div>
  );
}
