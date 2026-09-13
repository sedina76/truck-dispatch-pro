# LOAD_STOPS_MUTATION_AUDIT_0144.md

Phase 3B.3C.3, Section B — every reachable `load_stops` INSERT/UPDATE/DELETE
path in this codebase as of migration 0144 (application code, RPCs, triggers,
migrations, service jobs, and tests), re-derived by direct search (`grep`
across `src/`, `supabase/migrations/*.sql`, and this repo's test files), not
assumed from memory. For each caller: mutation type, whether `load_id` can
change, the Postgres role the statement runs as, whether
`guard_load_stops_parent_lock()` fires, whether another parent/load lock is
already held independently, the resulting lock order, and whether any lock
reversal exists.

## Method

- `grep -rn "load_stops" src/` then filtered to `.insert(`/`.update(`/
  `.delete(`/`.upsert(` call sites (28 files reference `load_stops` at all;
  only a handful ever write to it — the rest are read-only `.select()`s and
  joins).
- `grep -n "insert into public.load_stops\|update public.load_stops\|delete
  from public.load_stops" supabase/migrations/*.sql`.
- `grep` for `TRUNCATE`-relevant grants via `information_schema.
  role_table_grants` (empirically checked against a live disposable
  cluster, not just inferred from migration text).

## Caller matrix

| # | Caller | Mutation | `load_id` can change? | Role | Trigger fires? | Other parent lock already held? | Resulting lock order | Reversal? |
|---|---|---|---|---|---|---|---|---|
| 1 | `create_load_with_stops()` RPC (`0047`→`0061`→`0068`→`0114`, current live def in 0114) | INSERT (loop, one row per stop in `p_stops`) | No — `load_id` is always the row's OWN freshly-`INSERT`ed `loads.id`, `returning`-captured in the SAME transaction, never a parameter | `authenticated` (SECURITY DEFINER; internally re-checks owner/admin/dispatcher itself, since RLS does not apply to a SECURITY DEFINER function's own statements) | Yes (`BEFORE INSERT`, locks `NEW.load_id`) | Yes, implicitly: the `loads` row was `INSERT`ed by this SAME transaction moments earlier and is not yet visible/committed to any other transaction, so it is uncontended by construction — no other session can possibly hold or want this lock yet | `loads` (via its own `INSERT`) → `load_stops` (via `guard_load_stops_parent_lock()`, locking the same just-created, still-uncommitted row) | No — cannot reverse against anything, since nothing else can see this row until commit |
| 2 | `updateDispatchBoardStatus()` (`board-actions.ts:184,191`) | UPDATE `arrived_at`/`departed_at` only, `.eq("id", pickup.id)` / `.eq("id", delivery.id)` | No — `load_id` never in the patch object | `authenticated` (user-session client, RLS-enforced) | Yes (`BEFORE UPDATE`, same-`load_id` path, locks that one parent) | No — this function locks/reads `dispatches` (`.eq("id", dispatchId)`) via a plain `SELECT`, never `FOR UPDATE`; no independent `loads` lock is taken before this stop write | `load_stops`'s own trigger locks `loads` — the only lock in this transaction | No — the only lock-taking statement in the transaction is the trigger's own `loads` lock; nothing else to reverse against |
| 3 | `setStopTimezone()` (`board-actions.ts:1520`, via `requireStopOwnership()`) | UPDATE `timezone`/`timezone_source` only, `.eq("id", stopId)` | No | `authenticated` | Yes (same-`load_id` path) | No — `requireStopOwnership()` only `SELECT`s (no `FOR UPDATE`) `dispatches`/`load_stops` to verify ownership before the write | `load_stops` trigger → `loads` (only lock taken) | No |
| 4 | `setStopCoordinates()` (`board-actions.ts:~1393`, via `requireStopOwnership()`) | UPDATE `latitude`/`longitude`/`geocoded_at`/`geocode_source` only, `.eq("id", stopId)` | No | `authenticated` | Yes (same-`load_id` path) | No (same as #3) | `load_stops` trigger → `loads` | No |
| 5 | `setStopAppointment()` (`board-actions.ts:~1483`, via `requireStopOwnership()`) | UPDATE `scheduled_at`/`scheduled_window_end`/`timezone`/`timezone_source` only, `.eq("id", stopId)` | No | `authenticated` | Yes (same-`load_id` path) | No (same as #3) | `load_stops` trigger → `loads` | No |
| 6 | `evaluate-geofences.ts` — three call sites (arrival/departure on pickup, arrival on delivery), reached from `/api/driver-portal/location`'s POST handler and `confirmGeofenceArrival()` | UPDATE `arrived_at`/`departed_at` only, `.eq("id", m.loadStopId)` | No | `service_role` (via `createServiceRoleClient()` — **bypasses RLS, but RLS bypass does NOT bypass triggers**; `guard_load_stops_parent_lock()` is a plain `BEFORE ROW` trigger and fires for every role, service_role included) | Yes (same-`load_id` path) | No — the geofence pipeline reads `dispatches`/`load_stops` context via plain `SELECT`s before this write, never `FOR UPDATE` | `load_stops` trigger → `loads` | No |
| 7 | `issue_carrier_invoice()` itself (0144, STEP 11a) | none directly — it only ever `SELECT ... FOR UPDATE`s existing `load_stops` rows, never `INSERT`/`UPDATE`/`DELETE`s one | n/a | `authenticated` (SECURITY DEFINER) | No — the trigger only fires on write statements; a `SELECT ... FOR UPDATE` does not fire `BEFORE INSERT/UPDATE/DELETE` | Yes — `loads` already locked at STEP 11, immediately before | `loads` → `load_stops` (this RPC's own STEP 11 → STEP 11a, unrelated to the trigger) | No — this is the reference order every other caller is being checked against |
| 8 | Cascade `DELETE` via `ON DELETE CASCADE` on `load_stops.load_id → loads.id` (0004), triggered by a direct `DELETE FROM public.loads WHERE id = ...` | DELETE (cascaded, one row per stop of the deleted load) | n/a (row is removed, not moved) | Whatever role executes the `loads` `DELETE` — RLS on `loads` (via the same `standard_tables` policy loop, 0010) grants this to owner/admin/dispatcher; **no application code path in `src/` and no migration ever issues `DELETE FROM public.loads`**, so this is reachable only via a direct table DELETE (e.g. the Supabase dashboard/SQL editor) by an authorized role, not through any ordinary application action | Yes — cascade deletes still fire `BEFORE DELETE` row triggers on the child table | Yes, self-referentially: the outer `DELETE FROM loads` statement already holds this exact row's lock (as part of deleting it) by the time the cascade reaches `load_stops`'s trigger, which then re-acquires the SAME lock in the SAME transaction — Postgres permits a transaction to re-acquire its own already-held lock without blocking or deadlocking against itself | `loads` (via the outer `DELETE`'s own implicit lock) → `load_stops` (cascade) → the trigger's own redundant, harmless re-lock of the same already-held row | No — empirically verified live (see below): a load with one stop, deleted directly, cascades cleanly, stop count afterward is 0, no error, no deadlock |

## TRUNCATE

Checked live against a disposable cluster with 0001-0144 applied
(`information_schema.role_table_grants` + an actual attempted `TRUNCATE` as
`authenticated`):

```
select grantee, privilege_type from information_schema.role_table_grants where table_name='load_stops';
 authenticated | DELETE
 authenticated | INSERT
 authenticated | SELECT
 authenticated | UPDATE
 postgres      | DELETE / INSERT / REFERENCES / SELECT / TRUNCATE / TRIGGER / UPDATE
```

`authenticated` has **no `TRUNCATE` grant** on `load_stops` — confirmed
empirically: `set role authenticated; truncate public.load_stops;` →
`ERROR: permission denied for table load_stops`. No migration in 0001-0144
ever grants `TRUNCATE` on `load_stops` to `authenticated` or `anon`, and no
application code in `src/` ever issues a `TRUNCATE`. `TRUNCATE` would, if
somehow reachable, bypass `guard_load_stops_parent_lock()` entirely (Postgres
never fires `BEFORE`/`AFTER` **row** triggers for `TRUNCATE`, only
statement-level triggers, and none are defined on `load_stops`) — but since
the ordinary application path (the `authenticated` role, the only role any
browser-facing code ever runs as) categorically cannot execute it, this is
not a reachable bypass of financial snapshot safety through any application
path this codebase exposes. The one role that CAN `TRUNCATE` — `postgres`
(migration/superuser context) — is not reachable from any application
request; a real Supabase-provisioned `service_role` may carry broader
platform-default table privileges than this repo's own migrations grant it
(Supabase's own platform bootstrap, outside this repo's migration history),
but `service_role` is never exposed to a browser or an unauthenticated
caller either way — it is used exclusively from trusted server-only code
(`evaluate-geofences.ts`, `import "server-only"`), and no code path in this
repository ever issues a `TRUNCATE` from it.

## Conclusion

Every reachable **write** path to `load_stops` — application code (5 call
sites, all `authenticated`, all single-column-scoped-by-`id` `UPDATE`s or
role-checked `INSERT`s) and the one `service_role` path (geofence
automation, also `UPDATE`-only) — is covered by
`guard_load_stops_parent_lock()`, never changes `load_id`, and therefore
never engages the cross-load rejection path. The ONLY caller that creates a
brand-new `load_stops` row outside of `issue_carrier_invoice()`'s own reads
is `create_load_with_stops()`, and its lock is provably uncontended (same
transaction as the parent `loads` row's own creation). The only DELETE path
outside a hypothetical direct table statement is the FK cascade from a
`loads` deletion — itself unreachable from any application code path, and
proven live to be self-consistent (no deadlock, no error) even if invoked
directly. No caller anywhere takes a `loads`/`load_stops` lock in the
reverse of `issue_carrier_invoice()`'s own order (`loads` before
`load_stops`, always) — there is no reversal to find.
