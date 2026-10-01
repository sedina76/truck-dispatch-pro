-- NOT APPROVED FOR PRODUCTION. Disposable synthetic model only.
\set ON_ERROR_STOP on
BEGIN TRANSACTION READ ONLY;
SELECT _td0148.check_state('after');
DO $$ BEGIN
 IF EXISTS (SELECT 1 FROM public.factoring_relationships WHERE carrier_id IS NOT NULL) THEN RAISE EXCEPTION '0148_REFUSED_CARRIER_WRITE'; END IF;
 IF to_regclass('public.factoring_relationships_one_default_per_org') IS NULL OR to_regclass('public.factoring_relationships_one_default_per_carrier') IS NULL THEN RAISE EXCEPTION '0148_REFUSED_INDEX'; END IF;
 IF to_regclass('public.carrier_backfill_0137_provenance') IS NOT NULL THEN RAISE EXCEPTION '0148_REFUSED_FABRICATED_PROVENANCE'; END IF;
END $$;
COMMIT;
