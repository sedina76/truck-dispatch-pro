import { createClient } from "@/lib/supabase/server";
import { getCurrentOrgId } from "@/lib/actions/records";
import { SectionHeading } from "@/components/ui/section-heading";
import { EmailDomainsSection, EmailSendersSection, AddDomainForm } from "./email-settings-client";

export type DomainRow = {
  id: string;
  domain: string;
  sending_domain: string;
  status: string;
  // Spec review item 2 -- the actual sending-authorization signal
  // (mirrors Resend's capabilities.sending), independent of `status`.
  sending_enabled: boolean;
  is_default: boolean;
  verified_at: string | null;
  disabled_at: string | null;
  dns_records: { record: string; type: string; name: string; value: string; ttl: string; priority?: number; status: string }[];
};

export type SenderRow = {
  id: string;
  email_domain_id: string;
  display_name: string;
  email_address: string;
  reply_to: string | null;
  sender_type: string;
  is_default: boolean;
  is_active: boolean;
};

// Spec section 58 -- graceful pre-migration behavior. 0064 hasn't been
// applied to the live database yet (this Phase 2F pass stops before that,
// per the standing instruction); every other page in this app must keep
// working regardless, and THIS page must show a controlled message rather
// than crash with a raw "relation does not exist" 500.
export default async function EmailSettingsPage() {
  const supabase = await createClient();
  const orgId = await getCurrentOrgId();

  const {
    data: { user },
  } = await supabase.auth.getUser();
  const { data: profile } = await supabase.from("profiles").select("role").eq("id", user!.id).maybeSingle();
  const isAdmin = profile?.role === "owner" || profile?.role === "admin";

  const [domainsRes, sendersRes] = await Promise.all([
    supabase.from("organization_email_domains").select("*").eq("organization_id", orgId).order("created_at", { ascending: false }),
    supabase.from("organization_email_senders").select("*").eq("organization_id", orgId).order("created_at", { ascending: false }),
  ]);

  // A missing table surfaces as a PostgREST error with this code
  // (undefined_table / PGRST205-style "not found in schema cache") rather
  // than throwing -- Supabase's client never throws on a query error, it
  // returns { error }, so this is a plain, safe check, not a try/catch
  // around something that could crash the render.
  const migrationNotApplied = Boolean(domainsRes.error) || Boolean(sendersRes.error);

  if (migrationNotApplied) {
    return (
      <div className="space-y-4">
        <SectionHeading title="Email & Sending Domain" description="Configure your organization's business sending domain and sender identities." />
        <div className="rounded-md border border-dashed border-[var(--color-border)] bg-[var(--color-muted)]/30 p-6 text-sm text-[var(--color-text-muted)]">
          Email settings database migration has not been applied yet. This page will become available once it is. Everything else in Truck Dispatch Pro
          (invoicing, dispatch, tracking, driver portal) continues to work normally.
        </div>
      </div>
    );
  }

  const domains = (domainsRes.data ?? []) as DomainRow[];
  const senders = (sendersRes.data ?? []) as SenderRow[];
  // Gate on sending_enabled (spec review item 2), not `status` -- and
  // check disabled_at's actual VALUE, not merely whether the key exists
  // on the row (a select("*") result always has the key; the earlier
  // `!("disabled_at" in d)` was always true regardless of whether the
  // domain was actually disabled -- found while wiring this up).
  const verifiedDomains = domains.filter((d) => d.sending_enabled && !d.disabled_at);

  return (
    <div className="space-y-6">
      <SectionHeading
        title="Email & Sending Domain"
        description={
          isAdmin
            ? "Business email (invoices, billing packets, statements) sends from your own verified domain when one is configured. Without one, it sends via Truck Dispatch Pro's platform address, branded with your company name."
            : "Only an owner or admin can manage sending domains."
        }
      />

      {isAdmin && <AddDomainForm />}
      <EmailDomainsSection domains={domains} isAdmin={isAdmin} />
      <EmailSendersSection senders={senders} verifiedDomains={verifiedDomains} isAdmin={isAdmin} />
    </div>
  );
}
