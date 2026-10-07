// Hands-free scanning: page detection + "steady and sharp -> capture" logic
// on synthetic camera frames.
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { detectPage, AutoCaptureTracker, sharpness, padBox, grayFromRgba } from "./auto-capture.ts";

const W = 160;
const H = 120;

// Dark desk + noise, a white sheet with dark "text" lines at (px,py,pw,ph) (fractions).
function frame({ px = 0.2, py = 0.15, pw = 0.5, ph = 0.7, page = true, text = true, seed = 1, bg = 55, smear = false } = {}) {
  let s = seed;
  const rnd = () => ((s = (s * 16807) % 2147483647) / 2147483647);
  const g = new Uint8Array(W * H);
  for (let y = 0; y < H; y += 1) {
    for (let x = 0; x < W; x += 1) {
      let v = bg + rnd() * 12;
      const inPage = page && x >= px * W && x < (px + pw) * W && y >= py * H && y < (py + ph) * H;
      if (inPage) {
        v = smear ? 228 : 225 + rnd() * 6; // smear: no detail at all (heavy motion blur)
        const ly = y - py * H;
        if (text && ly > 6 && ly % 6 < 2 && x > px * W + 4 && x < (px + pw) * W - 4) v = 40;
      }
      g[y * W + x] = v;
    }
  }
  return g;
}

test("finds the sheet of paper and its box", () => {
  const { box, contrast } = detectPage(frame(), W, H);
  assert.ok(box, "page found");
  assert.ok(Math.abs(box.x - 0.2) < 0.03 && Math.abs(box.y - 0.15) < 0.03, JSON.stringify(box));
  assert.ok(Math.abs(box.w - 0.5) < 0.04 && Math.abs(box.h - 0.7) < 0.04, JSON.stringify(box));
  assert.ok(contrast > 100);
});

test("a densely printed page is still found whole", () => {
  // heavy text: dark lines every 3 rows, 2 rows thick, almost edge to edge
  const g = new Uint8Array(W * H).fill(50);
  for (let y = 12; y < 108; y += 1) for (let x = 40; x < 120; x += 1) g[y * W + x] = (y - 12) % 3 < 2 && x > 43 && x < 116 ? 35 : 230;
  const { box } = detectPage(g, W, H);
  assert.ok(box, "found");
  assert.ok(box.h > 0.75 && box.w > 0.45, JSON.stringify(box));
});

test("no paper in view -> no page", () => {
  assert.equal(detectPage(frame({ page: false }), W, H).box, null);
  assert.equal(detectPage(frame({ pw: 0.1, ph: 0.1 }), W, H).box, null, "a scrap too small to be the page");
  assert.equal(detectPage(new Uint8Array(W * H).fill(20), W, H).box, null, "dark frame (lens covered)");
});

test("a page filling the whole frame still counts", () => {
  const r = detectPage(frame({ px: 0, py: 0, pw: 1, ph: 1 }), W, H);
  assert.ok(r.box && r.fillsFrame);
});

function boxBlur(g, r) {
  const o = new Uint8Array(g.length);
  for (let y = 0; y < H; y += 1) for (let x = 0; x < W; x += 1) {
    let s = 0, n = 0;
    for (let dy = -r; dy <= r; dy += 1) for (let dx = -r; dx <= r; dx += 1) {
      const yy = y + dy, xx = x + dx;
      if (yy >= 0 && yy < H && xx >= 0 && xx < W) { s += g[yy * W + xx]; n += 1; }
    }
    o[y * W + x] = Math.round(s / n);
  }
  return o;
}

test("focus measure: crisp text scores far above blurred text and a smear", () => {
  const box = { x: 0.2, y: 0.15, w: 0.5, h: 0.7 };
  const crisp = sharpness(frame(), W, H, box);
  assert.ok(crisp > 10 * sharpness(boxBlur(frame(), 3), W, H, box), "blur drops the score by 10x+");
  assert.ok(sharpness(frame({ text: false, smear: true }), W, H, padBox(box, -0.05)) < 40);
});

test("captures once the page is held steady for a second -- no button", () => {
  const t = new AutoCaptureTracker();
  const statuses = [];
  for (let ms = 0; ms <= 1500; ms += 125) statuses.push(t.feed(frame({ seed: 7 }), W, H, ms).status);
  assert.equal(statuses[0], "steadying");
  assert.equal(statuses.filter((s) => s === "capture").length, 1, statuses.join(","));
  assert.ok(statuses.indexOf("capture") >= 8, "not before ~1s of stillness");
  assert.equal(statuses.at(-1), "next", "the same page is not captured again");
});

test("a moving page never captures", () => {
  const t = new AutoCaptureTracker();
  for (let i = 0, ms = 0; i < 20; i += 1, ms += 125) {
    const r = t.feed(frame({ px: 0.1 + (i % 2) * 0.1 }), W, H, ms);
    assert.notEqual(r.status, "capture");
  }
});

test("blurry page waits instead of capturing", () => {
  const t = new AutoCaptureTracker();
  let last;
  for (let ms = 0; ms <= 2000; ms += 125) last = t.feed(frame({ text: false, smear: true, bg: 50, seed: 3 }), W, H, ms);
  assert.equal(last.status, "blurry");
});

test("turning to the next page arms the next capture (multi-page)", () => {
  const t = new AutoCaptureTracker();
  let ms = 0;
  const run = (f, n) => { let caps = 0; for (let i = 0; i < n; i += 1, ms += 125) if (t.feed(f, W, H, ms).status === "capture") caps += 1; return caps; };
  assert.equal(run(frame({ seed: 5 }), 14), 1, "page 1");
  assert.equal(run(frame({ page: false }), 3), 0, "paper pulled away");
  assert.equal(run(frame({ seed: 9, px: 0.25, py: 0.12 }), 14), 1, "page 2");
});

test("RGBA -> gray", () => {
  const g = grayFromRgba(new Uint8ClampedArray([255, 255, 255, 255, 0, 0, 0, 255]), 2, 1);
  assert.deepEqual([...g], [255, 0]);
});

test("scanner opens a live camera with auto-capture and keeps the old way as a fallback", () => {
  const scanner = readFileSync(new URL("../../components/documents/document-scanner.tsx", import.meta.url), "utf8");
  const live = readFileSync(new URL("../../components/documents/live-capture.tsx", import.meta.url), "utf8");
  assert.match(scanner, /<LiveCapture/);
  assert.match(scanner, /onUnavailable=\{setLiveUnavailable\}/, "falls back when the live camera can't open");
  assert.match(scanner, /capture="environment"/, "phone camera app still available");
  assert.match(live, /getUserMedia\(/);
  assert.match(live, /new AutoCaptureTracker\(\)/);
  assert.match(live, /r\.status === "capture" && autoRef\.current/, "captures by itself when Auto is on");
  assert.match(live, /getTracks\(\)\.forEach\(\(t\) => t\.stop\(\)\)/, "camera is switched off when not scanning");
  assert.match(live, /playsInline/, "iPhone plays the preview inline");
});
