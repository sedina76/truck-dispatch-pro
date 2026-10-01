# Emergency recovery -- database freeze v2 (draft; NOT APPROVED FOR PRODUCTION)

**When:** a write path must reopen immediately, `05_disable_freeze.sql` cannot complete, or a freeze test shows a breach/unexpected effect. Everything here is done by the operator in the SQL Editor (role `postgres`) and needs no recorded state.

## 1. Remove the write barrier (stateless)
Run `EMERGENCY_UNFREEZE.sql`. It drops every trigger named `0_ops_freeze_block_writes` (and nothing else) and returns `freeze_triggers_remaining = 0`. If it aborts with a lock timeout (a long transaction holds a table), re-run it; it changes nothing on abort. Then run the external probe with `--phase restored` to prove writes work.

## 2. Close out the record
The `ops_freeze_v2` run still says `frozen`, which makes a later enable refuse ("already active"). After the emergency, run `05_disable_freeze.sql` (it now drops nothing, resumes only the cron jobs it paused, marks the run restored). If it refuses because a cron job changed, resolve that job by hand (section 3) and record it, then mark the run: `update ops_freeze_v2.freeze_run set status = 'restored', restored_at = now() where status = 'frozen';`

## 3. Cron jobs (only if the freeze paused any)
The recorded jobs are in `ops_freeze_v2.cron_state` (`paused_by_freeze`, `prior_active`). Resume exactly those: `select cron.alter_job(job_id := <id>, active := true);` for each row with `paused_by_freeze and prior_active`. Never resume a job that was not active before.

## 4. Application
`MAINTENANCE_MODE` is separate: unset it and redeploy only when the Owner decides (runbook step 20). Emergency database recovery does not reopen the app.

## 5. Preserve evidence, block approval
Keep the probe evidence files (`~/tdp-freeze-evidence/`), the SQL results and the change ticket. A breach or an emergency unfreeze during a hosted test means production approval is BLOCKED until a fresh hosted test passes.

## 6. If nothing works
Restore from the pre-freeze recovery point (runbook step 1) only for structural corruption, per the Owner. The freeze itself never changes data, roles, settings or privileges, so it should never be the reason for a data restore.
