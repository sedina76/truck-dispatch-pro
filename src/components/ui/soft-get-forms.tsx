"use client";

import { useEffect } from "react";
import { useRouter } from "next/navigation";

/**
 * Where a plain GET form (a filter bar: method="GET", or no method) should go,
 * or null if the browser should handle it itself (another site, a new tab,
 * a file input, a POST, or a submit someone already handled).
 */
export function softGetFormUrl(form: HTMLFormElement, submitter: HTMLElement | null, origin: string): string | null {
  const s = submitter as (HTMLButtonElement | HTMLInputElement) | null;
  const method = (s?.getAttribute("formmethod") || form.getAttribute("method") || "get").toLowerCase();
  if (method !== "get") return null;
  const target = s?.getAttribute("formtarget") || form.getAttribute("target");
  if (target && target !== "_self") return null;
  const action = s?.getAttribute("formaction") || form.getAttribute("action") || "";
  if (action.startsWith("javascript:")) return null;
  let url: URL;
  try {
    url = new URL(action || window.location.href, window.location.href);
  } catch {
    return null;
  }
  if (url.origin !== origin) return null;
  const data = new FormData(form, s ?? undefined);
  const params = new URLSearchParams();
  for (const [k, v] of data.entries()) {
    if (typeof v !== "string") return null; // file inputs: leave to the browser
    params.append(k, v);
  }
  url.search = params.toString();
  url.hash = "";
  return url.pathname + url.search;
}

// Mounted once in the root layout. Filter bars are plain GET forms; a plain
// form submit reloads the whole page, and a full reload makes the browser
// leave full screen (and loses scroll position). This turns them into the
// same in-app navigation a link click does. Runs after every other submit
// handler (window, bubble phase) and never touches a submit already handled
// -- server-action forms, confirm prompts and POST forms are untouched.
export function SoftGetForms() {
  const router = useRouter();
  useEffect(() => {
    function onSubmit(e: SubmitEvent) {
      if (e.defaultPrevented) return;
      const form = e.target;
      if (!(form instanceof HTMLFormElement)) return;
      const href = softGetFormUrl(form, e.submitter, window.location.origin);
      if (!href) return;
      e.preventDefault();
      router.push(href);
    }
    window.addEventListener("submit", onSubmit);
    return () => window.removeEventListener("submit", onSubmit);
  }, [router]);
  return null;
}
