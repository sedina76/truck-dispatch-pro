-- NOT APPROVED FOR PRODUCTION. Disposable synthetic model only.
DROP FUNCTION public.classify_carrier_factoring_readiness(uuid,uuid,uuid);
DROP INDEX public.factoring_relationships_one_default_per_carrier;
DROP TRIGGER factoring_relationships_guard_protected_fields ON public.factoring_relationships;
DROP FUNCTION public.guard_factoring_relationship_protected_fields();
DROP TRIGGER factoring_relationships_guard_org ON public.factoring_relationships;
create or replace function public.guard_factoring_relationship_org()
returns trigger
language plpgsql
as $$
declare
  v_company_org uuid;
begin
  select organization_id into v_company_org from public.factoring_companies where id = new.factoring_company_id;
  if v_company_org is null or v_company_org <> new.organization_id then
    raise exception 'Factoring relationship must reference a factoring company in the same organization.';
  end if;
  return new;
end;
$$;

CREATE TRIGGER factoring_relationships_guard_org BEFORE INSERT ON public.factoring_relationships FOR EACH ROW EXECUTE FUNCTION public.guard_factoring_relationship_org();
ALTER TABLE public.factoring_relationships DROP COLUMN carrier_id, DROP COLUMN remittance_instructions, DROP COLUMN remittance_reference, DROP COLUMN noa_template_text, DROP COLUMN noa_document_id, DROP COLUMN noa_reference, DROP COLUMN noa_effective_date, DROP COLUMN noa_approved, DROP COLUMN noa_approved_by, DROP COLUMN noa_approved_at, DROP COLUMN submission_method, DROP COLUMN submission_destination_email, DROP COLUMN submission_integration_id, DROP COLUMN submission_notes;
ALTER TABLE public.carriers DROP COLUMN factoring_mode;
DROP TYPE public.carrier_factoring_mode;
DROP TYPE public.factoring_submission_method;
ALTER TABLE public.integration_settings ALTER COLUMN provider TYPE text USING provider::text;
DROP TYPE public.integration_provider;
CREATE TYPE public.integration_provider AS ENUM ('dat','stripe');
ALTER TABLE public.integration_settings ALTER COLUMN provider TYPE public.integration_provider USING provider::public.integration_provider;
GRANT DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON public.activity_logs TO anon;
GRANT DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON public.brokers TO anon;
GRANT DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON public.carriers TO anon;
GRANT DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON public.customers TO anon;
GRANT DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON public.dispatches TO anon;
GRANT DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON public.documents TO anon;
GRANT DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON public.drivers TO anon;
GRANT DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON public.factored_invoices TO anon;
GRANT DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON public.factoring_companies TO anon;
GRANT DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON public.factoring_events TO anon;
GRANT DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON public.factoring_relationships TO anon;
GRANT DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON public.integration_settings TO anon;
GRANT DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON public.invoice_line_items TO anon;
GRANT DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON public.invoices TO anon;
GRANT DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON public.load_stops TO anon;
GRANT DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON public.loads TO anon;
GRANT DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON public.organizations TO anon;
GRANT DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON public.payments TO anon;
GRANT DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON public.profiles TO anon;
GRANT DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON public.settlement_line_items TO anon;
GRANT DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON public.settlements TO anon;
GRANT DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON public.trailers TO anon;
GRANT DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON public.trucks TO anon;
