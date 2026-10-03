#!/usr/bin/env bash
# =============================================================================
# twin-db.sh -- build a disposable "production twin" database from EVERY real
# migration (0001..latest), then run a test file against it.
#
# Several migrations (0120..0127, 0150) assert production data before they
# change anything (organization counts, pilot organizations by id, Stripe
# plan ids, a reviewed candidate digest). To apply them UNCHANGED on an empty
# database, ci/twin/before_NNNN.sql recreates exactly the state each one
# asserts, immediately before it runs. ci/twin/before_0001.sql emulates
# Supabase's default privileges. Production drift found while building the
# twin is recreated the same way (see before_0135.sql) and must be listed in
# supabase/ci/twin/README.md.
#
# Every migration from 0120 on is applied as ONE transaction (as the Supabase
# SQL Editor does) unless it carries its own BEGIN/COMMIT.
#
# NEVER point this at a real database: it creates its own throwaway cluster.
#
# Usage (as a non-root user with PostgreSQL 16+ binaries on PATH):
#   PGPORT=55800 bash supabase/ci/twin-db.sh [test.sql ...]
# Exit 0 only if the build and every test file succeed.
# =============================================================================
set -u
cd "$(dirname "$0")/.."
P=${PGPORT:-55800}
D=$(mktemp -d "${TMPDIR:-/tmp}/tdp-twin.XXXXXX")
initdb -D "$D" -U postgres --auth=trust --no-locale -E UTF8 >/dev/null || exit 9
pg_ctl -D "$D" -l "$D/log" -o "-p $P -c listen_addresses=127.0.0.1 -c unix_socket_directories= -c fsync=off" -w start >/dev/null || { cat "$D/log"; exit 9; }
trap 'pg_ctl -D "$D" -m immediate stop >/dev/null 2>&1; rm -rf "$D"' EXIT
createdb -h 127.0.0.1 -p "$P" -U postgres t || exit 9
PSQL=(psql -X -q -v ON_ERROR_STOP=1 -h 127.0.0.1 -p "$P" -U postgres -d t)
"${PSQL[@]}" -f ci/platform_stub.sql >/dev/null 2>"$D/err" || { echo "stub failed"; cat "$D/err"; exit 8; }

for m in migrations/*.sql; do
  n="$(basename "$m" | cut -c1-4)"
  if [ -f "ci/twin/before_$n.sql" ]; then
    "${PSQL[@]}" -f "ci/twin/before_$n.sql" >/dev/null 2>"$D/err" || { echo "TWIN SHIM FAILED before $n:"; grep -m3 -A2 ERROR "$D/err"; exit 7; }
  fi
  sed -E 's/create extension if not exists pg_cron[^;]*;/select 1;/I' "$m" > "$D/cur.sql"
  if [ "$n" = "0150" ]; then
    # 0150 ships fail-closed (count/digest null). Fill in the values that the
    # reviewed candidate query reports for THIS database, exactly as the
    # owner did in production.
    rv="$("${PSQL[@]}" -At -F'|' -f proposals/0150/candidate_review.sql 2>"$D/err")" || { echo "0150 candidate review failed"; cat "$D/err"; exit 7; }
    cnt="$(printf '%s\n' "$rv" | awk -F'|' '$3=="CANDIDATES (approve this count)"{print $4}')"
    dig="$(printf '%s\n' "$rv" | awk -F'|' '$3 ~ /^candidate digest/{print $4}')"
    [ -n "$cnt" ] && [ -n "$dig" ] || { echo "0150 candidate review: could not read count/digest"; exit 7; }
    sed -i -E "s/(v_expected_count  constant integer := )null;/\1$cnt;/; s/(v_expected_digest constant text    := )null;/\1'$dig';/" "$D/cur.sql"
  fi
  one=()
  if [[ ! "$n" < "0120" ]] && ! grep -qiE '^\s*begin\s*;' "$D/cur.sql"; then one=(-1); fi
  if ! "${PSQL[@]}" "${one[@]}" -f "$D/cur.sql" >/dev/null 2>"$D/err"; then
    echo "MIGRATION FAILED: $m"; grep -m1 -A3 ERROR "$D/err"; exit 7
  fi
done
echo "twin built: $(ls migrations/*.sql | wc -l) migrations applied"

rc=0
for t in "$@"; do
  if psql -X -v ON_ERROR_STOP=1 -h 127.0.0.1 -p "$P" -U postgres -d t -f "$t"; then echo "TWIN TEST PASSED: $t"; else echo "TWIN TEST FAILED: $t"; rc=1; fi
done
[ -n "${TWIN_DUMP:-}" ] && pg_dump -h 127.0.0.1 -p "$P" -U postgres -s t > "$TWIN_DUMP"
exit $rc
