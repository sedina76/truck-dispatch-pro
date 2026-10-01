// Dispatch board "Quick note": writes dispatch_internal_notes, never the dropped dispatches.notes column.
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { appendNoteLine } from "./internal-notes.ts";

const BOARD = readFileSync(new URL("../../app/(app)/dispatch/board-actions.ts", import.meta.url), "utf8");

test("appendNoteLine starts a new note or appends on a new line", () => {
  assert.equal(appendNoteLine(null, "[t] a"), "[t] a");
  assert.equal(appendNoteLine("", "[t] a"), "[t] a");
  assert.equal(appendNoteLine("   ", "[t] a"), "[t] a");
  assert.equal(appendNoteLine("[t] a", "[t] b"), "[t] a\n[t] b");
});

test("quick note reads and writes dispatch_internal_notes, not dispatches.notes", () => {
  const fn = BOARD.slice(BOARD.indexOf("export async function addDispatchQuickNote"));
  const body = fn.slice(0, fn.indexOf("\nexport async function", 10) === -1 ? undefined : fn.indexOf("\nexport async function", 10));
  assert.match(body, /from\("dispatch_internal_notes"\)\s*\.select\("notes"\)/);
  assert.match(body, /\.from\("dispatch_internal_notes"\)\s*\.upsert\(/);
  assert.match(body, /onConflict: "dispatch_id"/);
  assert.doesNotMatch(body, /from\("dispatches"\)\.select\("id, notes"\)/);
  assert.doesNotMatch(body, /from\("dispatches"\)\.update\(\{ notes/);
});

test("no app code reads or writes the dropped dispatches.notes column", () => {
  assert.doesNotMatch(BOARD, /from\("dispatches"\)[^;]*\bnotes\b/);
});
