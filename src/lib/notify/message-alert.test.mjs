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

test("staff app: every page chimes for new driver messages (dispatch roles only) and new bell notifications (every staff role)", () => {
  const layout = src("../../app/(app)/layout.tsx");
  assert.match(layout, /<MessageAlertWatcher \/>/);
  assert.ok(!/&& <MessageAlertWatcher/.test(layout), "mounted for every staff role");
  assert.match(layout, /showMessageSound /);
  const watcher = src("../../components/notify/message-alert-watcher.tsx");
  assert.match(watcher, /decideMessageAlert\(messageBaseline\.current, message\)/);
  assert.match(watcher, /decideMessageAlert\(notificationBaseline\.current, notification\)/);
  assert.match(watcher, /if \(m\.chime \|\| n\.chime\) playMessageChime\(\)/);
  assert.match(watcher, /router\.refresh\(\)/);
  const action = src("../../app/(app)/dispatch/message-alert-actions.ts");
  assert.match(action, /\.eq\("sender_type", "driver"\)/);
  assert.match(action, /\["owner", "admin", "dispatcher"\]/);
  // the bell: only the caller's own unread notifications, driver messages excluded (no double chime)
  assert.match(action, /\.eq\("profile_id", user\.id\)\.is\("read_at", null\)\.neq\("type", "dispatch_message"\)/);
});

test("sound resumes in Safari after sleep / background (\"interrupted\" state), not only from \"suspended\"", () => {
  const chime = src("./message-chime.ts");
  assert.match(chime, /a\.state !== "running"\) a\.resume\(\)/);
  assert.match(chime, /\(a\.state as string\) !== "running"\) a\.resume\(\)/);
  assert.ok(!/state === "suspended"/.test(chime));
  assert.match(chime, /"visibilitychange"/);
});

test("driver portal: the bottom nav chimes on every screen for new dispatch messages", () => {
  const nav = src("../../components/driver-portal/bottom-nav.tsx");
  assert.match(nav, /getMyPortalAlerts\(\)/);
  assert.match(nav, /decideMessageAlert\(chimeBaseline\.current, messages\)/);
  assert.match(nav, /else if \(message\.chime\) playMessageChime\(\)/);
  const actions = src("../../app/driver-portal/actions.ts");
  assert.match(actions, /export async function getMyUnreadMessageStatus[\s\S]*?\.eq\("sender_type", "staff"\)/);
  assert.match(src("../../app/driver-portal/messages/page.tsx"), /<MessageSoundToggle/);
});

test("driver portal: a rejected POD plays its own, different alert and shows a fix-it banner", () => {
  const nav = src("../../components/driver-portal/bottom-nav.tsx");
  assert.match(nav, /decideMessageAlert\(rejectBaseline\.current, \{ count: rejected \? 1 : 0, latestAt: rejected\?\.rejectedAt \?\? null \}\)/);
  assert.match(nav, /if \(reject\.chime\) playRejectedAlert\(\);/);
  assert.match(nav, /Proof of Delivery rejected/);
  assert.match(nav, /href="\/driver-portal\/documents"/);
  const actions = src("../../app/driver-portal/actions.ts");
  // only while the LATEST POD is rejected -- a re-upload clears it
  assert.match(actions, /getLatestDocument\(supabase, "load", dispatch\.load_id, "pod"\)/);
  assert.match(actions, /pod && pod\.rejected_at && !pod\.is_verified/);
  const chime = src("./message-chime.ts");
  assert.match(chime, /export function playRejectedAlert/);
});

test("a new rejection alerts once; the same rejection doesn't repeat; a re-rejection alerts again", () => {
  const T0 = "2026-10-01T15:00:00.000Z";
  const T1 = "2026-10-01T15:30:00.000Z";
  assert.deepEqual(decideMessageAlert(null, { count: 1, latestAt: T0 }), { chime: true, baseline: T0 });
  assert.deepEqual(decideMessageAlert(T0, { count: 1, latestAt: T0 }), { chime: false, baseline: T0 });
  assert.deepEqual(decideMessageAlert(T0, { count: 0, latestAt: null }), { chime: false, baseline: T0 });
  assert.deepEqual(decideMessageAlert(T0, { count: 1, latestAt: T1 }), { chime: true, baseline: T1 });
});

test("in the background (another tab / app) the alert also goes out as a system notification", () => {
  const watcher = src("../../components/notify/message-alert-watcher.tsx");
  assert.match(watcher, /const away = pageInBackground\(\)/);
  assert.match(watcher, /if \(away\) showDesktopAlert\(`New message from/);
  assert.match(watcher, /if \(away\) showDesktopAlert\(notification\.latest\.title/);
  assert.match(watcher, /addEventListener\("visibilitychange", onVisible\)/);
  const lib = src("./desktop-alert.ts");
  assert.match(lib, /if \(desktopAlertState\(\) !== "granted"\) return;/);
  assert.match(lib, /document\.visibilityState !== "visible" \|\| !document\.hasFocus\(\)/);
  const toggle = src("../../components/notify/desktop-alert-toggle.tsx");
  assert.match(toggle, /onClick=\{enable\}/, "permission is asked from a click (Safari requires it)");
  assert.match(src("../../components/desktop/status-bar.tsx"), /<DesktopAlertToggle \/>/);
});
