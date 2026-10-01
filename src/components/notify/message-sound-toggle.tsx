"use client";

import { useEffect, useState } from "react";
import { Bell, BellOff } from "lucide-react";
import { isMessageSoundEnabled, playMessageChime, setMessageSoundEnabled } from "@/lib/notify/message-chime";
import { cn } from "@/lib/utils";

// Per-device on/off switch for the new-message chime (remembered in this
// browser only). Turning it on plays the chime once so the person hears
// what to listen for -- and that click also unlocks audio in the browser.
export function MessageSoundToggle({ className, compact = false }: { className?: string; compact?: boolean }) {
  const [on, setOn] = useState(true);
  useEffect(() => setOn(isMessageSoundEnabled()), []);

  function toggle() {
    const next = !on;
    setMessageSoundEnabled(next);
    setOn(next);
    if (next) playMessageChime({ force: true });
  }

  const Icon = on ? Bell : BellOff;
  const label = on ? "Message sound on" : "Message sound off";
  return (
    <button
      type="button"
      onClick={toggle}
      aria-pressed={on}
      title={on ? "New-message sound is on (click to mute)" : "New-message sound is off (click to turn on)"}
      className={cn("inline-flex items-center gap-1 hover:text-foreground", className)}
    >
      <Icon className={compact ? "size-3" : "size-4"} />
      <span>{label}</span>
    </button>
  );
}
