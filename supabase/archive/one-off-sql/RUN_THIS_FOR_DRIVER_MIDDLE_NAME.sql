-- ---------------------------------------------------------------------------
-- Adds middle_name to the Personal Information section of the driver
-- record. Not sensitive enough to need the encrypted-PII treatment SSN and
-- direct deposit numbers get (see 0014 PART 2/3) -- just a plain column,
-- same tier as first_name/last_name.
-- ---------------------------------------------------------------------------
alter table public.drivers add column middle_name text;

-- The column-level grants from 0014 are an explicit allow-list (not a
-- deny-list), so a brand new column is invisible to the API until it's
-- added to all three grants below, same as every other non-sensitive field.
grant select (middle_name) on public.drivers to authenticated;
grant insert (middle_name) on public.drivers to authenticated;
grant update (middle_name) on public.drivers to authenticated;
