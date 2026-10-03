-- Emulates Supabase's default privileges on a plain PostgreSQL test cluster:
-- every public function is executable by anon, authenticated and service_role
-- (and PUBLIC, PostgreSQL's own default). Test-only; never run on production.
grant execute on all functions in schema public to public, anon, authenticated, service_role;
