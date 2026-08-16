# Email Setup (Resend)

Truck Dispatch Pro sends transactional email (Invoice, Payment Receipt,
Carrier Settlement, Driver Settlement, Statement, Profile Sharing) through
[Resend](https://resend.com). Until it's configured, every send is honestly
blocked with "Email provider not configured." -- nothing is ever faked as
sent.

## 1. Create a Resend account

Sign up at [resend.com](https://resend.com).

## 2. Add a sending domain

In the Resend dashboard: **Domains → Add Domain**, enter the domain you'll
send from (e.g. `yourdomain.com`).

## 3. Add the SPF/DKIM DNS records

Resend shows you a small set of DNS records (SPF `TXT`, DKIM `CNAME`
entries, optionally a `DMARC` record) to add at your domain registrar/DNS
host. Add them exactly as shown.

## 4. Wait for domain verification

Verification is usually fast (minutes) but DNS propagation can take longer.
The domain's status in Resend must show **Verified** before sending from an
address on that domain will work reliably -- unverified domains are likely
to have mail rejected or spam-filtered by recipients.

## 5. Create an API key

**API Keys → Create API Key**. Sending permission is enough; it doesn't need
domain/account admin access.

## 6. Set environment variables

Server-only -- never exposed to the browser. Add to `.env.local` (see
`.env.local.example`):

```
RESEND_API_KEY=re_xxxxxxxxx
EMAIL_FROM=Truck Dispatch Pro <billing@yourdomain.com>
EMAIL_REPLY_TO=accounts@yourdomain.com
```

- `RESEND_API_KEY` -- from step 5.
- `EMAIL_FROM` -- must be an address on the domain you verified in step 4.
  The app never lets a form field control this.
- `EMAIL_REPLY_TO` -- optional. Used when an organization has no validated
  reply-to of its own.

The app treats the provider as configured only when **both**
`RESEND_API_KEY` and `EMAIL_FROM` are set (`src/lib/email/provider.ts`). If
either is missing, sending stays blocked with the same honest error as
before -- this is intentional, not a bug.

## 7. Restart the app

```
npm run kill-stale -- --yes   # if something is already on the port
npm start                     # or npm run dev
```

## Database migration

Run `supabase/migrations/0053_email_send_log_resend.sql` against your
Supabase project (SQL Editor, or your usual migration flow) before sending
any real email -- it makes `email_send_log.sent_at` nullable (so
blocked/failed attempts never get a fake timestamp) and adds
`provider_message_id` for tracing a successful send back to Resend's
dashboard.

## Verifying it worked

Open any Invoice/Payment/Carrier Settlement/Driver Settlement/Statement
detail page, click the toolbar's **Email** button, and send. A successful
send shows "Sent." in the dialog and a `status = sent` row appears in
`email_send_log` with a real `sent_at` and `provider_message_id`. Anything
else (still not configured, entity blocked, provider rejected it) shows a
plain-language reason and never marks the entity as sent.
