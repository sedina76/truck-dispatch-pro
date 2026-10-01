// Branded "call to action" emails (invitations, portal access). Pure -- no
// server-only, no provider -- so the exact HTML/text that gets sent can be
// rendered and checked in tests.
//
// Why: invitation emails used to be plain text ending in a raw 64-character
// secure link, which recipients found confusing. These render a clear
// button instead, keep the long link only as a small "button not working?"
// fallback, and give the plain-text version (for text-only mail apps) the
// same clean structure.
//
// Email-client-safe HTML only: tables, inline styles, no external images,
// fonts or scripts. Every dynamic value is HTML-escaped.

export type EmailLayout = {
  heading: string;
  /** Hidden one-line summary most inboxes show next to the subject. */
  preheader?: string;
  greeting?: string;
  intro: string[];
  action?: { label: string; url: string };
  /** Small grey line right under the button, e.g. "Link expires in 14 days." */
  actionNote?: string;
  checklist?: { title: string; items: string[] };
  /** Boxed label/value rows, e.g. sign-in phone + PIN. */
  details?: { label: string; value: string }[];
  outro?: string[];
  footnote?: string;
};

const ACCENT = "#1c54b8";
const INK = "#14202e";
const TEXT = "#3e4c5f";
const MUTED = "#6b7a90";
const BORDER = "#dde3ec";
const FONT = "-apple-system,BlinkMacSystemFont,'Segoe UI',Helvetica,Arial,sans-serif";

export function escapeHtml(s: string): string {
  return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;").replace(/'/g, "&#39;");
}

// Only http(s) links ever become an href.
function safeUrl(url: string): string {
  return /^https?:\/\//i.test(url) ? url : "#";
}

export function renderEmailHtml(organizationName: string, layout: EmailLayout): string {
  const p = (t: string) => `<p style="margin:0 0 14px 0;font-size:15px;line-height:1.6;color:${TEXT};">${escapeHtml(t)}</p>`;
  const action = layout.action
    ? `<table role="presentation" cellpadding="0" cellspacing="0" style="margin:8px 0 6px 0;"><tr><td style="border-radius:8px;background:${ACCENT};">
<a href="${escapeHtml(safeUrl(layout.action.url))}" target="_blank" style="display:inline-block;padding:14px 28px;font-family:${FONT};font-size:16px;font-weight:600;color:#ffffff;text-decoration:none;border-radius:8px;">${escapeHtml(layout.action.label)}</a>
</td></tr></table>${layout.actionNote ? `<p style="margin:0 0 22px 0;font-size:13px;color:${MUTED};">${escapeHtml(layout.actionNote)}</p>` : ""}`
    : "";
  const details = layout.details?.length
    ? `<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin:6px 0 20px 0;border:1px solid ${BORDER};border-radius:8px;background:#f7f9fc;">${layout.details
        .map(
          (d) =>
            `<tr><td style="padding:10px 16px;font-size:13px;color:${MUTED};width:35%;">${escapeHtml(d.label)}</td><td style="padding:10px 16px;font-size:16px;font-weight:600;color:${INK};font-family:Menlo,Consolas,monospace;">${escapeHtml(d.value)}</td></tr>`
        )
        .join("")}</table>`
    : "";
  const checklist = layout.checklist?.items.length
    ? `<p style="margin:8px 0 8px 0;font-size:13px;font-weight:600;letter-spacing:.04em;text-transform:uppercase;color:${MUTED};">${escapeHtml(layout.checklist.title)}</p>
<table role="presentation" cellpadding="0" cellspacing="0" style="margin:0 0 18px 0;">${layout.checklist.items
        .map((i) => `<tr><td style="padding:3px 10px 3px 0;color:${ACCENT};font-size:15px;vertical-align:top;">&#10003;</td><td style="padding:3px 0;font-size:15px;color:${TEXT};">${escapeHtml(i)}</td></tr>`)
        .join("")}</table>`
    : "";
  const fallback = layout.action
    ? `<p style="margin:22px 0 0 0;padding-top:16px;border-top:1px solid ${BORDER};font-size:12px;line-height:1.5;color:${MUTED};">Button not working? Copy and paste this link into your browser:<br/><a href="${escapeHtml(safeUrl(layout.action.url))}" style="color:${MUTED};word-break:break-all;">${escapeHtml(layout.action.url)}</a></p>`
    : "";

  return `<!doctype html>
<html>
<head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>${escapeHtml(layout.heading)}</title></head>
<body style="margin:0;padding:0;background:#eef2f7;font-family:${FONT};color:${INK};">
${layout.preheader ? `<div style="display:none;max-height:0;overflow:hidden;opacity:0;">${escapeHtml(layout.preheader)}</div>` : ""}
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#eef2f7;padding:28px 12px;">
<tr><td align="center">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:560px;background:#ffffff;border:1px solid ${BORDER};border-radius:12px;overflow:hidden;">
<tr><td style="background:${ACCENT};height:5px;font-size:0;line-height:0;">&nbsp;</td></tr>
<tr><td style="padding:28px 32px 32px 32px;font-family:${FONT};">
<p style="margin:0 0 6px 0;font-size:13px;font-weight:600;letter-spacing:.03em;color:${MUTED};">${escapeHtml(organizationName)}</p>
<h1 style="margin:0 0 20px 0;font-size:22px;line-height:1.3;font-weight:700;color:${INK};">${escapeHtml(layout.heading)}</h1>
${layout.greeting ? p(layout.greeting) : ""}${layout.intro.map(p).join("")}${details}${action}${checklist}${(layout.outro ?? []).map(p).join("")}${fallback}
</td></tr>
</table>
${layout.footnote ? `<p style="max-width:560px;margin:14px auto 0 auto;font-size:12px;line-height:1.5;color:${MUTED};text-align:center;">${escapeHtml(layout.footnote)}</p>` : ""}
</td></tr>
</table>
</body>
</html>`;
}

export function renderEmailText(layout: EmailLayout): string {
  const parts: string[] = [];
  if (layout.greeting) parts.push(layout.greeting);
  parts.push(...layout.intro);
  if (layout.details?.length) parts.push(layout.details.map((d) => `${d.label}: ${d.value}`).join("\n"));
  if (layout.action) parts.push(`${layout.action.label}:\n${layout.action.url}` + (layout.actionNote ? `\n(${layout.actionNote})` : ""));
  if (layout.checklist?.items.length) parts.push(`${layout.checklist.title}:\n${layout.checklist.items.map((i) => `- ${i}`).join("\n")}`);
  if (layout.outro?.length) parts.push(...layout.outro);
  if (layout.footnote) parts.push(layout.footnote);
  return parts.join("\n\n");
}

// ---- The invitation / access emails ------------------------------------------

type Built = { subject: string; text: string; layout: EmailLayout };

function build(subject: string, layout: EmailLayout): Built {
  return { subject, text: renderEmailText(layout), layout };
}

const firstWord = (name: string | null | undefined) => (name ?? "").trim().split(/\s+/)[0] || "";

export function carrierInvitationEmail(o: { orgName: string; contactName: string | null; url: string; expiresInDays: number; resend?: boolean }): Built {
  const hi = firstWord(o.contactName);
  return build(o.resend ? `Your new carrier setup link from ${o.orgName}` : `${o.orgName} invited you to set up as a carrier`, {
    heading: o.resend ? "Here's your new setup link" : "Let's get you set up as a carrier",
    preheader: `Complete your carrier setup with ${o.orgName} online.`,
    greeting: hi ? `Hi ${hi},` : "Hello,",
    intro: [
      o.resend
        ? `Here's a fresh link to finish your carrier setup with ${o.orgName}. Any earlier link we sent no longer works.`
        : `${o.orgName} would like to work with you. Please complete your carrier setup online so we can start booking loads with you.`,
    ],
    action: { label: "Start carrier setup", url: o.url },
    actionNote: `This secure link is just for you and expires in ${o.expiresInDays} days.`,
    checklist: { title: "Have these ready", items: ["W-9", "Certificate of Insurance", "Operating authority (MC/DOT)", "Voided check for payments"] },
    outro: [`Questions? Contact ${o.orgName} directly.`],
    footnote: `You're receiving this because ${o.orgName} invited you to set up as a carrier. If you weren't expecting it, you can ignore this email.`,
  });
}

export function driverInvitationEmail(o: { carrierName: string; firstName: string | null; url: string; expiresInDays: number; resend?: boolean }): Built {
  const hi = firstWord(o.firstName);
  return build(o.resend ? `Your new driver onboarding link from ${o.carrierName}` : `${o.carrierName} invited you to drive with them`, {
    heading: o.resend ? "Here's your new onboarding link" : "Welcome! Let's get you on the road",
    preheader: `Complete your driver onboarding with ${o.carrierName} from your phone.`,
    greeting: hi ? `Hi ${hi},` : "Hello,",
    intro: [
      o.resend
        ? `Here's a fresh link to finish your driver onboarding with ${o.carrierName}. Any earlier link we sent no longer works.`
        : `${o.carrierName} would like to bring you on as a driver. You can complete your onboarding right from your phone.`,
    ],
    action: { label: "Start driver onboarding", url: o.url },
    actionNote: `This secure link is just for you and expires in ${o.expiresInDays} days.`,
    checklist: { title: "Have these ready", items: ["Your CDL", "Your DOT medical card", "Recent employment history"] },
    outro: [`Questions? Contact ${o.carrierName} directly.`],
    footnote: `You're receiving this because ${o.carrierName} invited you to complete driver onboarding. If you weren't expecting it, you can ignore this email.`,
  });
}

export function driverPortalAccessEmail(o: { orgName: string; firstName: string | null; phone: string; pin: string; portalUrl: string }): Built {
  const hi = firstWord(o.firstName);
  return build(`Your Driver Portal sign-in for ${o.orgName}`, {
    heading: "You're all set — welcome aboard!",
    preheader: "Your Driver Portal phone number and PIN are inside.",
    greeting: hi ? `Hi ${hi},` : "Hello,",
    intro: ["You can now use the Driver Portal to see your trips, message dispatch, and upload documents. Sign in with:"],
    details: [
      { label: "Phone", value: o.phone },
      { label: "PIN", value: o.pin },
    ],
    action: { label: "Open the Driver Portal", url: o.portalUrl },
    actionNote: "Tip: after it opens, add it to your phone's home screen for one-tap access.",
    outro: ["Keep your PIN private — it's how you sign in to your account."],
    footnote: `Sent by ${o.orgName}.`,
  });
}
