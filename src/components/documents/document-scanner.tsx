"use client";

import { useEffect, useRef, useState } from "react";
import { Camera, ImageIcon, X, RotateCw, Check, Plus, Trash2, ChevronLeft, ChevronRight, Loader2, AlertTriangle } from "lucide-react";
import * as DialogPrimitive from "@radix-ui/react-dialog";
import { Button } from "@/components/ui/button";
import { cn } from "@/lib/utils";
import { assembleScannedPdf, scannedFileName, type ScannedPage } from "@/lib/documents/scanner-pdf";

// Phase 2Q.1 -- Mobile Document Scanner.
//
// ONE reusable component (spec Section J) that every upload site can drop
// in next to its existing "Upload File" control. It never touches
// storage, RLS, or any server action itself -- it only turns a camera
// photo (or a chosen image) into a cropped, rotated, enhanced File (a
// plain JPEG, or a multi-page PDF assembled client-side with pdf-lib,
// already a project dependency -- see scanner-pdf.ts), then hands that
// File to the caller's onCapture. The caller feeds it into the EXACT
// SAME upload action/route it already uses for a plain <input type=
// "file"> selection (uploadLoadDocument, uploadOnboardingDocument, the
// driver-portal POD/expense/trip-document routes, etc.) -- see each
// integration site's own comment. That is the whole security story:
// this component is only another way to PRODUCE a File; every existing
// organization/entity/role/signature-immutability check downstream of
// "here is a File" is completely unmodified and un-bypassed (Section H).
//
// Camera capture itself is the same <input type="file" capture=
// "environment"> technique already used by
// src/components/driver-portal/expense-receipt-upload.tsx and
// trip-document-upload.tsx (confirmed during the Section A audit) -- not
// getUserMedia/<video>. That native-picker approach was kept deliberately:
// it already opens the device's own camera app (with its own zoom/flash/
// focus, already reliable on iPhone Safari and Android Chrome), degrades
// automatically to a normal file picker on desktop (the capture attribute
// is simply ignored there -- Section C's desktop fallback, for free), and
// needs no getUserMedia permission-prompt/stream-lifecycle/HTTPS-context
// handling of its own. If the user backs out of the native camera (denies
// the OS permission, or just cancels), onChange never fires and this
// component simply stays on the capture screen with the plain "Choose
// Photo" picker (no capture attribute) always visible right below it --
// satisfying Section C's permission-denied/no-camera/unsupported-browser
// cases without any extra branching.
//
// Perspective ("keystone") correction is intentionally NOT implemented --
// Canvas 2D has no true projective-transform primitive (only affine
// scale/rotate/skew via setTransform), and a hand-rolled triangle-warp
// approximation was judged not practical to build and verify reliably in
// this phase (Section D explicitly marks perspective correction as
// desirable, "if practical," not mandatory). Manual rectangular crop +
// 90-degree rotation covers the requirement; documented plainly rather
// than shipped half-working.

const MAX_WORKING_DIMENSION = 2000; // caps decode/edit memory (Section K); output is re-encoded at this size or smaller
const JPEG_QUALITY = 0.85;
const MIN_CROP_PX = 40; // floor so a resize handle can never collapse the crop box to zero
const MAX_RAW_FILE_BYTES = 40 * 1024 * 1024; // guards against decoding something pathological; ordinary phone photos are 2-12MB

type EnhanceMode = "original" | "document" | "grayscale";
const ENHANCE_FILTERS: Record<EnhanceMode, string> = {
  original: "none",
  grayscale: "grayscale(1)",
  document: "grayscale(1) contrast(1.35) brightness(1.12)",
};
const ENHANCE_LABEL: Record<EnhanceMode, string> = { original: "Original", document: "Document", grayscale: "Grayscale" };

type CropRect = { x: number; y: number; w: number; h: number };
type Stage = "capture" | "edit" | "pages";
type HandleId = "move" | "nw" | "ne" | "sw" | "se";

function clamp(n: number, min: number, max: number) {
  return Math.min(Math.max(n, min), max);
}

function fullFrame(canvas: HTMLCanvasElement): CropRect {
  // Inset ~4% so the initial box sits just inside the frame instead of
  // exactly on the edge (easier to grab a handle on a touchscreen).
  const inset = Math.round(Math.min(canvas.width, canvas.height) * 0.04);
  return { x: inset, y: inset, w: canvas.width - inset * 2, h: canvas.height - inset * 2 };
}

function errorMessage(e: unknown, fallback: string) {
  return e instanceof Error ? e.message : fallback;
}

// Decodes a picked/captured photo into a working canvas capped to
// MAX_WORKING_DIMENSION on its long edge. Uses <img> (not
// createImageBitmap) specifically because every evergreen browser
// auto-rotates <img> rendering per the photo's EXIF orientation tag,
// while createImageBitmap's orientation handling was historically
// inconsistent across browsers -- this avoids a whole class of "my scan
// is sideways" bugs for free.
async function decodeCapped(file: File): Promise<HTMLCanvasElement> {
  const url = URL.createObjectURL(file);
  try {
    const img = await new Promise<HTMLImageElement>((resolve, reject) => {
      const el = new Image();
      el.onload = () => resolve(el);
      el.onerror = () => reject(new Error("Could not read that photo. Try again or choose a different file."));
      el.src = url;
    });
    const longEdge = Math.max(img.naturalWidth, img.naturalHeight);
    const scale = longEdge > MAX_WORKING_DIMENSION ? MAX_WORKING_DIMENSION / longEdge : 1;
    const canvas = document.createElement("canvas");
    canvas.width = Math.max(1, Math.round(img.naturalWidth * scale));
    canvas.height = Math.max(1, Math.round(img.naturalHeight * scale));
    const ctx = canvas.getContext("2d");
    if (!ctx) throw new Error("This browser cannot process images.");
    ctx.drawImage(img, 0, 0, canvas.width, canvas.height);
    return canvas;
  } finally {
    URL.revokeObjectURL(url);
  }
}

function rotateCanvas90(src: HTMLCanvasElement): HTMLCanvasElement {
  const out = document.createElement("canvas");
  out.width = src.height;
  out.height = src.width;
  const ctx = out.getContext("2d")!;
  ctx.translate(out.width / 2, out.height / 2);
  ctx.rotate(Math.PI / 2);
  ctx.drawImage(src, -src.width / 2, -src.height / 2);
  return out;
}

function toBlob(canvas: HTMLCanvasElement, type: string, quality: number): Promise<Blob> {
  return new Promise((resolve, reject) => {
    canvas.toBlob((b) => (b ? resolve(b) : reject(new Error("Could not process the image."))), type, quality);
  });
}

// Crops + bakes the enhancement filter into one output canvas in a single
// drawImage call (Canvas 2D's ctx.filter, well-supported in current
// Safari/Chrome/Firefox, does the grayscale/contrast/brightness work
// natively -- no per-pixel JS loop needed).
async function renderPage(source: HTMLCanvasElement, crop: CropRect, mode: EnhanceMode): Promise<{ blob: Blob; width: number; height: number }> {
  const out = document.createElement("canvas");
  out.width = Math.max(1, Math.round(crop.w));
  out.height = Math.max(1, Math.round(crop.h));
  const ctx = out.getContext("2d");
  if (!ctx) throw new Error("This browser cannot process images.");
  ctx.filter = ENHANCE_FILTERS[mode];
  ctx.drawImage(source, crop.x, crop.y, crop.w, crop.h, 0, 0, out.width, out.height);
  const blob = await toBlob(out, "image/jpeg", JPEG_QUALITY);
  return { blob, width: out.width, height: out.height };
}

export type DocumentScannerOutputMode = "image" | "pdf" | "auto";

export interface DocumentScannerProps {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  // May throw (or reject) to report an upload failure -- the scanner
  // keeps every captured page in memory and lets the user retry rather
  // than closing or discarding anything (Section L).
  onCapture: (file: File) => void | Promise<void>;
  // Multi-page mode adds Add Page / delete / reorder around a page list
  // and (per outputMode) assembles a PDF. Single-page mode (default) ends
  // at [Retake]/[Use Scan] with no separate page list, per spec Section B.
  multiPage?: boolean;
  // "auto" (default): single page -> JPEG, 2+ pages -> PDF. Force "pdf" for
  // document types that should always end up as one PDF even at one page
  // (broker packet, signed paperwork); force "image" for a workflow that
  // specifically needs an image (kept for parity, not currently used).
  outputMode?: DocumentScannerOutputMode;
  // UI copy + filename base only (e.g. "POD", "BOL") -- never persisted.
  documentLabel?: string;
}

export function DocumentScanner({ open, onOpenChange, onCapture, multiPage = false, outputMode = "auto", documentLabel }: DocumentScannerProps) {
  const [stage, setStage] = useState<Stage>("capture");
  const [workingCanvas, setWorkingCanvas] = useState<HTMLCanvasElement | null>(null);
  const [cropRect, setCropRect] = useState<CropRect | null>(null);
  const [enhanceMode, setEnhanceMode] = useState<EnhanceMode>("document");
  const [pages, setPages] = useState<ScannedPage[]>([]);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const cameraInputRef = useRef<HTMLInputElement>(null);
  const fileInputRef = useRef<HTMLInputElement>(null);
  const displayCanvasRef = useRef<HTMLCanvasElement>(null);
  const dragRef = useRef<{ mode: HandleId; startX: number; startY: number; startRect: CropRect } | null>(null);
  const thumbUrlsRef = useRef<Map<string, string>>(new Map());

  // Redraw the preview canvas whenever the working image or enhancement
  // mode changes. Intrinsic canvas size == source pixel size; CSS scales
  // it down to fit the viewport, so pointer math only needs one scale
  // factor (see toSourceScale below).
  useEffect(() => {
    const el = displayCanvasRef.current;
    if (!el || !workingCanvas) return;
    el.width = workingCanvas.width;
    el.height = workingCanvas.height;
    const ctx = el.getContext("2d");
    if (!ctx) return;
    ctx.filter = ENHANCE_FILTERS[enhanceMode];
    ctx.clearRect(0, 0, el.width, el.height);
    ctx.drawImage(workingCanvas, 0, 0);
  }, [workingCanvas, enhanceMode]);

  // Thumbnail object URLs for the page list -- created lazily, revoked
  // the moment a page is removed or the scanner fully resets, never left
  // to leak across a long multi-page session (Section K).
  function thumbUrlFor(page: ScannedPage): string {
    let url = thumbUrlsRef.current.get(page.id);
    if (!url) {
      url = URL.createObjectURL(page.blob);
      thumbUrlsRef.current.set(page.id, url);
    }
    return url;
  }
  function revokeThumb(id: string) {
    const url = thumbUrlsRef.current.get(id);
    if (url) {
      URL.revokeObjectURL(url);
      thumbUrlsRef.current.delete(id);
    }
  }

  function resetAll() {
    for (const id of Array.from(thumbUrlsRef.current.keys())) revokeThumb(id);
    setStage("capture");
    setWorkingCanvas(null);
    setCropRect(null);
    setEnhanceMode("document");
    setPages([]);
    setBusy(false);
    setError(null);
  }

  // Revoke every outstanding thumbnail URL on unmount, regardless of how
  // the scanner was closed. Captures the map reference itself (stable for
  // the component's lifetime) rather than reading thumbUrlsRef.current
  // inside the cleanup closure.
  useEffect(() => {
    const urls = thumbUrlsRef.current;
    return () => {
      for (const url of urls.values()) URL.revokeObjectURL(url);
    };
  }, []);

  function handleOpenChange(next: boolean) {
    if (!next && busy) return; // never tear down state mid-upload
    if (!next) resetAll();
    onOpenChange(next);
  }

  async function handlePicked(file: File | undefined) {
    if (!file) return;
    setError(null);
    if (!file.type.startsWith("image/")) {
      setError("Please choose a photo.");
      return;
    }
    if (file.size > MAX_RAW_FILE_BYTES) {
      setError("That photo is too large to scan. Try a lower camera resolution or a different photo.");
      return;
    }
    try {
      const canvas = await decodeCapped(file);
      setWorkingCanvas(canvas);
      setCropRect(fullFrame(canvas));
      setEnhanceMode("document");
      setStage("edit");
    } catch (e) {
      setError(errorMessage(e, "Could not read that photo. Try again or choose a different file."));
    }
  }

  function rotate() {
    setWorkingCanvas((prev) => {
      if (!prev) return prev;
      const rotated = rotateCanvas90(prev);
      setCropRect(fullFrame(rotated));
      return rotated;
    });
  }

  function toSourceScale(): number {
    const canvas = workingCanvas;
    const el = displayCanvasRef.current;
    if (!canvas || !el) return 1;
    const rect = el.getBoundingClientRect();
    return rect.width > 0 ? canvas.width / rect.width : 1;
  }

  function onHandlePointerDown(mode: HandleId, e: React.PointerEvent) {
    if (!cropRect) return;
    e.preventDefault();
    e.stopPropagation();
    (e.currentTarget as Element).setPointerCapture(e.pointerId);
    dragRef.current = { mode, startX: e.clientX, startY: e.clientY, startRect: cropRect };
  }

  function onHandlePointerMove(e: React.PointerEvent) {
    const drag = dragRef.current;
    const canvas = workingCanvas;
    if (!drag || !canvas) return;
    const scale = toSourceScale();
    const dx = (e.clientX - drag.startX) * scale;
    const dy = (e.clientY - drag.startY) * scale;
    const { startRect } = drag;
    if (drag.mode === "move") {
      const x = clamp(startRect.x + dx, 0, canvas.width - startRect.w);
      const y = clamp(startRect.y + dy, 0, canvas.height - startRect.h);
      setCropRect({ x, y, w: startRect.w, h: startRect.h });
      return;
    }
    let left = startRect.x;
    let top = startRect.y;
    let right = startRect.x + startRect.w;
    let bottom = startRect.y + startRect.h;
    if (drag.mode === "nw" || drag.mode === "sw") left = clamp(left + dx, 0, right - MIN_CROP_PX);
    if (drag.mode === "ne" || drag.mode === "se") right = clamp(right + dx, left + MIN_CROP_PX, canvas.width);
    if (drag.mode === "nw" || drag.mode === "ne") top = clamp(top + dy, 0, bottom - MIN_CROP_PX);
    if (drag.mode === "sw" || drag.mode === "se") bottom = clamp(bottom + dy, top + MIN_CROP_PX, canvas.height);
    setCropRect({ x: left, y: top, w: right - left, h: bottom - top });
  }

  function onHandlePointerUp() {
    dragRef.current = null;
  }

  // Single-page mode: crop+enhance, upload, and only THEN tear down the
  // working image -- if onCapture rejects, workingCanvas/cropRect/
  // enhanceMode are all untouched, so the same Use Scan button just
  // retries with the identical crop (Section L).
  async function useScanSinglePage() {
    if (!workingCanvas || !cropRect) return;
    setBusy(true);
    setError(null);
    try {
      const { blob } = await renderPage(workingCanvas, cropRect, enhanceMode);
      const file = new File([blob], scannedFileName(documentLabel, "jpg"), { type: "image/jpeg" });
      await onCapture(file);
      resetAll();
      onOpenChange(false);
    } catch (e) {
      setError(errorMessage(e, "Could not save the scan. Your page is still here -- try again."));
    } finally {
      setBusy(false);
    }
  }

  // Multi-page mode: commit the current page into the list (no upload
  // yet), then show the page list. A rendering failure here is a rare,
  // environment-level failure (not an upload failure), so it's reported
  // inline without discarding the in-progress crop.
  async function usePageMultiPage() {
    if (!workingCanvas || !cropRect) return;
    setBusy(true);
    setError(null);
    try {
      const { blob, width, height } = await renderPage(workingCanvas, cropRect, enhanceMode);
      const page: ScannedPage = { id: crypto.randomUUID(), blob, width, height };
      setPages((prev) => [...prev, page]);
      setWorkingCanvas(null);
      setCropRect(null);
      setStage("pages");
    } catch (e) {
      setError(errorMessage(e, "Could not process that page. Try again."));
    } finally {
      setBusy(false);
    }
  }

  function removePage(id: string) {
    revokeThumb(id);
    setPages((prev) => prev.filter((p) => p.id !== id));
  }
  function rescanPage(id: string) {
    revokeThumb(id);
    setPages((prev) => prev.filter((p) => p.id !== id));
    setError(null);
    setStage("capture");
  }
  function movePage(id: string, dir: -1 | 1) {
    setPages((prev) => {
      const i = prev.findIndex((p) => p.id === id);
      const j = i + dir;
      if (i < 0 || j < 0 || j >= prev.length) return prev;
      const next = prev.slice();
      [next[i], next[j]] = [next[j], next[i]];
      return next;
    });
  }

  async function saveDocument() {
    if (pages.length === 0) return;
    setBusy(true);
    setError(null);
    try {
      const usePdf = outputMode === "pdf" || (outputMode !== "image" && pages.length > 1);
      const file = usePdf
        ? new File([await assembleScannedPdf(pages)], scannedFileName(documentLabel, "pdf"), { type: "application/pdf" })
        : new File([pages[0].blob], scannedFileName(documentLabel, "jpg"), { type: "image/jpeg" });
      await onCapture(file);
      resetAll();
      onOpenChange(false);
    } catch (e) {
      setError(errorMessage(e, "Could not save the document. Your pages are still here -- try again."));
    } finally {
      setBusy(false);
    }
  }

  const title = documentLabel ? `Scan ${documentLabel}` : "Scan Document";
  const scale = toSourceScale();
  const displayRect = cropRect ? { x: cropRect.x / scale, y: cropRect.y / scale, w: cropRect.w / scale, h: cropRect.h / scale } : null;

  return (
    <DialogPrimitive.Root open={open} onOpenChange={handleOpenChange}>
      <DialogPrimitive.Portal>
        <DialogPrimitive.Overlay className="fixed inset-0 z-50 bg-black/60" />
        <DialogPrimitive.Content
          onOpenAutoFocus={(e) => e.preventDefault()}
          onEscapeKeyDown={(e) => busy && e.preventDefault()}
          onInteractOutside={(e) => e.preventDefault()}
          className="fixed inset-0 z-50 flex h-full w-full flex-col bg-background outline-none"
        >
          <DialogPrimitive.Title className="sr-only">{title}</DialogPrimitive.Title>
          <div className="flex h-12 shrink-0 items-center justify-between border-b border-border px-3">
            <span className="text-sm font-medium text-foreground">{title}</span>
            <button
              type="button"
              disabled={busy}
              onClick={() => handleOpenChange(false)}
              aria-label="Close scanner"
              className="flex size-8 items-center justify-center rounded-md text-muted-foreground hover:bg-muted disabled:opacity-50"
            >
              <X className="size-4" />
            </button>
          </div>

          {error && (
            <div className="flex items-start gap-2 border-b border-danger/30 bg-danger/10 px-3 py-2 text-[12.5px] text-danger">
              <AlertTriangle className="mt-0.5 size-3.5 shrink-0" />
              <span>{error}</span>
            </div>
          )}

          <div className="flex-1 overflow-y-auto p-3">
            {stage === "capture" && (
              <div className="flex h-full flex-col items-center justify-center gap-3 text-center">
                <p className="max-w-xs text-[13px] text-muted-foreground">
                  {multiPage ? "Capture each page of the document, one photo at a time." : "Capture a photo of the document."}
                </p>
                <div className="flex w-full max-w-xs flex-col gap-2">
                  <Button type="button" size="lg" disabled={busy} onClick={() => cameraInputRef.current?.click()} className="h-14">
                    <Camera className="size-5" />
                    Take Photo
                  </Button>
                  <Button type="button" size="lg" variant="outline" disabled={busy} onClick={() => fileInputRef.current?.click()} className="h-14">
                    <ImageIcon className="size-5" />
                    Choose Photo
                  </Button>
                </div>
                <input
                  ref={cameraInputRef}
                  type="file"
                  accept="image/*"
                  capture="environment"
                  className="hidden"
                  onChange={(e) => {
                    void handlePicked(e.target.files?.[0]);
                    e.target.value = "";
                  }}
                />
                <input
                  ref={fileInputRef}
                  type="file"
                  accept="image/*"
                  className="hidden"
                  onChange={(e) => {
                    void handlePicked(e.target.files?.[0]);
                    e.target.value = "";
                  }}
                />
              </div>
            )}

            {stage === "edit" && workingCanvas && cropRect && displayRect && (
              <div className="flex h-full flex-col gap-3">
                <div
                  className="relative mx-auto max-h-[55vh] w-full max-w-xl touch-none select-none"
                  onPointerMove={onHandlePointerMove}
                  onPointerUp={onHandlePointerUp}
                >
                  <canvas ref={displayCanvasRef} className="mx-auto block max-h-[55vh] w-full rounded-md border border-border object-contain" />
                  <div
                    onPointerDown={(e) => onHandlePointerDown("move", e)}
                    className="absolute cursor-move border-2 border-primary bg-primary/10"
                    style={{ left: displayRect.x, top: displayRect.y, width: displayRect.w, height: displayRect.h }}
                  >
                    {(["nw", "ne", "sw", "se"] as const).map((corner) => (
                      <div
                        key={corner}
                        onPointerDown={(e) => onHandlePointerDown(corner, e)}
                        className={cn(
                          "absolute size-6 rounded-full border-2 border-primary bg-background shadow-elevation-1",
                          corner === "nw" && "-left-3 -top-3 cursor-nwse-resize",
                          corner === "ne" && "-right-3 -top-3 cursor-nesw-resize",
                          corner === "sw" && "-left-3 -bottom-3 cursor-nesw-resize",
                          corner === "se" && "-right-3 -bottom-3 cursor-nwse-resize"
                        )}
                      />
                    ))}
                  </div>
                </div>

                <div className="mx-auto flex w-full max-w-xl flex-wrap items-center justify-between gap-2">
                  <div className="flex overflow-hidden rounded-md border border-border">
                    {(Object.keys(ENHANCE_LABEL) as EnhanceMode[]).map((mode) => (
                      <button
                        key={mode}
                        type="button"
                        onClick={() => setEnhanceMode(mode)}
                        className={cn(
                          "px-2.5 py-1.5 text-[12px] font-medium",
                          enhanceMode === mode ? "bg-primary text-primary-foreground" : "bg-card text-muted-foreground hover:bg-muted"
                        )}
                      >
                        {ENHANCE_LABEL[mode]}
                      </button>
                    ))}
                  </div>
                  <Button type="button" variant="outline" size="sm" onClick={rotate} disabled={busy}>
                    <RotateCw className="size-3.5" />
                    Rotate
                  </Button>
                </div>
              </div>
            )}

            {stage === "pages" && (
              <div className="mx-auto grid w-full max-w-xl grid-cols-2 gap-2.5 sm:grid-cols-3">
                {pages.map((page, i) => (
                  <div key={page.id} className="relative overflow-hidden rounded-md border border-border">
                    {/* eslint-disable-next-line @next/next/no-img-element -- object URL thumbnail, not a Next-optimizable remote asset */}
                    <img src={thumbUrlFor(page)} alt={`Page ${i + 1}`} className="aspect-[3/4] w-full bg-muted object-cover" />
                    <span className="absolute left-1 top-1 rounded bg-black/60 px-1.5 py-0.5 text-[10.5px] font-medium text-white">{i + 1}</span>
                    <div className="absolute inset-x-0 bottom-0 flex items-center justify-between gap-1 bg-black/55 p-1">
                      <button type="button" disabled={busy || i === 0} onClick={() => movePage(page.id, -1)} className="rounded p-1 text-white disabled:opacity-30" aria-label="Move page earlier">
                        <ChevronLeft className="size-3.5" />
                      </button>
                      <button type="button" disabled={busy} onClick={() => rescanPage(page.id)} className="rounded p-1 text-white" aria-label="Rescan page">
                        <RotateCw className="size-3.5" />
                      </button>
                      <button type="button" disabled={busy} onClick={() => removePage(page.id)} className="rounded p-1 text-white" aria-label="Delete page">
                        <Trash2 className="size-3.5" />
                      </button>
                      <button type="button" disabled={busy || i === pages.length - 1} onClick={() => movePage(page.id, 1)} className="rounded p-1 text-white disabled:opacity-30" aria-label="Move page later">
                        <ChevronRight className="size-3.5" />
                      </button>
                    </div>
                  </div>
                ))}
                <button
                  type="button"
                  disabled={busy}
                  onClick={() => setStage("capture")}
                  className="flex aspect-[3/4] flex-col items-center justify-center gap-1 rounded-md border border-dashed border-border text-muted-foreground hover:bg-muted disabled:opacity-50"
                >
                  <Plus className="size-5" />
                  <span className="text-[12px] font-medium">Add Page</span>
                </button>
              </div>
            )}
          </div>

          <div className="flex shrink-0 items-center justify-end gap-2 border-t border-border p-3">
            {stage === "edit" && (
              <>
                <Button type="button" variant="outline" disabled={busy} onClick={() => { setWorkingCanvas(null); setCropRect(null); setError(null); setStage("capture"); }}>
                  Retake
                </Button>
                <Button type="button" disabled={busy} onClick={multiPage ? usePageMultiPage : useScanSinglePage}>
                  {busy ? <Loader2 className="size-4 animate-spin" /> : <Check className="size-4" />}
                  {multiPage ? "Use Page" : "Use Scan"}
                </Button>
              </>
            )}
            {stage === "pages" && (
              <Button type="button" disabled={busy || pages.length === 0} onClick={saveDocument}>
                {busy ? <Loader2 className="size-4 animate-spin" /> : <Check className="size-4" />}
                Save Document{pages.length > 0 ? ` (${pages.length})` : ""}
              </Button>
            )}
          </div>
        </DialogPrimitive.Content>
      </DialogPrimitive.Portal>
    </DialogPrimitive.Root>
  );
}
