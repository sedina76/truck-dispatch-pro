-- Test-only twin shim: Supabase's default privileges. On a Supabase project,
-- every table, sequence and function created in schema public by postgres is
-- automatically granted to anon, authenticated and service_role. Migrations
-- (and their postconditions) assume this.
alter default privileges in schema public grant all on tables to anon, authenticated, service_role;
alter default privileges in schema public grant all on sequences to anon, authenticated, service_role;
alter default privileges in schema public grant execute on functions to anon, authenticated, service_role;
