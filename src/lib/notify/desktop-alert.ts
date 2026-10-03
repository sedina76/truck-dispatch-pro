// Browser-only: Mac / Windows system notifications (the banner in the
// corner with the system sound) for new messages and notifications. They
// reach you while the TMS tab is in the background or you're in another
// app -- when the browser itself keeps a page's own sound paused (Safari)
// and slows its checks. Needs one-time permission, asked from a click.
// Every call is best-effort and never throws.

export type DesktopAlertState = "unsupported" | "default" | "granted" | "denied";

export function desktopAlertState(): DesktopAlertState {
  if (typeof window === "undefined" || !("Notification" in window)) return "unsupported";
  return Notification.permission as DesktopAlertState;
}

/** Must be called from a click (Safari only asks from a user gesture). */
export async function requestDesktopAlerts(): Promise<DesktopAlertState> {
  if (desktopAlertState() === "unsupported") return "unsupported";
  try {
    const result = await Notification.requestPermission();
    return result as DesktopAlertState;
  } catch {
    return desktopAlertState();
  }
}

/** True when the person is not looking at this tab (another tab, another app, minimized). */
export function pageInBackground(): boolean {
  if (typeof document === "undefined") return false;
  return document.visibilityState !== "visible" || !document.hasFocus();
}

/** Shows a system notification if allowed; clicking it brings the TMS tab forward (and opens `href` if given). */
export function showDesktopAlert(title: string, body: string, opts?: { tag?: string; href?: string }) {
  if (desktopAlertState() !== "granted") return;
  try {
    const n = new Notification(title, { body, tag: opts?.tag, silent: false });
    n.onclick = () => {
      try {
        window.focus();
        if (opts?.href) window.location.assign(opts.href);
      } catch {
        // nothing else to do
      }
      n.close();
    };
  } catch {
    // never let an alert problem surface to the user
  }
}
