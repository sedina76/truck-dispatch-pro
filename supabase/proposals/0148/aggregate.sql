-- NOT APPROVED FOR PRODUCTION. Only counts and hashes leave the disposable fixture.
\set ON_ERROR_STOP on
BEGIN TRANSACTION READ ONLY;
SELECT jsonb_build_object(
 'invoices',(SELECT jsonb_object_agg(status,n) FROM (SELECT status,count(*) n FROM public.invoices GROUP BY status) q),
 'payments',(SELECT jsonb_object_agg(status,n) FROM (SELECT status,count(*) n FROM public.payments GROUP BY status) q),
 'factoring',(SELECT jsonb_object_agg(status,n) FROM (SELECT status,count(*) n FROM public.factored_invoices GROUP BY status) q),
 'invoice_recipient_conflicts',(SELECT count(*) FROM public.invoices WHERE broker_id IS NOT NULL AND customer_id IS NOT NULL),
 'load_recipient_conflicts',(SELECT count(*) FROM public.loads WHERE broker_id IS NOT NULL AND customer_id IS NOT NULL),
 'relationship_carrier_nonnull',(SELECT count(*) FROM public.factoring_relationships WHERE carrier_id IS NOT NULL),
 'relationship_carrier_sha256',(SELECT encode(sha256(convert_to(coalesce(jsonb_agg(jsonb_build_array(id,carrier_id) ORDER BY id)::text,'[]'),'UTF8')),'hex') FROM public.factoring_relationships)
);
COMMIT;
