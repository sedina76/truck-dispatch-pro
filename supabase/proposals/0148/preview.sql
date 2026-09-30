-- NOT APPROVED FOR PRODUCTION. Aggregate-only evidence; never populates ownership.
\set ON_ERROR_STOP on
BEGIN TRANSACTION READ ONLY;
SELECT _td0148.check_state('after');
WITH evidence AS (
 SELECT r.id,r.organization_id,count(DISTINCT c.id) AS org_carriers,
        count(DISTINCT coalesce(d.carrier_id,l.carrier_id)) AS evidence_carriers,
        coalesce(bool_or(d.carrier_id IS NOT NULL AND l.carrier_id IS NOT NULL AND d.carrier_id<>l.carrier_id),false) AS conflict,
        coalesce(bool_or((d.organization_id IS NOT NULL AND d.organization_id<>r.organization_id) OR (l.organization_id IS NOT NULL AND l.organization_id<>r.organization_id) OR (i.organization_id IS NOT NULL AND i.organization_id<>r.organization_id)),false) AS cross_org
 FROM public.factoring_relationships r
 LEFT JOIN public.carriers c ON c.organization_id=r.organization_id
 LEFT JOIN public.factored_invoices fi ON fi.factoring_relationship_id=r.id
 LEFT JOIN public.invoices i ON i.id=fi.invoice_id
 LEFT JOIN public.dispatches d ON d.id=i.dispatch_id
 LEFT JOIN public.loads l ON l.id=i.load_id
 GROUP BY r.id,r.organization_id
), classified AS (
 SELECT CASE WHEN conflict OR cross_org THEN 'ABORT_structural_conflict'
 WHEN org_carriers=1 THEN 'single_carrier_org'
 WHEN org_carriers>1 AND evidence_carriers=1 THEN 'multi_carrier_org_provable'
 WHEN evidence_carriers>1 THEN 'unresolved_multiple'
 ELSE 'unresolved_no_evidence' END AS resolution FROM evidence
)
SELECT resolution,count(*) FROM classified GROUP BY resolution ORDER BY resolution;
COMMIT;
