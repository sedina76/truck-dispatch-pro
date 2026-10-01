// Browser-only: plays the short two-note "new message" chime with the Web
// Audio API (no audio file to load or cache), and remembers the per-device
// on/off choice. Every call is best-effort and never throws -- a blocked
// or missing audio device must never break messaging.
//
// Browsers only allow sound after the person has interacted with the page
// at least once (a tap, click or key press). installChimeUnlock() resumes
// the audio engine on that first interaction, so later chimes can play
// even while the person is on another tab or not touching the screen.
import { MESSAGE_SOUND_STORAGE_KEY, soundEnabledFromStorage } from "./message-alert";

type AudioCtor = typeof AudioContext;
let ctx: AudioContext | null = null;

function audio(): AudioContext | null {
  if (typeof window === "undefined") return null;
  if (ctx) return ctx;
  const Ctor: AudioCtor | undefined = window.AudioContext ?? (window as unknown as { webkitAudioContext?: AudioCtor }).webkitAudioContext;
  if (!Ctor) return null;
  try {
    ctx = new Ctor();
  } catch {
    ctx = null;
  }
  return ctx;
}

export function installChimeUnlock(): () => void {
  if (typeof window === "undefined") return () => {};
  const unlock = () => {
    const a = audio();
    if (a && a.state === "suspended") a.resume().catch(() => {});
  };
  const events = ["pointerdown", "keydown", "touchstart"] as const;
  events.forEach((e) => window.addEventListener(e, unlock, { passive: true }));
  return () => events.forEach((e) => window.removeEventListener(e, unlock));
}

export function isMessageSoundEnabled(): boolean {
  try {
    return soundEnabledFromStorage(window.localStorage.getItem(MESSAGE_SOUND_STORAGE_KEY));
  } catch {
    return true;
  }
}

export function setMessageSoundEnabled(on: boolean) {
  try {
    window.localStorage.setItem(MESSAGE_SOUND_STORAGE_KEY, on ? "on" : "off");
  } catch {
    // per-device preference only; nothing else to do
  }
}

// Two quick rising notes ("peep-peep"), ~0.35s total, moderate volume.
export function playMessageChime(opts?: { force?: boolean }) {
  if (!opts?.force && !isMessageSoundEnabled()) return;
  const a = audio();
  if (!a) return;
  try {
    if (a.state === "suspended") a.resume().catch(() => {});
    const now = a.currentTime;
    [
      { freq: 880, start: 0 },
      { freq: 1320, start: 0.16 },
    ].forEach(({ freq, start }) => {
      const osc = a.createOscillator();
      const gain = a.createGain();
      osc.type = "sine";
      osc.frequency.value = freq;
      gain.gain.setValueAtTime(0.0001, now + start);
      gain.gain.exponentialRampToValueAtTime(0.25, now + start + 0.015);
      gain.gain.exponentialRampToValueAtTime(0.0001, now + start + 0.15);
      osc.connect(gain).connect(a.destination);
      osc.start(now + start);
      osc.stop(now + start + 0.17);
    });
  } catch {
    // never let a sound problem surface to the user
  }
}
