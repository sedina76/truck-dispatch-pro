// "Broker pays the carrier" loads in the one Invoices workflow.
//
// For these loads the invoice to the broker is the CARRIER's invoice (in the
// carrier's name, paid to the carrier or its factoring company), stored in
// carrier_invoices -- not one of your own invoices. Ready to Bill, the
// Create Invoice load picker and the Invoices list read them through here so
// the user sees one list of "invoices to brokers" either way.
// Everything is read through the caller's RLS-scoped session.

import type { createClient } from "@/lib/supabase/server";

type Supabase = Awaited<ReturnType<typeof createClient>>;

export type CarrierPaidLoad = {
  loadId: string;
  loadNumber: string;
  carrierId: string;
  carrierName: string | null;
  brokerId: string | null;
  customerId: string | null;
  billToName: string | null;
  rate: number;
  deliveredAt: string | null;
  origin: string | null;
  destination: string | null;
  hasVerifiedPod: boolean;
};

export type LiveCarrierInvoiceForLoad = { loadId: string; invoiceId: string; invoiceNumber: string | null; issuanceStatus: string };

/**
 * Loads on a live carrier invoice, keyed by load id. "Live" is the billable
 * ledger's unreleased row (0157): discarding a draft or voiding releases it,
 * so a discarded draft (which keeps status "draft") no longer holds the load.
 */
export async function liveCarrierInvoicesByLoad(supabase: Supabase, loadIds?: string[]): Promise<Map<string, LiveCarrierInvoiceForLoad>> {
  let q = supabase
    .from("carrier_invoice_billable_ledger_0157")
    .select("load_id, invoice_id, carrier_invoices!inner(invoice_number, issuance_status)")
    .is("released_at", null)
    .neq("carrier_invoices.issuance_status", "voided");
  if (loadIds) {
    if (loadIds.length === 0) return new Map();
    q = q.in("load_id", loadIds);
  }
  const { data } = await q.limit(5000);
  const out = new Map<string, LiveCarrierInvoiceForLoad>();
  for (const row of (data ?? []) as unknown as { load_id: string; invoice_id: string; carrier_invoices: { invoice_number: string | null; issuance_status: string } | null }[]) {
    if (!row.carrier_invoices) continue;
    out.set(String(row.load_id), { loadId: String(row.load_id), invoiceId: String(row.invoice_id), invoiceNumber: row.carrier_invoices.invoice_number, issuanceStatus: row.carrier_invoices.issuance_status });
  }
  return out;
}

/** Ids of draft / ready carrier invoices that still hold loads (i.e. not discarded). */
export async function liveCarrierDraftIds(supabase: Supabase): Promise<Set<string>> {
  const { data } = await supabase
    .from("carrier_invoice_billable_ledger_0157")
    .select("invoice_id, carrier_invoices!inner(issuance_status)")
    .is("released_at", null)
    .in("carrier_invoices.issuance_status", ["draft", "ready_for_issue"])
    .limit(5000);
  return new Set((data ?? []).map((r) => String((r as { invoice_id: string }).invoice_id)));
}

/** Load ids (of the given ones) whose live dispatch is "broker pays the carrier". */
export async function carrierPaidLoadIds(supabase: Supabase, loadIds: string[]): Promise<Set<string>> {
  if (loadIds.length === 0) return new Set();
  const { data } = await supabase.from("dispatches").select("load_id").in("load_id", loadIds).eq("proceeds_model", "carrier_paid_directly").neq("status", "cancelled");
  return new Set((data ?? []).map((r) => String(r.load_id)));
}

/**
 * Delivered "broker pays the carrier" loads that do not have a carrier
 * invoice yet -- what still needs invoicing, next to your own Ready to Bill.
 */
export async function carrierPaidLoadsToInvoice(supabase: Supabase): Promise<CarrierPaidLoad[]> {
  const { data: dispatches } = await supabase
    .from("dispatches")
    .select("load_id")
    .eq("proceeds_model", "carrier_paid_directly")
    .neq("status", "cancelled")
    .limit(5000);
  const ids = [...new Set((dispatches ?? []).map((d) => String(d.load_id)))];
  if (ids.length === 0) return [];

  const { data: loadsRaw } = await supabase
    .from("loads")
    .select("id, load_number, status, carrier_id, broker_id, customer_id, carriers(legal_name, dba_name), brokers(company_name), customers(company_name), load_stops(stop_type, stop_sequence, city, state, arrived_at, scheduled_at)")
    .in("id", ids)
    .in("status", ["delivered", "pod_received", "invoiced", "closed"])
    .limit(2000);
  const loads = (loadsRaw ?? []) as unknown as {
    id: string; load_number: string; carrier_id: string | null; broker_id: string | null; customer_id: string | null;
    carriers: { legal_name: string; dba_name: string | null } | null; brokers: { company_name: string } | null; customers: { company_name: string } | null;
    load_stops: { stop_type: string; stop_sequence: number; city: string | null; state: string | null; arrived_at: string | null; scheduled_at: string | null }[] | null;
  }[];
  if (loads.length === 0) return [];

  const loadIds = loads.map((l) => l.id);
  const [onInvoice, { data: fin }, { data: pods }] = await Promise.all([
    liveCarrierInvoicesByLoad(supabase, loadIds),
    supabase.from("load_financials").select("load_id, rate").in("load_id", loadIds),
    supabase.from("documents").select("entity_id, is_verified").eq("entity_type", "load").eq("document_type", "pod").in("entity_id", loadIds),
  ]);
  const rate = new Map((fin ?? []).map((r) => [String(r.load_id), Number(r.rate ?? 0)]));
  const verifiedPod = new Set((pods ?? []).filter((p) => p.is_verified).map((p) => String(p.entity_id)));

  const place = (s: { city: string | null; state: string | null } | undefined) => (s?.city ? `${s.city}${s.state ? `, ${s.state}` : ""}` : null);
  return loads
    .filter((l) => !onInvoice.has(l.id) && l.carrier_id)
    .map((l) => {
      const stops = [...(l.load_stops ?? [])].sort((a, b) => a.stop_sequence - b.stop_sequence);
      const pickup = stops.find((s) => s.stop_type === "pickup");
      const delivery = [...stops].reverse().find((s) => s.stop_type === "delivery");
      return {
        loadId: l.id,
        loadNumber: l.load_number,
        carrierId: String(l.carrier_id),
        carrierName: l.carriers?.dba_name || l.carriers?.legal_name || null,
        brokerId: l.broker_id,
        customerId: l.customer_id,
        billToName: l.broker_id ? (l.brokers?.company_name ?? null) : l.customer_id ? (l.customers?.company_name ?? null) : null,
        rate: rate.get(l.id) ?? 0,
        deliveredAt: delivery ? (delivery.arrived_at ?? delivery.scheduled_at) : null,
        origin: place(pickup),
        destination: place(delivery),
        hasVerifiedPod: verifiedPod.has(l.id),
      };
    });
}
