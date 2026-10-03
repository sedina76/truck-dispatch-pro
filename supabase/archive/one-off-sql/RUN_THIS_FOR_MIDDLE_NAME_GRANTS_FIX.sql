-- ---------------------------------------------------------------------------
-- Fixes a gap from 0017: the middle_name column on public.drivers exists
-- (confirmed live -- a driver was already successfully created with a
-- middle_name via convert_driver_application_to_driver, which runs as
-- SECURITY DEFINER and so bypasses column grants entirely), but the
-- column-level SELECT/INSERT/UPDATE grants for it were never actually
-- applied to the `authenticated` role. Postgres denies an entire query when
-- it references any column the caller lacks a grant on -- not just that
-- column -- so every plain page load of a driver (View/Edit, same page)
-- was failing outright and rendering blank. GRANT is idempotent -- safe to
-- run even if some of these already succeeded.
-- ---------------------------------------------------------------------------

grant select (middle_name) on public.drivers to authenticated;
grant insert (middle_name) on public.drivers to authenticated;
grant update (middle_name) on public.drivers to authenticated;
