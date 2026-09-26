# Emergency recovery -- database freeze (PROPOSAL 0152 tooling; NOT executed)

**Key safety property:** the freeze only changes a *setting* on the API/pooler login role(s) you list (normally `authenticator`) and pauses reviewed cron jobs. It never touches the operator role (`postgres` in the SQL Editor), never revokes a privilege, never changes data. So the SQL Editor can always write and can always undo the freeze.

## A. Normal path (state table available)
Run `05_disable_freeze.sql`, then `06_recycle_sessions_after_disable.sql`, then `07_verify_disable.sql` and the REST/RPC write probe.

## B. State table missing or the scripts cannot run
1. In the SQL Editor (operator session) run the read-only `01_discovery_readonly.sql` and compare with the discovery output you saved **before** the freeze (it lists every role's prior `setconfig` and every cron job's prior `active` flag). Do not guess prior values.
2. For each frozen role R whose saved pre-freeze `setconfig` had NO `default_transaction_read_only`:  `alter role R reset default_transaction_read_only;`  (if it had one, `alter role R set default_transaction_read_only = <the saved value>;`).
3. If pg_cron is installed, for each cron job you paused (ids from the enable output / discovery):  `select cron.alter_job(job_id := <id>, active := true);`  -- only those. If `cron.job` is absent, skip this step; never query it directly.
4. Terminate the read-only sessions so pools reconnect writable:  `select pg_terminate_backend(pid) from pg_stat_activity where usename = 'R' and pid <> pg_backend_pid();`  (operator role and other roles are never listed).
5. Prove writes work with the REST/RPC probe and re-run `01_discovery_readonly.sql` (no `default_transaction_read_only` anywhere).

## C. The SQL Editor itself cannot connect
The freeze never affects the operator role, so this is an unrelated outage. Use the direct database connection string / Supabase support. If only API traffic is blocked and you must reopen it at once, the operator role can run step B.2 from any connection.

## D. Application-side control
Unset `MAINTENANCE_MODE` (redeploy/restart) only AFTER step A/B is verified. The old `DISPATCH_WRITES_DISABLED` switch is separate and stays as configured.
