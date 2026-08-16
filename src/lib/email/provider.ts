import "server-only";
import { Resend } from "resend";

// The ONE place that decides "is sending actually possible" and the ONE
// place that actually talks to the email provider (Resend). Every send
// path (toolbar Email /api/email/send, Billing Packet send, Profile
// Sharing send) imports from here -- never duplicated, never faked true.
//
// Configured only when RESEND_API_KEY AND EMAIL_FROM are both set. Missing
// either preserves the existing honest behavior everywhere: a 501 / "Email
// provider not configured." error, and an email_send_log row with
// status='blocked', never a faked 'sent'.
export const EMAIL_PROVIDER_CONFIGURED = Boolean(process.env.RESEND_API_KEY && process.env.EMAIL_FROM);

let _client: Resend | null = null;
function client(): Resend {
  if (!_client) _client = new Resend(process.env.RESEND_API_KEY);
  return _client;
}

export type EmailAttachment = {
  filename: string;
  /** Raw bytes -- never a URL. The caller already fetched/generated these from the existing, already-reviewed PDF source for that entity. */
  content: Uint8Array | Buffer;
};

export type SendTransactionalEmailArgs = {
  to: string;
  subject: string;
  /** Plain text body. A simple, safe HTML wrapper is generated from this -- see buildHtml() below, not a templating system. */
  text: string;
  /** Optional cc, e.g. from the toolbar Email dialog's CC field. */
  cc?: string;
  /**
   * Reply-To may only ever be the organization's own validated
   * business email or EMAIL_REPLY_TO -- never arbitrary client input (spec
   * section 18). Callers pass an already-validated address or omit it.
   */
  replyTo?: string;
  attachments?: EmailAttachment[];
  /** Shown in the HTML header ("Northbound Logistics"), never used for auth/routing. */
  organizationName: string;
  /** Shown as the HTML document title/heading, e.g. "Invoice INV-000021". */
  heading: string;
};

export type SendResult = { ok: true; providerMessageId: string | null } | { ok: false; error: string };

function escapeHtml(s: string): string {
  return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
}

// Simple, professional HTML wrapper around a plain-text body -- no
// templating engine, no external assets/CDN, matches spec section 17.
function buildHtml(organizationName: string, heading: string, text: string): string {
  const bodyHtml = escapeHtml(text)
    .split("\n\n")
    .map((para) => `<p style="margin:0 0 14px 0;">${para.split("\n").join("<br/>")}</p>`)
    .join("");
  return `<!doctype html>
<html>
  <body style="margin:0;padding:0;background:#f4f4f5;font-family:Helvetica,Arial,sans-serif;color:#111827;">
    <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f4f4f5;padding:24px 0;">
      <tr><td align="center">
        <table role="presentation" width="560" cellpadding="0" cellspacing="0" style="background:#ffffff;border:1px solid #e5e7eb;border-radius:8px;padding:32px;">
          <tr><td style="font-size:13px;color:#6b7280;font-weight:600;letter-spacing:.02em;padding-bottom:4px;">${escapeHtml(organizationName)}</td></tr>
          <tr><td style="font-size:19px;font-weight:700;color:#111827;padding-bottom:18px;">${escapeHtml(heading)}</td></tr>
          <tr><td style="font-size:14px;line-height:1.55;color:#1f2937;">${bodyHtml}</td></tr>
        </table>
      </td></tr>
    </table>
  </body>
</html>`;
}

// The one shared, provider-specific function. Every entity workflow calls
// this instead of talking to Resend directly (spec section 5) -- so
// swapping providers later, or adding retry/rate-limit logic, only ever
// touches this one file.
export async function sendTransactionalEmail(args: SendTransactionalEmailArgs): Promise<SendResult> {
  if (!EMAIL_PROVIDER_CONFIGURED) {
    return { ok: false, error: "Email provider not configured." };
  }

  const from = process.env.EMAIL_FROM!;
  const replyTo = args.replyTo || process.env.EMAIL_REPLY_TO || undefined;

  try {
    const { data, error } = await client().emails.send({
      from,
      to: args.to,
      cc: args.cc || undefined,
      replyTo,
      subject: args.subject,
      text: args.text,
      html: buildHtml(args.organizationName, args.heading, args.text),
      attachments: args.attachments?.map((a) => ({ filename: a.filename, content: Buffer.from(a.content) })),
    });

    if (error) {
      // Resend's own error object can carry provider-internal detail --
      // never forwarded to the browser (spec section 19); the audit log is
      // the one place the full message is kept.
      return { ok: false, error: error.message || "The email provider rejected this send." };
    }

    return { ok: true, providerMessageId: data?.id ?? null };
  } catch (err) {
    // Network/timeout/unexpected SDK failure -- same treatment, never a
    // raw stack trace or secret back to the browser.
    return { ok: false, error: err instanceof Error ? err.message : "The email provider could not be reached." };
  }
}

// User-facing error text (spec section 19) -- never the raw provider
// message, which is kept in email_send_log.error for support/diagnostics
// only.
export const FRIENDLY_SEND_ERROR = "Email could not be sent. Please try again.";
