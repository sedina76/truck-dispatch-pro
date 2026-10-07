// Hands-free document capture for the scanner's live camera view: finds a
// sheet of paper in a small, downscaled video frame, waits until it's held
// steady and in focus, then says "capture" -- so the driver never has to
// press a shutter button.
//
// Pure functions on grayscale pixel arrays (no DOM), so they run in a unit
// test. Deliberately simple and cheap enough for ~8 frames/second on an
// older phone:
//   * page = the largest bright rectangle against a darker background
//     (paper is almost always lighter than the dash/desk/clipboard behind
//     it), found with an Otsu threshold and row/column projections;
//   * steady = the frame barely changes and the page box barely moves;
//   * sharp = some edge detail (Laplacian variance) inside the page. A safety
//     net only: it rejects frames with almost no detail (heavy motion blur,
//     a blank smear); steadiness does the real work.
// It finds an upright-ish rectangle, not exact corners: the capture is
// cropped to that box and the driver can still adjust it on the edit screen.

export type Box = { x: number; y: number; w: number; h: number }; // fractions of the frame, 0..1

export function grayFromRgba(data: Uint8ClampedArray | Uint8Array, width: number, height: number): Uint8Array {
  const out = new Uint8Array(width * height);
  for (let i = 0, p = 0; i < out.length; i += 1, p += 4) {
    // Rec. 601 luma, integer math
    out[i] = (data[p] * 77 + data[p + 1] * 150 + data[p + 2] * 29) >> 8;
  }
  return out;
}

export function otsuThreshold(gray: Uint8Array): number {
  const hist = new Array<number>(256).fill(0);
  for (let i = 0; i < gray.length; i += 1) hist[gray[i]] += 1;
  const total = gray.length;
  let sum = 0;
  for (let t = 0; t < 256; t += 1) sum += t * hist[t];
  let sumB = 0;
  let wB = 0;
  let best = 0;
  let threshold = 127;
  for (let t = 0; t < 256; t += 1) {
    wB += hist[t];
    if (wB === 0) continue;
    const wF = total - wB;
    if (wF === 0) break;
    sumB += t * hist[t];
    const mB = sumB / wB;
    const mF = (sum - sumB) / wF;
    const between = wB * wF * (mB - mF) * (mB - mF);
    if (between > best) {
      best = between;
      threshold = t;
    }
  }
  return threshold;
}

/** Longest run of indexes where values[i] >= min, tolerating gaps of up to `gap`. */
function longestRun(values: number[], min: number, gap: number): [number, number] | null {
  let best: [number, number] | null = null;
  let start = -1;
  let lastHit = -1;
  for (let i = 0; i <= values.length; i += 1) {
    const hit = i < values.length && values[i] >= min;
    if (hit) {
      if (start < 0 || i - lastHit > gap + 1) start = i;
      lastHit = i;
      if (!best || lastHit - start > best[1] - best[0]) best = [start, lastHit];
    }
  }
  return best;
}

export type PageDetection = { box: Box | null; contrast: number; fillsFrame: boolean };

/**
 * Bright mask with short dark gaps filled in, along rows then columns
 * (a 1-D morphological closing). Printed text inside the page becomes
 * "paper", so a densely printed sheet still reads as one solid rectangle.
 */
function closedBrightMask(gray: Uint8Array, width: number, height: number, t: number): Uint8Array {
  const m = new Uint8Array(width * height);
  for (let i = 0; i < m.length; i += 1) m[i] = gray[i] > t ? 1 : 0;
  const kx = Math.max(2, Math.round(width * 0.06));
  const ky = Math.max(2, Math.round(height * 0.06));
  for (let y = 0; y < height; y += 1) {
    let last = -1;
    for (let x = 0; x < width; x += 1) {
      const i = y * width + x;
      if (!m[i]) continue;
      if (last >= 0 && x - last - 1 <= kx) for (let f = last + 1; f < x; f += 1) m[y * width + f] = 1;
      last = x;
    }
  }
  for (let x = 0; x < width; x += 1) {
    let last = -1;
    for (let y = 0; y < height; y += 1) {
      if (!m[y * width + x]) continue;
      if (last >= 0 && y - last - 1 <= ky) for (let f = last + 1; f < y; f += 1) m[f * width + x] = 1;
      last = y;
    }
  }
  return m;
}

const MIN_SIDE = 0.25; // page must span at least a quarter of the frame each way
const MIN_CONTRAST = 28; // page vs background brightness, 0..255
const FILL_AREA = 0.95; // a page this big is treated as "fills the frame"

export function detectPage(gray: Uint8Array, width: number, height: number): PageDetection {
  const none: PageDetection = { box: null, contrast: 0, fillsFrame: false };
  if (width < 8 || height < 8) return none;
  const t = Math.max(otsuThreshold(gray), 60); // never call a dark frame "paper"
  const mask = closedBrightMask(gray, width, height, t);

  const rowFrac = new Array<number>(height).fill(0);
  for (let y = 0; y < height; y += 1) {
    let c = 0;
    for (let x = 0, i = y * width; x < width; x += 1, i += 1) c += mask[i];
    rowFrac[y] = c / width;
  }
  const rows = longestRun(rowFrac, 0.25, Math.max(1, Math.round(height * 0.02)));
  if (!rows || rows[1] - rows[0] + 1 < height * MIN_SIDE) return none;
  const [top, bottom] = rows;
  const runH = bottom - top + 1;

  const colFrac = new Array<number>(width).fill(0);
  for (let x = 0; x < width; x += 1) {
    let c = 0;
    for (let y = top; y <= bottom; y += 1) c += mask[y * width + x];
    colFrac[x] = c / runH;
  }
  const cols = longestRun(colFrac, 0.5, Math.max(1, Math.round(width * 0.02)));
  if (!cols || cols[1] - cols[0] + 1 < width * MIN_SIDE) return none;
  const [left, right] = cols;

  let inSum = 0;
  let inN = 0;
  let inBright = 0;
  let outSum = 0;
  let outN = 0;
  for (let y = 0; y < height; y += 1) {
    for (let x = 0; x < width; x += 1) {
      const v = gray[y * width + x];
      if (y >= top && y <= bottom && x >= left && x <= right) {
        inSum += v;
        inN += 1;
        inBright += mask[y * width + x];
      } else {
        outSum += v;
        outN += 1;
      }
    }
  }
  if (inN === 0 || inBright / inN < 0.6) return none; // mostly dark inside: not a sheet of paper
  const inMean = inSum / inN;
  const area = inN / (width * height);
  const fillsFrame = area >= FILL_AREA || outN < width * height * 0.03;
  const contrast = outN > 0 ? inMean - outSum / outN : 255;
  if (fillsFrame ? inMean < 140 : contrast < MIN_CONTRAST) return { box: null, contrast, fillsFrame };

  return {
    box: { x: left / width, y: top / height, w: (right - left + 1) / width, h: runH / height },
    contrast,
    fillsFrame,
  };
}

/** Average per-pixel change between two same-size frames (0..255). */
export function meanAbsDiff(a: Uint8Array, b: Uint8Array): number {
  if (a.length !== b.length || a.length === 0) return 255;
  let sum = 0;
  for (let i = 0; i < a.length; i += 1) sum += Math.abs(a[i] - b[i]);
  return sum / a.length;
}

/** Focus measure: variance of the 4-neighbour Laplacian inside the box. */
export function sharpness(gray: Uint8Array, width: number, height: number, box: Box): number {
  const x0 = Math.max(1, Math.floor(box.x * width));
  const y0 = Math.max(1, Math.floor(box.y * height));
  const x1 = Math.min(width - 2, Math.ceil((box.x + box.w) * width) - 1);
  const y1 = Math.min(height - 2, Math.ceil((box.y + box.h) * height) - 1);
  let n = 0;
  let sum = 0;
  let sumSq = 0;
  for (let y = y0; y <= y1; y += 1) {
    for (let x = x0; x <= x1; x += 1) {
      const i = y * width + x;
      const lap = 4 * gray[i] - gray[i - 1] - gray[i + 1] - gray[i - width] - gray[i + width];
      sum += lap;
      sumSq += lap * lap;
      n += 1;
    }
  }
  if (n === 0) return 0;
  const mean = sum / n;
  return sumSq / n - mean * mean;
}

function boxShift(a: Box, b: Box): number {
  return Math.max(Math.abs(a.x - b.x), Math.abs(a.y - b.y), Math.abs(a.x + a.w - b.x - b.w), Math.abs(a.y + a.h - b.y - b.h));
}

export type AutoCaptureStatus =
  | "searching" // no page in view
  | "steadying" // page found, counting down while it stays still
  | "blurry" // page found and still, but out of focus
  | "capture" // take the picture now (returned once per page)
  | "next"; // just captured; waiting for the page to change before arming again

export type AutoCaptureResult = { status: AutoCaptureStatus; box: Box | null; progress: number };

export type AutoCaptureOptions = {
  steadyMs?: number; // how long the page must stay still
  maxFrameDiff?: number; // "still" = frame-to-frame change below this
  maxBoxShift?: number; // and the page box moves less than this (fraction of frame)
  minSharpness?: number;
  rearmDiff?: number; // after a capture, the view must change this much before the next one
};

export class AutoCaptureTracker {
  private readonly o: Required<AutoCaptureOptions>;
  private prev: Uint8Array | null = null;
  private prevBox: Box | null = null;
  private steadySince: number | null = null;
  private captured: Uint8Array | null = null;

  constructor(options: AutoCaptureOptions = {}) {
    this.o = { steadyMs: 1000, maxFrameDiff: 6, maxBoxShift: 0.03, minSharpness: 40, rearmDiff: 14, ...options };
  }

  reset() {
    this.prev = null;
    this.prevBox = null;
    this.steadySince = null;
    this.captured = null;
  }

  feed(gray: Uint8Array, width: number, height: number, nowMs: number): AutoCaptureResult {
    const { box } = detectPage(gray, width, height);
    const prev = this.prev;
    const prevBox = this.prevBox;
    this.prev = gray;
    this.prevBox = box;

    if (this.captured) {
      // Wait for the driver to move on (turn the page / pull the paper away)
      // so the same page isn't captured twice.
      if (!box || meanAbsDiff(gray, this.captured) > this.o.rearmDiff) {
        this.captured = null;
        this.steadySince = null;
      } else {
        return { status: "next", box, progress: 0 };
      }
    }

    if (!box) {
      this.steadySince = null;
      return { status: "searching", box: null, progress: 0 };
    }

    const still = prev !== null && prevBox !== null && meanAbsDiff(gray, prev) <= this.o.maxFrameDiff && boxShift(box, prevBox) <= this.o.maxBoxShift;
    if (!still) {
      this.steadySince = null;
      return { status: "steadying", box, progress: 0 };
    }
    // Measured a little inside the box so the page's own edge (paper vs.
    // background) doesn't count as "detail".
    if (sharpness(gray, width, height, padBox(box, -0.03)) < this.o.minSharpness) {
      this.steadySince = null;
      return { status: "blurry", box, progress: 0 };
    }

    this.steadySince ??= nowMs;
    const progress = Math.min(1, (nowMs - this.steadySince) / this.o.steadyMs);
    if (progress < 1) return { status: "steadying", box, progress };

    this.captured = gray;
    this.steadySince = null;
    return { status: "capture", box, progress: 1 };
  }
}

/** Box grown by `margin` (fraction of the frame) on every side, clamped to the frame. */
export function padBox(box: Box, margin = 0.02): Box {
  const x = Math.max(0, box.x - margin);
  const y = Math.max(0, box.y - margin);
  return { x, y, w: Math.min(1, box.x + box.w + margin) - x, h: Math.min(1, box.y + box.h + margin) - y };
}
