-- ---------------------------------------------------------------------------
-- Billing Packet generation hardening: adds the DELETE policies needed to
-- support the app-level cleanup path when a packet reservation succeeds
-- but the subsequent PDF upload fails (see generatePacket() in
-- src/app/(app)/invoices/billing-packet-actions.ts). No schema/version
-- semantics change -- version uniqueness (invoice_id, version) is unchanged,
-- and no existing row/object is ever touched by this.
--
-- These policies are scoped identically to the existing insert/update
-- policies from 0024 (same org, same role tier) -- they do not expand who
-- can write billing packets, only what a request that already has write
-- access can undo for ITS OWN failed, not-yet-successful attempt. App code
-- only ever calls delete from that one failure-recovery branch; a
-- successfully generated packet is never targeted for deletion by any
-- code path.
-- ---------------------------------------------------------------------------

create policy billing_packets_delete on public.billing_packets
  for delete using (
    organization_id = public.current_org_id()
    and public.has_role(array['owner', 'admin', 'accountant']::public.org_role[])
  );

create policy billing_packets_storage_delete on storage.objects
  for delete using (
    bucket_id = 'billing-packets'
    and (storage.foldername(name))[1] = public.current_org_id()::text
    and public.has_role(array['owner', 'admin', 'accountant']::public.org_role[])
  );
