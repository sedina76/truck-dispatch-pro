-- Test-only twin shim: 0069 drops dispatches.notes, but production still has
-- the column (0135 grants UPDATE on it and was applied successfully there).
alter table public.dispatches add column if not exists notes text;
