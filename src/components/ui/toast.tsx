"use client";

import { createContext, useCallback, useContext, useRef, useState } from "react";
import { CheckCircle2, XCircle, Info, X } from "lucide-react";
import { cn } from "@/lib/utils";

// Small, dependency-free toast system (Truck Dispatch Pro has never
// installed a notification library -- consistent with the rest of this
// codebase, which builds small bespoke Client Components instead of
// pulling in a package for something this size). Reusable anywhere in the
// app: wrap a subtree in <ToastProvider>, call useToast() from a
// descendant Client Component.

type ToastKind = "success" | "error" | "info";
type Toast = { id: number; kind: ToastKind; message: string };

type ToastContextValue = {
  show: (kind: ToastKind, message: string) => void;
};

const ToastContext = createContext<ToastContextValue | null>(null);

const ICON_BY_KIND: Record<ToastKind, React.ComponentType<{ className?: string }>> = {
  success: CheckCircle2,
  error: XCircle,
  info: Info,
};

const TONE_BY_KIND: Record<ToastKind, string> = {
  success: "border-desktop-success/30 bg-desktop-success/10 text-desktop-success",
  error: "border-danger/30 bg-danger/10 text-danger",
  info: "border-primary/30 bg-primary/10 text-primary",
};

const AUTO_DISMISS_MS = 4000;

export function ToastProvider({ children }: { children: React.ReactNode }) {
  const [toasts, setToasts] = useState<Toast[]>([]);
  const nextId = useRef(0);

  const dismiss = useCallback((id: number) => {
    setToasts((prev) => prev.filter((t) => t.id !== id));
  }, []);

  const show = useCallback(
    (kind: ToastKind, message: string) => {
      const id = nextId.current++;
      setToasts((prev) => [...prev, { id, kind, message }]);
      setTimeout(() => dismiss(id), AUTO_DISMISS_MS);
    },
    [dismiss]
  );

  return (
    <ToastContext.Provider value={{ show }}>
      {children}
      {/* Compact bottom-right stack -- never a giant banner. */}
      <div className="pointer-events-none fixed bottom-4 right-4 z-[100] flex w-80 flex-col gap-2">
        {toasts.map((t) => {
          const Icon = ICON_BY_KIND[t.kind];
          return (
            <div
              key={t.id}
              role="status"
              className={cn(
                "pointer-events-auto flex items-start gap-2 rounded-md border px-3 py-2.5 text-[13px] shadow-elevation-2 backdrop-blur-sm",
                "bg-desktop-panel",
                TONE_BY_KIND[t.kind]
              )}
            >
              <Icon className="mt-0.5 size-4 shrink-0" />
              <span className="flex-1 text-desktop-text">{t.message}</span>
              <button
                type="button"
                onClick={() => dismiss(t.id)}
                aria-label="Dismiss"
                className="shrink-0 rounded-sm p-0.5 text-desktop-text-muted hover:bg-desktop-muted"
              >
                <X className="size-3.5" />
              </button>
            </div>
          );
        })}
      </div>
    </ToastContext.Provider>
  );
}

// Never throws if no provider is mounted -- callers get a harmless no-op
// so a page that forgets to wrap itself doesn't crash, it just silently
// shows no toast (same defensive convention as DesktopCollapsibleSection's
// standalone fallback).
export function useToast(): ToastContextValue {
  const ctx = useContext(ToastContext);
  return ctx ?? { show: () => {} };
}
