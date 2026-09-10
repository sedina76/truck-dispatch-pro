"use client";

import { useCallback, useEffect, useState } from "react";
import { Maximize, Minimize } from "lucide-react";
import { cn } from "@/lib/utils";

// Cross-browser Fullscreen API surface. Safari (desktop) still ships only
// the webkit-prefixed methods/events as of 2026, so both are probed.
type FsDocument = Document & {
  webkitFullscreenElement?: Element | null;
  webkitExitFullscreen?: () => Promise<void> | void;
  webkitFullscreenEnabled?: boolean;
};
type FsElement = HTMLElement & {
  webkitRequestFullscreen?: () => Promise<void> | void;
};

function currentFullscreenElement(): Element | null {
  const d = document as FsDocument;
  return document.fullscreenElement ?? d.webkitFullscreenElement ?? null;
}

// Top-toolbar fullscreen toggle. Uses the standard Fullscreen API on the
// document element; the click itself is the required user gesture. Listens
// for fullscreenchange (+ webkit variant) so the icon/label stay correct
// when the user leaves fullscreen with Escape. Renders nothing when the
// browser has no Fullscreen API (graceful degradation). Purely visual --
// touches no navigation, sidebar, auth, or keyboard handling.
export function FullscreenToggle() {
  // false on the server AND the first client render so hydration matches;
  // the effect below enables it once mounted in a capable browser.
  const [supported, setSupported] = useState(false);
  const [active, setActive] = useState(false);

  useEffect(() => {
    const el = document.documentElement as FsElement;
    const canRequest =
      typeof el.requestFullscreen === "function" || typeof el.webkitRequestFullscreen === "function";
    if (!canRequest) return;

    setSupported(true);
    const sync = () => setActive(currentFullscreenElement() != null);
    sync();
    document.addEventListener("fullscreenchange", sync);
    document.addEventListener("webkitfullscreenchange", sync as EventListener);
    return () => {
      document.removeEventListener("fullscreenchange", sync);
      document.removeEventListener("webkitfullscreenchange", sync as EventListener);
    };
  }, []);

  const toggle = useCallback(() => {
    const d = document as FsDocument;
    try {
      if (currentFullscreenElement() == null) {
        const el = document.documentElement as FsElement;
        if (typeof el.requestFullscreen === "function") void el.requestFullscreen();
        else if (typeof el.webkitRequestFullscreen === "function") void el.webkitRequestFullscreen();
      } else {
        if (typeof document.exitFullscreen === "function") void document.exitFullscreen();
        else if (typeof d.webkitExitFullscreen === "function") void d.webkitExitFullscreen();
      }
    } catch {
      // A rejected request (permission / not a user gesture) leaves the
      // page as-is; the change listener corrects the icon if anything
      // actually toggled.
    }
  }, []);

  if (!supported) return null;

  const label = active ? "Exit fullscreen" : "Enter fullscreen";
  const Icon = active ? Minimize : Maximize;

  return (
    <button
      type="button"
      onClick={toggle}
      title={label}
      aria-label={label}
      aria-pressed={active}
      className={cn(
        "inline-flex size-7 shrink-0 items-center justify-center rounded-sm border border-transparent",
        "text-desktop-text/80 transition-colors hover:border-desktop-border hover:bg-desktop-muted"
      )}
    >
      <Icon className="size-4" />
    </button>
  );
}
