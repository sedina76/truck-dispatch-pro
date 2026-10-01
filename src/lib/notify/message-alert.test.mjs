// New-message chime: when it plays, and that both sides are wired to it.

import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { decideMessageAlert, soundEnabledFromStorage } from "./message-alert.ts";

const T1 = "2026-10-01T14:00:00.000Z";
const T2 = "2026-10-01T14:05:00.000Z";

test("first check after page load never chimes for messages that were already unread", () => {
  assert.deepEqual(decideMessageAlert(undefined, { count: 3, latestAt: T1 }), { chime: false, baseline: T1 });
  assert.deepEqual(decideMessageAlert(undefined, { count: 0, latestAt: null }), { chime: false, baseline: null });
});

test("a newer unread message chimes exactly once", () => {
  const first = decideMessageAlert(T1, { count: 4, latestAt: T2 });
  assert.deepEqual(first, { chime: true, baseline: T2 });
  assert.deepEqual(decideMessageAlert(first.baseline, { count: 4, latestAt: T2 }), { chime: false, baseline: T2 });
});

test("a message arriving when nothing was unread chimes", () => {
  assert.deepEqual(decideMessageAlert(null, { count: 1, latestAt: T1 }), { chime: true, baseline: T1 });
});

test("reading messages (count drops to 0) never chimes and keeps the baseline", () => {
  assert.deepEqual(decideMessageAlert(T2, { count: 0, latestAt: null }), { chime: false, baseline: T2 });
  // an older message still unread after newer ones were read: no chime
  assert.deepEqual(decideMessageAlert(T2, { count: 1, latestAt: T1 }), { chime: false, baseline: T2 });
});

test("sound is on by default; only an explicit 'off' mutes", () => {
  assert.equal(soundEnabledFromStorage(null), true);
  assert.equal(soundEnabledFromStorage(undefined), true);
  assert.equal(soundEnabledFromStorage("on"), true);
  assert.equal(soundEnabledFromStorage("off"), false);
});

const src = (p) => readFileSync(new URL(p, import.meta.url), "utf8");

test("staff app: every page of the app watches for driver messages (dispatch roles only)", () => {
  const layout = src("../../app/(app)/layout.tsx");
  assert.match(layout, /\["owner", "admin", "dispatcher"\]\.includes\(profile\.role\)/);
  assert.match(layout, /\{handlesDriverMessages && <MessageAlertWatcher \/>\}/);
  assert.match(layout, /showMessageSound=\{handlesDriverMessages\}/);
  const watcher = src("../../components/notify/message-alert-watcher.tsx");
  assert.match(watcher, /decideMessageAlert\(baseline\.current, alert\)/);
  assert.match(watcher, /playMessageChime\(\)/);
  const action = src("../../app/(app)/dispatch/message-alert-actions.ts");
  assert.match(action, /\.eq\("sender_type", "driver"\)/);
  assert.match(action, /\["owner", "admin", "dispatcher"\]/);
});

test("driver portal: the bottom nav chimes on every screen for new dispatch messages", () => {
  const nav = src("../../components/driver-portal/bottom-nav.tsx");
  assert.match(nav, /getMyUnreadMessageStatus\(\)/);
  assert.match(nav, /decideMessageAlert\(chimeBaseline\.current, status\)/);
  assert.match(nav, /if \(decision\.chime\) playMessageChime\(\)/);
  const actions = src("../../app/driver-portal/actions.ts");
  assert.match(actions, /export async function getMyUnreadMessageStatus[\s\S]*?\.eq\("sender_type", "staff"\)/);
  assert.match(src("../../app/driver-portal/messages/page.tsx"), /<MessageSoundToggle/);
});
