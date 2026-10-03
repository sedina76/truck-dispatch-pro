-- Test-only. Recreates the production billing state that the data-pinned
-- migrations 0120..0129 assert before they run (63 organizations, the three
-- grandfathered pilot organizations by id + name, their subscription rows),
-- so the REAL migrations can be applied unchanged on a disposable database.
-- Never run on a real database.
do $$
declare v_prof uuid; v_ent uuid; i int;
begin
  if (select count(*) from public.organizations) <> 0 then
    raise exception 'production_twin_seed: expects an empty organizations table';
  end if;
  insert into public.organizations (id, name, slug) values
    ('054ef09f-6cfb-461a-aeb2-3ec9fdd62d47', 'Kali Freight LLC', 'twin-kali-freight'),
    ('11111111-0000-0000-0000-000000000001', 'Kali Freights LLC', 'twin-kali-freights'),
    ('1f29315a-e193-481f-bd5f-5f1b40da7f05', 'Kali Logistic', 'twin-kali-logistic');
  for i in 1..60 loop
    insert into public.organizations (name, slug) values ('Twin Org ' || i, 'twin-org-' || i);
  end loop;
  delete from public.organization_subscriptions;
  -- production's original (pre-0121) plan catalog was created by hand, not by a migration
  insert into public.subscription_plans (tier, name, monthly_price_cents, annual_price_cents) values
    ('starter', 'Starter', 4900, 49000), ('professional', 'Professional', 14900, 149000), ('enterprise', 'Enterprise', 39900, 399000)
  on conflict (tier) do nothing;
  select id into v_prof from public.subscription_plans where tier = 'professional' and is_active;
  select id into v_ent from public.subscription_plans where tier = 'enterprise' and is_active;
  insert into public.organization_subscriptions (organization_id, plan_id, status, billing_cycle) values
    ('11111111-0000-0000-0000-000000000001', v_prof, 'active', 'monthly'),
    ('1f29315a-e193-481f-bd5f-5f1b40da7f05', v_ent, 'active', 'monthly');
end $$;
