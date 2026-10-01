-- NOT APPROVED FOR PRODUCTION. Read-only functional assertions against the model.
\set ON_ERROR_STOP on
BEGIN TRANSACTION READ ONLY;
DO $$
DECLARE t text; privilege text;
BEGIN
 FOREACH t IN ARRAY ARRAY['activity_logs','brokers','carriers','customers','dispatches','documents','drivers','factored_invoices','factoring_companies','factoring_events','factoring_relationships','integration_settings','invoice_line_items','invoices','load_stops','loads','organizations','payments','profiles','settlement_line_items','settlements','trailers','trucks'] LOOP
  FOREACH privilege IN ARRAY ARRAY['DELETE','INSERT','REFERENCES','SELECT','TRIGGER','TRUNCATE','UPDATE'] LOOP
   IF has_table_privilege('anon','public.'||t,privilege) THEN RAISE EXCEPTION '0148_REFUSED_ANON_PRIVILEGE'; END IF;
  END LOOP;
 END LOOP;
 IF has_function_privilege('anon','public.classify_carrier_factoring_readiness(uuid,uuid,uuid)','EXECUTE') THEN RAISE EXCEPTION '0148_REFUSED_ANON_CLASSIFIER'; END IF;
 IF NOT has_function_privilege('authenticated','public.classify_carrier_factoring_readiness(uuid,uuid,uuid)','EXECUTE') THEN RAISE EXCEPTION '0148_REFUSED_CLASSIFIER_ACCESS'; END IF;
 IF public.classify_carrier_factoring_readiness(md5('carrier1')::uuid)->>'classification' <> 'factoring_policy_unconfigured' THEN RAISE EXCEPTION '0148_REFUSED_CLASSIFIER_RESULT'; END IF;
 IF EXISTS (SELECT 1 FROM public.carriers WHERE factoring_mode <> 'unconfigured') OR EXISTS (SELECT 1 FROM public.factoring_relationships WHERE carrier_id IS NOT NULL) THEN RAISE EXCEPTION '0148_REFUSED_OWNERSHIP'; END IF;
 IF (SELECT count(*) FROM pg_index WHERE indexrelid IN ('public.factoring_relationships_one_default_per_org'::regclass,'public.factoring_relationships_one_default_per_carrier'::regclass) AND indisvalid AND indisready AND indisunique) <> 2 THEN RAISE EXCEPTION '0148_REFUSED_INVARIANTS'; END IF;
 IF (SELECT attnotnull FROM pg_attribute WHERE attrelid='public.factoring_relationships'::regclass AND attname='carrier_id') THEN RAISE EXCEPTION '0148_REFUSED_NULLABILITY'; END IF;
END $$;
COMMIT;
