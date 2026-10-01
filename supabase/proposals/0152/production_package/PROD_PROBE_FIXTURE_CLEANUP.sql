-- PROD_PROBE_FIXTURE_CLEANUP.sql -- PROPOSAL ONLY. NOT APPLIED. Removes ONLY the three ops_freeze_probe objects created by PROD_PROBE_FIXTURE_PROPOSAL.sql. Run after restoration is proven
-- (freeze DISABLED, external probe --phase restored = WRITES_WORK). Do not run while the freeze is enabled unless abandoning the window.
begin;
drop function if exists public.ops_freeze_probe_write();
drop function if exists public.ops_freeze_probe_diag();
drop table if exists public.ops_freeze_probe_items;
commit;
select to_regclass('public.ops_freeze_probe_items') is null as table_removed, to_regprocedure('public.ops_freeze_probe_write()') is null as write_rpc_removed, to_regprocedure('public.ops_freeze_probe_diag()') is null as diag_rpc_removed;
