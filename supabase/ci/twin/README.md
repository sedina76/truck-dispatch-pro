# Production twin shims

`ci/twin-db.sh` builds a disposable database from **every** migration, unchanged.
Some migrations assert production data before changing anything; each
`before_NNNN.sql` here recreates exactly what migration NNNN asserts, right
before it runs. Test-only -- never run on a real database.

| Shim | Why |
|---|---|
| before_0001 | Supabase default privileges (new tables/sequences/functions granted to anon/authenticated/service_role) |
| before_0120 | 63 organizations incl. the three grandfathered pilot orgs (by id + name), the hand-made Starter/Professional/Enterprise plans, their two subscription rows |
| before_0122 | the Essential/Pro plan ids production got from 0121 |
| before_0127 | the 64th organization (United Leather sandbox, in-flight Stripe Checkout) |
| before_0135 | `dispatches.notes` (dropped by 0069, granted by 0135; 0162 drops it again -- production never had it) |
| (0150) | twin-db.sh fills the reviewed candidate count/digest from `proposals/0150/candidate_review.sql`, as the owner did in production |

Migrations from 0120 on run as one transaction each (like the Supabase SQL
Editor) unless they carry their own BEGIN/COMMIT.

`ci/make-drift-check.sh` regenerates `supabase/DRIFT_CHECK_READONLY.sql` from
the twin; running that read-only query in production lists every schema
difference (none expected except Supabase's own `rls_auto_enable()`).
