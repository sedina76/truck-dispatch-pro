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

type Note = { freq: number; start: number; dur: number; type: OscillatorType; peak: number };

function playNotes(notes: Note[], opts?: { force?: boolean }) {
  if (!opts?.force && !isMessageSoundEnabled()) return;
  const a = audio();
  if (!a) return;
  try {
    if (a.state === "suspended") a.resume().catch(() => {});
    const now = a.currentTime;
    for (const { freq, start, dur, type, peak } of notes) {
      const osc = a.createOscillator();
      const gain = a.createGain();
      osc.type = type;
      osc.frequency.value = freq;
      gain.gain.setValueAtTime(0.0001, now + start);
      gain.gain.exponentialRampToValueAtTime(peak, now + start + 0.015);
      gain.gain.exponentialRampToValueAtTime(0.0001, now + start + dur);
      osc.connect(gain).connect(a.destination);
      osc.start(now + start);
      osc.stop(now + start + dur + 0.02);
    }
  } catch {
    // never let a sound problem surface to the user
  }
}

// New message: two quick RISING notes ("peep-peep"), ~0.35s, friendly.
export function playMessageChime(opts?: { force?: boolean }) {
  playNotes(
    [
      { freq: 880, start: 0, dur: 0.15, type: "sine", peak: 0.25 },
      { freq: 1320, start: 0.16, dur: 0.15, type: "sine", peak: 0.25 },
    ],
    opts
  );
}

// Document rejected: three FALLING, buzzier notes, played twice (~1.3s) --
// deliberately unlike the message chime so a driver knows without looking
// that something needs fixing. Same on/off switch as the message chime.
export function playRejectedAlert(opts?: { force?: boolean }) {
  const pass = (t: number): Note[] => [
    { freq: 784, start: t, dur: 0.16, type: "triangle", peak: 0.32 },
    { freq: 587, start: t + 0.18, dur: 0.16, type: "triangle", peak: 0.32 },
    { freq: 392, start: t + 0.36, dur: 0.28, type: "triangle", peak: 0.32 },
  ];
  playNotes([...pass(0), ...pass(0.72)], opts);
}
