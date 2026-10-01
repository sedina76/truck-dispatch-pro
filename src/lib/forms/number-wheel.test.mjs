// Number fields change only when typed (load rate 7500 -> 7499.31 bug).
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { keyWouldStepNumber, wheelWouldChangeNumber } from "./number-wheel.ts";

const num = { tagName: "INPUT", type: "number" };
const txt = { tagName: "INPUT", type: "text" };

test("wheel: guards only a focused number input", () => {
  assert.equal(wheelWouldChangeNumber(num, num), true);
  assert.equal(wheelWouldChangeNumber(num, {}), false);
  assert.equal(wheelWouldChangeNumber(txt, txt), false);
  assert.equal(wheelWouldChangeNumber(null, null), false);
});

test("keys: arrow/page up-down are blocked on number inputs only", () => {
  for (const k of ["ArrowUp", "ArrowDown", "PageUp", "PageDown"]) assert.equal(keyWouldStepNumber(num, k), true, k);
  for (const k of ["1", "Backspace", "Tab", ".", "ArrowLeft", "ArrowRight", "Enter"]) assert.equal(keyWouldStepNumber(num, k), false, k);
  assert.equal(keyWouldStepNumber(txt, "ArrowDown"), false);
  assert.equal(keyWouldStepNumber({ tagName: "SELECT" }, "ArrowDown"), false);
});

test("guard is mounted app-wide; spinners hidden", () => {
  const layout = readFileSync(new URL("../../app/layout.tsx", import.meta.url), "utf8");
  assert.match(layout, /<NumberWheelGuard \/>/);
  const guard = readFileSync(new URL("../../components/ui/number-wheel-guard.tsx", import.meta.url), "utf8");
  assert.match(guard, /"use client"/);
  assert.match(guard, /addEventListener\("wheel", onWheel, \{ capture: true, passive: true \}\)/);
  assert.match(guard, /addEventListener\("keydown", onKeyDown, \{ capture: true \}\)/);
  const css = readFileSync(new URL("../../app/globals.css", import.meta.url), "utf8");
  assert.match(css, /::-webkit-inner-spin-button/);
  assert.match(css, /appearance: textfield/);
});
