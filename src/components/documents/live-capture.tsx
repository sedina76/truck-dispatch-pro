"use client";

import { useEffect, useRef, useState } from "react";
import { Camera, ImageIcon, Zap, ZapOff, Check } from "lucide-react";
import { cn } from "@/lib/utils";
import { AutoCaptureTracker, grayFromRgba, type AutoCaptureStatus, type Box } from "@/lib/documents/auto-capture";

// Live camera view for the document scanner: the page is found, held steady
// and captured automatically (lib/documents/auto-capture.ts), so drivers
// don't need to press a shutter. A manual shutter, the phone's own camera
// app and "Choose photo" stay available. If the browser can't open a live
// camera (permission denied, no camera, old browser, desktop), onUnavailable
// fires and the scanner falls back to its classic buttons.

const ANALYSIS_WIDTH = 192; // px; detection runs on a tiny copy of each frame
const TICK_MS = 120; // ~8 analyses per second

const STATUS_TEXT: Record<AutoCaptureStatus | "starting", string> = {
  starting: "Starting camera…",
  searching: "Point the camera at the page",
  steadying: "Hold steady…",
  blurry: "Hold still so it can focus",
  capture: "Got it!",
  next: "Page captured. Show the next page, or tap Done",
};

export type LiveCaptureProps = {
  /** Full-resolution frame + the detected page box (fractions), or null for a manual shot without a page. */
  onFrame: (canvas: HTMLCanvasElement, box: Box | null) => Promise<void> | void;
  onUnavailable: (reason: string) => void;
  onUseCameraApp: () => void;
  onChoosePhoto: () => void;
  maxDimension: number;
  multiPage: boolean;
  pageCount: number;
  onDone: () => void;
  disabled?: boolean;
};

function unavailableReason(e: unknown): string {
  const name = e instanceof DOMException ? e.name : "";
  if (name === "NotAllowedError" || name === "SecurityError") return "Camera access is turned off for this site. Use Take Photo below, or allow the camera in your browser settings.";
  if (name === "NotFoundError" || name === "OverconstrainedError") return "No camera was found. Choose a photo instead.";
  if (name === "NotReadableError") return "The camera is busy in another app. Close it and try again, or use Take Photo.";
  return "Live camera isn't available in this browser. Use Take Photo instead.";
}

export function LiveCapture({ onFrame, onUnavailable, onUseCameraApp, onChoosePhoto, maxDimension, multiPage, pageCount, onDone, disabled }: LiveCaptureProps) {
  const videoRef = useRef<HTMLVideoElement>(null);
  const streamRef = useRef<MediaStream | null>(null);
  const trackerRef = useRef(new AutoCaptureTracker());
  const busyRef = useRef(false);
  const autoRef = useRef(true);
  const lastBoxRef = useRef<Box | null>(null);
  const onFrameRef = useRef(onFrame);
  const onUnavailableRef = useRef(onUnavailable);
  onFrameRef.current = onFrame;
  onUnavailableRef.current = onUnavailable;

  const [ready, setReady] = useState(false);
  const [auto, setAuto] = useState(true);
  const [status, setStatus] = useState<AutoCaptureStatus>("searching");
  const [progress, setProgress] = useState(0);
  const [overlay, setOverlay] = useState<{ left: number; top: number; width: number; height: number } | null>(null);
  const [flash, setFlash] = useState(false);

  useEffect(() => {
    autoRef.current = auto;
  }, [auto]);

  // Open the camera on mount, close it on unmount (scanner closed, or moved
  // on to the edit/pages screen) so the camera light never stays on.
  useEffect(() => {
    let cancelled = false;
    async function start() {
      if (typeof navigator === "undefined" || !navigator.mediaDevices?.getUserMedia) {
        onUnavailableRef.current(unavailableReason(null));
        return;
      }
      try {
        const stream = await navigator.mediaDevices.getUserMedia({
          audio: false,
          video: { facingMode: { ideal: "environment" }, width: { ideal: 1920 }, height: { ideal: 1080 } },
        });
        if (cancelled) {
          stream.getTracks().forEach((t) => t.stop());
          return;
        }
        streamRef.current = stream;
        const video = videoRef.current;
        if (!video) return;
        video.srcObject = stream;
        await video.play().catch(() => {});
        setReady(true);
      } catch (e) {
        if (!cancelled) onUnavailableRef.current(unavailableReason(e));
      }
    }
    void start();
    return () => {
      cancelled = true;
      streamRef.current?.getTracks().forEach((t) => t.stop());
      streamRef.current = null;
    };
  }, []);

  // Grab the current video frame at full resolution (capped) and hand it over.
  async function grab(box: Box | null) {
    const video = videoRef.current;
    if (!video || !video.videoWidth || busyRef.current) return;
    busyRef.current = true;
    try {
      const long = Math.max(video.videoWidth, video.videoHeight);
      const scale = long > maxDimension ? maxDimension / long : 1;
      const canvas = document.createElement("canvas");
      canvas.width = Math.round(video.videoWidth * scale);
      canvas.height = Math.round(video.videoHeight * scale);
      canvas.getContext("2d")?.drawImage(video, 0, 0, canvas.width, canvas.height);
      setFlash(true);
      window.setTimeout(() => setFlash(false), 180);
      try {
        navigator.vibrate?.(60);
      } catch {
        // vibration not allowed -- fine
      }
      await onFrameRef.current(canvas, box);
    } finally {
      busyRef.current = false;
    }
  }

  // Analysis loop: tiny frame -> tracker -> overlay + auto-capture.
  useEffect(() => {
    if (!ready) return;
    const video = videoRef.current;
    if (!video) return;
    const small = document.createElement("canvas");
    const ctx = small.getContext("2d", { willReadFrequently: true });
    if (!ctx) return;
    trackerRef.current.reset();
    let raf = 0;
    let last = 0;
    const tick = (now: number) => {
      raf = requestAnimationFrame(tick);
      if (now - last < TICK_MS || !video.videoWidth || busyRef.current) return;
      last = now;
      const w = ANALYSIS_WIDTH;
      const h = Math.max(1, Math.round((ANALYSIS_WIDTH * video.videoHeight) / video.videoWidth));
      if (small.width !== w || small.height !== h) {
        small.width = w;
        small.height = h;
      }
      ctx.drawImage(video, 0, 0, w, h);
      const gray = grayFromRgba(ctx.getImageData(0, 0, w, h).data, w, h);
      const r = trackerRef.current.feed(gray, w, h, now);
      lastBoxRef.current = r.box;
      setStatus(r.status);
      setProgress(r.progress);

      // Where the box sits on screen (the video is letterboxed: object-contain).
      if (r.box) {
        const el = video.getBoundingClientRect();
        const va = video.videoWidth / video.videoHeight;
        const contentW = el.width / el.height > va ? el.height * va : el.width;
        const contentH = el.width / el.height > va ? el.height : el.width / va;
        const ox = (el.width - contentW) / 2;
        const oy = (el.height - contentH) / 2;
        // Drawn a few px OUTSIDE the page so it doesn't vanish into a white sheet's own edge.
        const pad = 6;
        setOverlay({ left: ox + r.box.x * contentW - pad, top: oy + r.box.y * contentH - pad, width: r.box.w * contentW + pad * 2, height: r.box.h * contentH + pad * 2 });
      } else {
        setOverlay(null);
      }

      if (r.status === "capture" && autoRef.current) void grab(r.box);
    };
    raf = requestAnimationFrame(tick);
    return () => cancelAnimationFrame(raf);
    // grab is stable enough for this loop: it reads everything through refs
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [ready]);

  const shownStatus: AutoCaptureStatus | "starting" = !ready ? "starting" : !auto && status === "steadying" ? "searching" : status;
  const locked = status === "steadying" && progress > 0;

  return (
    <div className="flex h-full flex-col gap-3">
      <div className="relative min-h-0 flex-1 overflow-hidden rounded-xl bg-black">
        <video ref={videoRef} playsInline muted autoPlay className="absolute inset-0 h-full w-full object-contain" aria-label="Camera preview" />

        {overlay && (
          <div
            className={cn("pointer-events-none absolute rounded-md border-[3px] transition-[border-color] duration-150", locked ? "border-emerald-400 bg-emerald-400/10" : status === "next" ? "border-sky-300/70" : "border-sky-400 bg-sky-400/5")}
            style={overlay}
          >
            {auto && locked && (
              <div className="absolute inset-x-0 bottom-0 h-1.5 bg-black/30">
                <div className="h-full bg-emerald-400" style={{ width: `${Math.round(progress * 100)}%` }} />
              </div>
            )}
          </div>
        )}

        {flash && <div className="pointer-events-none absolute inset-0 bg-white/70" />}

        <div className="pointer-events-none absolute inset-x-0 top-3 flex justify-center px-3">
          <span role="status" aria-live="polite" className="rounded-full bg-black/65 px-3.5 py-1.5 text-center text-sm font-medium text-white">
            {auto ? STATUS_TEXT[shownStatus] : ready ? "Tap the button to take the picture" : STATUS_TEXT.starting}
          </span>
        </div>

        {multiPage && pageCount > 0 && (
          <span className="absolute left-3 bottom-3 rounded-full bg-black/65 px-3 py-1 text-xs font-semibold text-white">
            {pageCount} page{pageCount === 1 ? "" : "s"}
          </span>
        )}
      </div>

      <div className="grid shrink-0 grid-cols-3 items-center gap-2 pb-[env(safe-area-inset-bottom)]">
        <button type="button" onClick={onChoosePhoto} disabled={disabled} className="flex h-12 flex-col items-center justify-center text-xs font-medium text-muted-foreground disabled:opacity-50">
          <ImageIcon className="size-5" />
          Choose photo
        </button>
        <div className="flex justify-center">
          <button
            type="button"
            onClick={() => void grab(lastBoxRef.current)}
            disabled={!ready || disabled}
            aria-label="Take picture now"
            className="flex size-[72px] items-center justify-center rounded-full border-4 border-primary bg-card shadow-elevation-1 active:scale-95 disabled:opacity-50"
          >
            <Camera className="size-7 text-primary" />
          </button>
        </div>
        {multiPage && pageCount > 0 ? (
          <button type="button" onClick={onDone} disabled={disabled} className="flex h-12 items-center justify-center gap-1.5 rounded-xl bg-primary text-sm font-semibold text-primary-foreground disabled:opacity-50">
            <Check className="size-4" /> Done ({pageCount})
          </button>
        ) : (
          <button
            type="button"
            onClick={() => setAuto((a) => !a)}
            aria-pressed={auto}
            className={cn("flex h-12 flex-col items-center justify-center text-xs font-medium", auto ? "text-primary" : "text-muted-foreground")}
          >
            {auto ? <Zap className="size-5" /> : <ZapOff className="size-5" />}
            {auto ? "Auto on" : "Auto off"}
          </button>
        )}
      </div>
      <button type="button" onClick={onUseCameraApp} disabled={disabled} className="-mt-1 shrink-0 text-center text-xs font-medium text-muted-foreground underline-offset-2 hover:underline">
        Use my phone&apos;s camera app instead
      </button>
    </div>
  );
}
