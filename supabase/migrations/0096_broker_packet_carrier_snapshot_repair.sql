-- =============================================================================
-- 0096_broker_packet_carrier_snapshot_repair.sql
-- Phase 2M.2E: repair reserve_broker_packet() (0095) -- its carrier_snapshot
-- construction references v_carrier.factoring_company_name, a column that
-- does not exist on the live public.carriers table (confirmed via live
-- schema introspection: carriers has no factoring_company_name; that field
-- lives on public.carrier_financials, exactly where
-- reserve_carrier_setup_package() (0087) already sources it from).
--
-- Blast radius correction from the Phase 2M.2D pre-apply finding: this is
-- NOT limited to drafts with a non-null carrier_id. Postgres parses the
-- entire UPDATE statement -- including both branches of the
-- `case when v_carrier.id is null then null else jsonb_build_object(...)
-- end` expression -- at prepare time. A field reference that does not
-- exist on the declared composite type public.carriers is a hard
-- parse-time error regardless of which branch will actually supply the
-- runtime value, so EVERY call to reserve_broker_packet() fails today,
-- with or without a carrier attached. Confirmed empirically both ways
-- before writing this fix, not assumed.
--
-- Fix, mirroring 0087's exact precedent: look up factoring_company_name
-- from carrier_financials (scoped by both carrier_id and organization_id,
-- so it can never cross an organization boundary) into its own plain
-- variable, and reference that variable in the snapshot instead of the
-- nonexistent carriers column. If carrier_id is null, or no
-- carrier_financials row exists for that carrier, the variable stays
-- NULL and jsonb_strip_nulls() cleanly omits it -- missing factoring
-- information never blocks reservation, matching the approved design.
--
-- Every other field, check, lock, transition, and the function's
-- signature/SECURITY DEFINER/search_path/grants are unchanged from 0095.
-- Audited every other v_carrier.* reference in this function against the
-- live carriers schema before writing this: legal_name, dba_name,
-- mc_number, dot_number, contact_name, phone, email, address_line1,
-- address_line2, city, state, postal_code, country, is_active, and id all
-- exist live -- factoring_company_name was the only invalid reference.
-- Also cross-checked organization_snapshot's and broker_snapshot's field
-- lists against the live organizations/brokers schemas: no further
-- invalid references found anywhere in this function.
-- =============================================================================

create or replace function public.reserve_broker_packet(p_packet_id uuid)
returns table(packet_id uuid, packet_version integer)
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_packet public.broker_packets;
  v_broker public.brokers;
  v_carrier public.carriers;
  v_org public.organizations;
  v_version integer;
  -- 0096: factoring_company_name lives on carrier_financials, not
  -- carriers -- see this migration's header comment.
  v_factoring_company_name text;
begin
  if not public.has_role(array['owner','admin','dispatcher']::public.org_role[]) then
    raise exception 'You do not have permission to generate broker packets.';
  end if;
  select * into v_packet from public.broker_packets where id = p_packet_id and organization_id = public.current_org_id() for update;
  if v_packet.id is null then raise exception 'Broker packet not found in your organization.'; end if;
  if v_packet.status <> 'draft' then raise exception 'Only a draft broker packet can be generated.'; end if;
  if v_packet.document_count < 1 then raise exception 'Select at least one document before generating.'; end if;

  if exists (
    select 1 from public.broker_packet_requirements r
    where r.broker_id = v_packet.broker_id and r.organization_id = v_packet.organization_id and r.is_required
      and not exists (select 1 from public.broker_packet_items i where i.packet_id = v_packet.id and i.document_type = r.document_type)
  ) then
    raise exception 'This broker packet is missing a required document type.';
  end if;

  select * into v_broker from public.brokers where id = v_packet.broker_id;
  select * into v_org from public.organizations where id = v_packet.organization_id;
  if v_packet.carrier_id is not null then
    select * into v_carrier from public.carriers where id = v_packet.carrier_id and organization_id = v_packet.organization_id and is_active;
    if v_carrier.id is null then raise exception 'The selected carrier must be active and belong to this organization.'; end if;
    -- 0096 fix: same source, same org-scoping shape as
    -- reserve_carrier_setup_package() (0087). Leaves v_factoring_company_name
    -- NULL (never blocks reservation) if no carrier_financials row exists.
    select factoring_company_name into v_factoring_company_name
    from public.carrier_financials where carrier_id = v_carrier.id and organization_id = v_packet.organization_id;
  end if;

  perform pg_advisory_xact_lock(hashtext(v_packet.organization_id::text), hashtext('broker-packet:' || v_packet.broker_id::text));
  select coalesce(max(version), 0) + 1 into v_version from public.broker_packets where broker_id = v_packet.broker_id and version is not null;

  update public.broker_packets set
    status = 'generating',
    version = v_version,
    generated_by = auth.uid(),
    organization_snapshot = jsonb_strip_nulls(jsonb_build_object(
      'name', v_org.name, 'dba_name', v_org.dba_name, 'mc_number', v_org.mc_number, 'dot_number', v_org.dot_number,
      'phone', v_org.business_phone, 'email', v_org.business_email,
      'address', nullif(concat_ws(', ', v_org.address_line1, v_org.address_line2, v_org.city, v_org.state, v_org.postal_code, v_org.country), ''),
      'logo_url', v_org.logo_url
    )),
    carrier_snapshot = case when v_carrier.id is null then null else jsonb_strip_nulls(jsonb_build_object(
      'legal_name', v_carrier.legal_name, 'dba_name', v_carrier.dba_name, 'mc_number', v_carrier.mc_number, 'dot_number', v_carrier.dot_number,
      'contact_name', v_carrier.contact_name, 'phone', v_carrier.phone, 'email', v_carrier.email,
      'address', nullif(concat_ws(', ', v_carrier.address_line1, v_carrier.address_line2, v_carrier.city, v_carrier.state, v_carrier.postal_code, v_carrier.country), ''),
      'factoring_company_name', v_factoring_company_name
    )) end,
    -- Broker MC/DOT are optional per 2M.2B decision 3: present when
    -- populated, cleanly absent otherwise (jsonb_strip_nulls), and never
    -- block reservation either way.
    broker_snapshot = jsonb_strip_nulls(jsonb_build_object(
      'legal_name', v_broker.legal_name, 'dba_name', v_broker.dba_name, 'mc_number', v_broker.mc_number, 'dot_number', v_broker.dot_number
    ))
  where id = p_packet_id;

  return query select v_packet.id, v_version;
end;
$$;

comment on function public.reserve_broker_packet(uuid) is
  'Draft -> generating: role/org/lock/requirements/snapshot/version, all in one transaction. EIN and any bank/routing-style value are deliberately never read into a snapshot. factoring_company_name is sourced from carrier_financials (0096 repair), not carriers, which does not have that column live.';

-- No grant/revoke changes: CREATE OR REPLACE FUNCTION with an unchanged
-- signature preserves the existing ACL from 0095 (revoked from public/anon,
-- granted to authenticated) untouched.
