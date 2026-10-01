# Full maintenance freeze -- write-surface inventory, options, recommendation (DESIGN ONLY; NOTHING IMPLEMENTED)

> **CORRECTION (hosted test, `tdp-freeze-test`): the database mechanism recommended in sections 3-4 (`ALTER ROLE authenticator SET default_transaction_read_only = on`) FAILED end to end -- a real PostgREST insert returned 201 during the freeze -- and is SUPERSEDED by the trigger-based v2 in `freeze/` (see `freeze/ROOT_CAUSE_AND_REDESIGN.md`). The PostgreSQL 17.6 evidence in section 3 used plain sessions, not PostgREST-style `BEGIN ... READ WRITE` transactions, so it did not exercise the override. Sections 3-4 are retained as history only.**


Decision recorded: the narrow `DISPATCH_WRITES_DISABLED` switch is insufficient (it only guards `createDispatch` and `cancelDispatch`); residual application writers are not accepted during the migration window.

## 1. Write-surface inventory (from the repository; production role/pool details are marked UNVERIFIED)

**Traffic choke point that exists today:** `src/middleware.ts` -> `updateSession` runs on every request except static assets (`matcher: /((?!_next/static|_next/image|favicon.ico|.*\.(svg|png|jpg|jpeg|gif|webp)$).*)`). Next.js Server Actions are POSTs to the page URL, so they pass through it.

| # | Surface | Where | What it writes | Uses service role? | Covered by DISPATCH_WRITES_DISABLED? |
|---|---|---|---|---|---|
| 1 | Dispatch create / cancel | `(app)/dispatch/actions.ts` `createDispatch`, `cancelDispatch` (-> `create_dispatch`, `transition_dispatch_status`) | dispatches, loads, financials, activity_logs | no (user JWT) | **yes** (only these two) |
| 2 | Dispatch edit / **reassignment** | `dispatch/actions.ts` `updateDispatch` (-> `reassign_dispatch_resources`, notes/financials writes), `updateDispatchStatus` | dispatches, dispatch_financials, notes, ledger | no | **no** |
| 3 | **Dispatch Board** status moves, notes, exceptions | `dispatch/board-actions.ts` (18 write ops incl. `transition_dispatch_status`), `dispatch/exceptions/actions.ts`, `dispatch/route-actions.ts` | dispatches, operational_exceptions | some | **no** |
| 4 | Driver portal | `driver-portal/actions.ts` (updates `dispatches` directly), `tracking-actions.ts`, `api/driver-portal/{login,logout,location,upload-pod}` | dispatches (status/timestamps), driver_locations, tracking sessions, documents, storage | yes | **no** |
| 5 | Geofence / route-deviation automation (triggered by driver location posts) | `lib/tracking/evaluate-geofences.ts` (updates `dispatches.status`), `evaluate-route-deviation.ts` | dispatches, exceptions | yes | **no** |
| 6 | Load writes | `(app)/loads/{actions,create-actions,pod-actions,load-number-actions}.ts` | loads, load_stops, documents | pod-actions | **no** |
| 7 | Carriers / trailers / trucks / drivers | `carriers/actions.ts`, `carrier-document-actions.ts`, `compliance-actions.ts`, `trucks/`, `trailers/`, `drivers/` | carriers, trailers (ownership scope), fleet | some | **no** |
| 8 | Factoring configuration & lifecycle | `settings/factoring/actions.ts` (`set_carrier_factoring_policy`, companies, relationships, NOA), `invoices/factoring-actions.ts` (13 write ops), `settings/integrations/*` | carriers.factoring_mode, factoring_* tables, integrations | yes | **no** |
| 9 | Carrier invoices / payments / voids / agreements (0142-0147 RPCs) | **no application caller today** (`grep` finds none in `src/`); reachable only by direct PostgREST/SQL | carrier_invoices, payments, agreements, ledgers | -- | n/a (DB-only surface) |
| 10 | Legacy invoices, payments, AR, collections, settlements, advances, expenses, fuel, maintenance | `invoices/`, `payments/`, `accounts-receivable`, `collections/actions.ts` (18), `settlements/actions.ts` (29), `driver-settlements/actions.ts`, `advances/`, `expenses/`, `fuel/`, `maintenance/` | many tables | yes | **no** |
| 11 | Onboarding / public token routes | `carrier-onboarding/*`, `driver-onboarding/*`, `api/driver-application/{submit,upload}` (anon RPC `submit_driver_application`) | onboarding, applications, documents | yes | **no** |
| 12 | Settings, profile-share, email, brokers/customers/documents | `settings/actions.ts`, `settings/email`, `profile-share`, `brokers`, `customers`, `documents` | org settings, sharing, email logs | yes | **no** |
| 13 | Inbound webhooks | `api/webhooks/stripe` (subscription state RPCs), `api/webhooks/resend` (email_send_log*), `api/integrations/quickbooks/callback` (3 RPCs) | billing_records, organization_subscriptions, email logs, integration state | yes | **no** |
| 14 | Email send / resolve | `api/email/send` (insert email_send_log, reads invoices/statements), `api/email/resolve` | email_send_log | yes | **no** |
| 15 | Platform admin | `(superadmin)/admin/**` (creates users/orgs via `auth.admin`) | auth + platform tables | yes | **no** |
| 16 | Auth flows | `login, signup, verify-email, reset-password, forgot-*`, `auth/callback` | Supabase Auth (GoTrue) internal tables, profile creation trigger | Auth service | **no** |
| 17 | **Direct browser / API access** | The anon key and every user's JWT are in the browser; `lib/supabase/client.ts` is used by `components/tracking/live-map.tsx` (realtime read). Any holder of a valid session can call PostgREST tables and **every public RPC** directly, bypassing all UI/route code. Stale open browser tabs keep their JWT. | anything RLS/grants allow | -- | **no** (application code cannot stop this) |
| 18 | Database-internal writers | `pg_cron` job `sync-time-based-exceptions` (every 5 min, 0063), DB triggers (auto-invoice on delivery, financial sync, guards), Supabase Auth/Storage/Realtime services (own roles) | operational_exceptions, invoices, activity_logs, auth.*, storage.objects | -- | **no** |
| 19 | Storage uploads | `storage.from(...)` in ~12 action/route files | storage.objects | -- | **no** |

There is no `vercel.json`, no Supabase Edge Functions directory and no CI/CD migration runner. No direct database connection string is used by the application (all access is through the Supabase API). **UNVERIFIED (needs a read-only look at production):** which login roles the API/pooler use (`authenticator` expected), whether other cron jobs exist in `cron.job`, and whether anything else (BI tools, other services) connects with write access. The runbook adds the read-only queries for this.

## 2. Options compared
| | 1. Centralised app maintenance mode (middleware) | 2. Temporary maintenance deployment | 3. Database-level write protection | 4. Combined (1 + 3) |
|---|---|---|---|---|
| Stops all app writers (server actions, route handlers, webhooks, driver portal) | yes, at one choke point, no per-route list | yes (nothing runs) | yes (every write fails in the DB) | yes |
| Stops **direct PostgREST / RPC / stale JWT / service-role** writes | **no** | **no** (Supabase API stays public) | **yes** | yes |
| Stops DB-internal writers (pg_cron, triggers) | no | no | writes by API roles yes; cron runs as another role -> must be paused separately | yes with the cron pause |
| Clear user message | yes (503 + banner) | yes (static page) | **no** -- raw "cannot execute ... in a read-only transaction" | yes (app layer supplies it) |
| Stale open browser sessions | yes for their POST/actions | yes | yes, but with a raw error | yes |
| Auth + read-only inspection preserved | yes (GET allowed, login allowed by allow-list) | login/read lost | yes (reads and Auth service unaffected) | yes |
| Reversible | env flag + redeploy | redeploy | reset role setting | both, independently |
| Testable before migrations | yes | yes | yes | yes |
| Relies on remembering routes | no | no | no | no |

## 3. Evidence from a real PostgreSQL 17.6 container (synthetic roles mirroring Supabase's `authenticator` -> `authenticated`/`service_role` pattern; `reports17/freeze_probe.sh`)
`ALTER ROLE <api login role> SET default_transaction_read_only = on`:
* NEW sessions: direct INSERT as the `authenticated` role -> `ERROR: cannot execute INSERT in a read-only transaction`; the same for a `BYPASSRLS` service-role-like role; **a SECURITY DEFINER RPC that writes also fails**; SELECT works (read-only inspection).
* The operator's own `postgres` session is **not** affected (no `SET TRANSACTION READ WRITE` override needed by the migrations).
* A session that was already open before the change **kept writing** -> the runbook must terminate existing API-role backends after setting it.
* `ALTER ROLE ... RESET default_transaction_read_only` fully restores writes (reversible).
Not yet verified on the managed Supabase platform (permission to alter the API role, pooler behaviour) -- to be proven on a non-production Supabase project before the window.

## 4. Recommendation: option 4 (combined), in this minimal form -- NOT implemented, awaiting approval
1. **Application (clear message, one choke point):** ship *ahead of the window*, as a normal reviewed release with the flag OFF, a maintenance gate in `src/middleware.ts` keyed on one environment flag (`MAINTENANCE_MODE=1`): every non-GET/HEAD request (server actions, route handlers, webhooks, driver-portal posts) gets `503` + `Retry-After` + a fixed JSON/HTML message; GET requests continue (read-only inspection) with a banner; the authentication routes are allow-listed. No per-route edits. Stripe/Resend webhooks receiving 503 will retry.
2. **Database (authoritative backstop for direct RPC, stale JWTs, service role):** `ALTER ROLE authenticator SET default_transaction_read_only = on` (and any other API login role found by the read-only role inventory), then `pg_terminate_backend` for those roles' sessions, and `cron.alter_job(<sync-time-based-exceptions id>, active := false)`.
3. **Pre-migration proof (mandatory gate):** a battery -- one attempt per surface in section 1 (server action, route handler, driver-portal POST, webhook POST, direct PostgREST insert, direct public-RPC call with a real user JWT, pg_cron tick) -- each must be rejected, and `select count(*)` of dispatches, loads, activity_logs, ledgers, email_send_log must be identical across a 5-minute observation.
4. **Reverse:** `RESET default_transaction_read_only`, re-enable the cron job, unset `MAINTENANCE_MODE`; verify with the same battery inverted.
Why not the others alone: (1) or (2) leave every direct-API writer open; (3) alone gives users raw errors, misses cron, and cannot be proven "clean" per surface without the app layer.
Residuals to record explicitly: Supabase Auth-internal writes (sign-in timestamps, signup profile trigger) and Storage-service object writes are outside these migrations' tables; disable sign-ups in the Auth dashboard for the window if the Owner wants zero writes.
