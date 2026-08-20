import "server-only";
import { createClient } from "@/lib/supabase/server";
import { getBillingParty } from "@/lib/billing/party";
import { isPacketOutdated } from "@/app/(app)/invoices/billing-packet-actions";
import { checkPacketReadiness } from "@/lib/billing-packet/generate";

// Shared "who does this go to, what's the subject/body, what attachment,
// is it blocked" resolver -- used by BOTH /api/email/resolve (populates
// the compose dialog) AND /api/email/send (re-derives the authoritative
// answer server-side right before actually sending, rather than trusting
// whatever attachmentType/blocked state the client last saw -- a client
// could otherwise open the dialog, then race a draft->void or a document
// change, then POST straight to /send with a stale attachmentType). Every
// entity's own RLS-scoped query means an org-B caller passing an org-A
// entityId simply gets "not found" here -- no cross-org branch to get
// wrong.
export type EmailResolution = {
  to: string;
  subject: string;
  message: string;
  attachmentType: string;
  attachmentLabel: string;
  blocked: string | null;
  organizationName: string;
  /** Internal use only (send route's attachment lookup) -- stripped before /api/email/resolve returns its JSON. */
  numberLabel: string;
  packetStoragePath?: string;
  statementStoragePath?: string;
};

type Supabase = Awaited<ReturnType<typeof createClient>>;

export async function resolveEmailForEntity(entityType: string, entityId: string, supabase: Supabase): Promise<EmailResolution | { error: string; status: number }> {
  switch (entityType) {
    case "invoice": {
      const { data: invoice } = await supabase
        .from("invoices")
        .select(
          "id, invoice_number, load_id, bill_to_name, bill_to_email, total_amount, balance_due, due_date, status, broker_id, customer_id, loads(load_number), brokers(company_name, email), customers(company_name, email)"
        )
        .eq("id", entityId)
        .single();
      if (!invoice) return { error: "Invoice not found.", status: 404 };

      const inv = invoice as unknown as {
        invoice_number: string;
        load_id: string | null;
        bill_to_name: string;
        bill_to_email: string | null;
        total_amount: number;
        balance_due: number;
        due_date: string | null;
        status: string;
        broker_id: string | null;
        customer_id: string | null;
        loads: { load_number: string } | null;
        brokers: { company_name: string; email: string | null } | null;
        customers: { company_name: string; email: string | null } | null;
      };

      // Canonical recipient: the invoice's own frozen bill_to_email if set
      // (a snapshot, not a live re-read), else the canonical billing
      // party's current email. Never the driver/carrier -- neither is even
      // queried here.
      const party = getBillingParty(inv);
      const partyEmail = party.type === "broker" ? inv.brokers?.email : party.type === "customer" ? inv.customers?.email : null;
      const to = inv.bill_to_email || partyEmail || "";

      let attachmentType = "invoice_pdf";
      let attachmentLabel = `Invoice PDF (${inv.invoice_number})`;
      let blocked: string | null = null;

      const { data: packets } = await supabase
        .from("billing_packets")
        .select("id, document_snapshot, storage_path")
        .eq("invoice_id", entityId)
        .order("version", { ascending: false })
        .limit(1);
      const latestPacket = packets?.[0] ?? null;
      let packetStoragePath: string | undefined;
      if (latestPacket) {
        const outdated = await isPacketOutdated(inv.load_id, latestPacket.document_snapshot);
        if (outdated) {
          blocked = "The billing packet is outdated (source documents changed since it was generated). Regenerate it before sending.";
        } else {
          attachmentType = "billing_packet_pdf";
          attachmentLabel = `Billing Packet PDF (${inv.invoice_number})`;
          packetStoragePath = latestPacket.storage_path;
        }
      } else {
        // No packet yet -- the plain invoice PDF is still sendable as long
        // as the invoice itself isn't blocked below. checkPacketReadiness
        // is intentionally not consulted for a hard block here: only
        // "attach a packet" requires verified POD, not "send the invoice
        // itself" (matches check_invoice_ready_to_send()).
        await checkPacketReadiness(supabase, inv.load_id);
      }
      if (inv.status === "draft") {
        blocked = blocked ?? "This invoice is still a draft.";
      }
      if (inv.status === "void") {
        blocked = "This invoice has been voided.";
      }

      const orgName = await resolveOrgName(supabase);
      const dueDateLabel = inv.due_date ? new Date(inv.due_date + "T00:00:00").toLocaleDateString(undefined, { year: "numeric", month: "long", day: "numeric" }) : "--";

      return {
        to,
        subject: `Invoice ${inv.invoice_number}${inv.loads?.load_number ? ` – Load ${inv.loads.load_number}` : ""}`,
        message: `Hello,\n\nPlease find attached Invoice ${inv.invoice_number}${inv.loads?.load_number ? ` for Load ${inv.loads.load_number}` : ""}.\n\nAmount Due: ${money(inv.balance_due)}\nDue Date: ${dueDateLabel}\n\nThank you,\n${orgName}`,
        attachmentType,
        attachmentLabel,
        blocked,
        organizationName: orgName,
        numberLabel: inv.invoice_number,
        packetStoragePath,
      };
    }

    case "statement": {
      const { data: statement } = await supabase
        .from("statements")
        .select("id, statement_number, statement_type, party_type, closing_balance, period_end, as_of_date, storage_path, recipient_email, broker_id, customer_id, brokers(company_name, email), customers(company_name, email)")
        .eq("id", entityId)
        .single();
      if (!statement) return { error: "Statement not found.", status: 404 };
      const st = statement as unknown as {
        statement_number: string;
        closing_balance: number;
        period_end: string | null;
        as_of_date: string | null;
        storage_path: string | null;
        recipient_email: string | null;
        brokers: { company_name: string; email: string | null } | null;
        customers: { company_name: string; email: string | null } | null;
      };
      if (!st.storage_path) return { error: "This statement has no generated PDF yet.", status: 400 };
      const party = st.brokers ?? st.customers;
      const to = st.recipient_email || party?.email || "";
      const orgName = await resolveOrgName(supabase);
      const asOfLabel = st.period_end ?? st.as_of_date ?? "";
      return {
        to,
        subject: `Statement ${st.statement_number}`,
        message: `Hello,\n\nPlease find attached Statement ${st.statement_number} as of ${asOfLabel}.\n\nClosing Balance: ${money(st.closing_balance)}\n\nThank you,\n${orgName}`,
        attachmentType: "statement_pdf",
        attachmentLabel: `Statement PDF (${st.statement_number}, frozen)`,
        blocked: null,
        organizationName: orgName,
        numberLabel: st.statement_number,
        statementStoragePath: st.storage_path,
      };
    }

    case "carrier_settlement": {
      const { data: settlement } = await supabase
        .from("settlements")
        // Phase 2G.12: factoring_company_name dropped -- confirmed unused
        // anywhere below (dead select, not an actual reader); carriers'
        // own copy is stale/scheduled for removal by 0069 regardless.
        .select("id, settlement_number, net_amount, payee_name, status, carriers(legal_name, email)")
        .eq("id", entityId)
        .single();
      if (!settlement) return { error: "Settlement not found.", status: 404 };
      const s = settlement as unknown as {
        settlement_number: string;
        net_amount: number;
        payee_name: string | null;
        status: string;
        carriers: { legal_name: string; email: string | null } | null;
      };
      const orgName = await resolveOrgName(supabase);
      return {
        to: s.carriers?.email || "",
        subject: `Carrier Settlement ${s.settlement_number}`,
        message: `Hello,\n\nPlease find attached Carrier Settlement ${s.settlement_number}${s.payee_name ? ` for ${s.payee_name}` : ""}.\n\nNet Amount: ${money(s.net_amount)}\n\nThank you,\n${orgName}`,
        attachmentType: "carrier_settlement_pdf",
        attachmentLabel: `Carrier Settlement PDF (${s.settlement_number})`,
        blocked: s.status === "draft" ? "This settlement hasn't been approved yet." : null,
        organizationName: orgName,
        numberLabel: s.settlement_number,
      };
    }

    case "driver_settlement": {
      const { data: settlement } = await supabase
        .from("driver_settlements")
        .select("id, settlement_number, net_pay, status, drivers(first_name, last_name, email)")
        .eq("id", entityId)
        .single();
      if (!settlement) return { error: "Settlement not found.", status: 404 };
      const s = settlement as unknown as {
        settlement_number: string;
        net_pay: number;
        status: string;
        drivers: { first_name: string; last_name: string; email: string | null } | null;
      };
      const orgName = await resolveOrgName(supabase);
      return {
        to: s.drivers?.email || "",
        subject: `Driver Settlement ${s.settlement_number}`,
        message: `Hello ${s.drivers?.first_name ?? ""},\n\nPlease find attached your Driver Settlement ${s.settlement_number}.\n\nNet Pay: ${money(s.net_pay)}\n\nThank you,\n${orgName}`,
        attachmentType: "driver_settlement_pdf",
        attachmentLabel: `Driver Settlement PDF (${s.settlement_number})`,
        blocked: s.status === "draft" ? "This settlement hasn't been approved yet." : null,
        organizationName: orgName,
        numberLabel: s.settlement_number,
      };
    }

    case "payment": {
      const { data: payment } = await supabase
        .from("payments")
        .select("id, payment_number, amount, invoices(invoice_number, bill_to_email, broker_id, customer_id, brokers(email), customers(email))")
        .eq("id", entityId)
        .single();
      if (!payment) return { error: "Payment not found.", status: 404 };
      const p = payment as unknown as {
        payment_number: string;
        amount: number;
        invoices: {
          invoice_number: string;
          bill_to_email: string | null;
          broker_id: string | null;
          customer_id: string | null;
          brokers: { email: string | null } | null;
          customers: { email: string | null } | null;
        } | null;
      };
      const party = getBillingParty({ broker_id: p.invoices?.broker_id, customer_id: p.invoices?.customer_id });
      const partyEmail = party.type === "broker" ? p.invoices?.brokers?.email : party.type === "customer" ? p.invoices?.customers?.email : null;
      const orgName = await resolveOrgName(supabase);
      return {
        to: p.invoices?.bill_to_email || partyEmail || "",
        subject: `Payment Receipt ${p.payment_number}${p.invoices ? ` – Invoice ${p.invoices.invoice_number}` : ""}`,
        message: `Hello,\n\nThank you for your payment of ${money(p.amount)}${p.invoices ? ` against Invoice ${p.invoices.invoice_number}` : ""}. A receipt is attached.\n\nThank you,\n${orgName}`,
        attachmentType: "receipt_pdf",
        attachmentLabel: `Payment Receipt PDF (${p.payment_number})`,
        blocked: null,
        organizationName: orgName,
        numberLabel: p.payment_number,
      };
    }

    default:
      return { error: "Unknown entity type.", status: 400 };
  }
}

export function money(n: number | null | undefined): string {
  return `$${Number(n ?? 0).toLocaleString(undefined, { minimumFractionDigits: 2 })}`;
}

export async function resolveOrgName(supabase: Supabase): Promise<string> {
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) return "Your organization";
  const { data: profile } = await supabase.from("profiles").select("organizations(name)").eq("id", user.id).single();
  const org = profile as unknown as { organizations: { name: string } | null } | null;
  return org?.organizations?.name ?? "Your organization";
}
