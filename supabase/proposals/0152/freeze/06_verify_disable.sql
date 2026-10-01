-- =============================================================================
-- 06_verify_disable.sql -- DATABASE FREEZE v2, STEP 6: SQL-LAYER RESTORATION CHECK (read-only: one SELECT; changes nothing)
-- PROPOSAL 0152 (freeze tooling). NOT APPROVED FOR PRODUCTION.
-- Proves the freeze artifacts are gone and the recorded prior state matches. It does NOT prove writes work again through the API: run api_freeze_probe.py --phase restored.
-- Last row: SQL_LAYER_RESTORED__EXTERNAL_WRITE_PROBE_REQUIRED or SQL_LAYER_NOT_RESTORED.
-- The trigger/ACL fingerprints must be IDENTICAL when no migration ran during the freeze (the hosted test); after approved migrations they legitimately differ and are INFO.
-- =============================================================================
with run as (select * from ops_freeze_v2.freeze_run order by started_at desc limit 1),
c as (
  select 1 as ord, 'the latest run is marked restored' as check_name, case when (select status from run) = 'restored' then 'PASS' else 'FAIL' end as result, coalesce((select status from run), 'none') as detail
  union all select 2, 'no freeze trigger exists anywhere in the database',
         case when not exists (select 1 from pg_trigger where tgname = '0_ops_freeze_block_writes' and not tgisinternal) then 'PASS' else 'FAIL' end,
         (select count(*) from pg_trigger where tgname = '0_ops_freeze_block_writes' and not tgisinternal)::text || ' remaining'
  union all select 3, 'no run is active', case when not exists (select 1 from ops_freeze_v2.freeze_run where status = 'frozen') then 'PASS' else 'FAIL' end, ''
  union all select 4, 'non-freeze triggers on the scope tables equal the pre-freeze fingerprint (must be identical if no migration ran)',
         case when ops_freeze_v2.fingerprint_triggers((select scope_schemas from run)) = (select pre_trigger_fp from run) then 'PASS' else 'FAIL_OR_MIGRATED' end,
         'compare with the migration log: a difference is acceptable ONLY after approved migrations'
  union all select 5, 'table ACLs / owners / RLS flags equal the pre-freeze fingerprint (must be identical if no migration ran)',
         case when ops_freeze_v2.fingerprint_acl((select scope_schemas from run)) = (select pre_acl_fp from run) then 'PASS' else 'FAIL_OR_MIGRATED' end,
         'compare with the migration log: a difference is acceptable ONLY after approved migrations'
  union all select 6, 'cron jobs paused by the freeze are active again and unchanged',
         case when to_regclass('cron.job') is null then case when (select count(*) from ops_freeze_v2.cron_state where run_id = (select run_id from run)) = 0 then 'PASS' else 'FAIL' end
              else (select case when (xpath('/row/n/text()', query_to_xml(format('select count(*) as n from ops_freeze_v2.cron_state cs left join cron.job j on j.jobid = cs.job_id where cs.run_id = %L and cs.paused_by_freeze and (j.jobid is null or j.active is distinct from cs.prior_active)', (select run_id from run)), false, true, '')))[1]::text::int = 0 then 'PASS' else 'FAIL' end) end, ''
  union all select 7, 'operator session can write', case when current_setting('transaction_read_only') = 'off' and not pg_is_in_recovery() then 'PASS' else 'FAIL' end, session_user::text
)
select ord, check_name, result, detail from c
union all select 9999, 'VERDICT', case when count(*) filter (where result = 'FAIL') = 0 and count(*) filter (where result = 'FAIL_OR_MIGRATED') = 0 then 'SQL_LAYER_RESTORED__EXTERNAL_WRITE_PROBE_REQUIRED'
                                        when count(*) filter (where result = 'FAIL') = 0 then 'SQL_LAYER_RESTORED_BUT_FINGERPRINT_DIFFERS__EXPLAIN_OR_STOP' else 'SQL_LAYER_NOT_RESTORED' end,
          'Run api_freeze_probe.py --phase restored before declaring the restoration complete.' from c
order by 1;
