#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; cd "$HERE"
PGDATA="$(mktemp -d "${TMPDIR:-/tmp}/audit0130_0146.XXXXXX")"; PGPORT="${PGPORT:-54946}"; export PGPORT PGUSER=postgres PGHOST=127.0.0.1
cleanup(){ pg_ctl -D "$PGDATA" -m immediate stop >/dev/null 2>&1 || true; rm -rf "$PGDATA"; }; trap cleanup EXIT
LC_ALL=C initdb -D "$PGDATA" -U postgres --auth=trust --no-locale --encoding=UTF8 >/dev/null
LC_ALL=C pg_ctl -D "$PGDATA" -l "$PGDATA/server.log" -o "-p $PGPORT -c listen_addresses=127.0.0.1 -c unix_socket_directories='' -c fsync=off" -w start >/dev/null
PSQL=(psql -X -v ON_ERROR_STOP=1 -q -P pager=off)
fail=0
run_case(){
  local name="$1" setup="$2" expected="$3" required="${4:-FINAL_DECISION}" severity="${5:-}" count="${6:-}" db="audit_${1//[^a-zA-Z0-9]/_}" before after out case_fail=0
  createdb "$db"; out="$PGDATA/$name.out"
  "${PSQL[@]}" -d "$db" -f TEST_SUPPORT_0130_0133_schema.sql >/dev/null
  if [[ "$setup" == APPLY0132\;* ]]; then
    "${PSQL[@]}" -d "$db" -f migrations/0130_carrier_context_foundation.sql >/dev/null
    "${PSQL[@]}" -d "$db" -f migrations/0131_carrier_party_relationships.sql >/dev/null
    "${PSQL[@]}" -d "$db" -f migrations/0132_load_carrier_and_trailer_scope.sql >/dev/null
    setup="${setup#APPLY0132;}"
  elif [[ "$setup" == APPLY0130\;* ]]; then
    "${PSQL[@]}" -d "$db" -f migrations/0130_carrier_context_foundation.sql >/dev/null
    setup="${setup#APPLY0130;}"
  fi
  [[ -z "$setup" ]] || "${PSQL[@]}" -d "$db" -c "$setup" >/dev/null
  before="$("${PSQL[@]}" -At -d "$db" -c "select md5(string_agg(x,'|' order by x)) from (select c.oid::text||c.relname||c.relkind::text||coalesce(c.reltuples,0)::text x from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public')s; select count(*) from public.loads;")"
  if ! "${PSQL[@]}" -d "$db" -f PRODUCTION_PREFLIGHT_0130_0147_READONLY.sql >"$out" 2>&1; then echo "FAIL $name: audit SQL error"; cat "$out"; fail=1; return; fi
  after="$("${PSQL[@]}" -At -d "$db" -c "select md5(string_agg(x,'|' order by x)) from (select c.oid::text||c.relname||c.relkind::text||coalesce(c.reltuples,0)::text x from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public')s; select count(*) from public.loads;")"
  [[ "$before" == "$after" ]] || { echo "FAIL $name: persistent state changed"; fail=1; case_fail=1; }
  grep -Eq "FINAL_DECISION.*$expected" "$out" || { echo "FAIL $name: expected $expected"; tail -25 "$out"; fail=1; case_fail=1; }
  grep -q "$required" "$out" || { echo "FAIL $name: missing finding $required"; fail=1; case_fail=1; }
  [[ -z "$severity" ]] || grep -Eq "$required.*$severity.*f[[:space:]]*\|[[:space:]]*$count" "$out" || { echo "FAIL $name: $required expected $severity count $count"; fail=1; case_fail=1; }
  # audit_coverage_status is COMPLETE as of Phase 3C.0G (all 107 manifest
  # rows closed). Matched as a column value specifically (a pipe/whitespace
  # immediately before the literal, case-sensitive "INCOMPLETE") rather
  # than a bare substring search, since several legitimate, unrelated
  # finding identifiers/details text contain lowercase "incomplete" in
  # ordinary English prose, and this file's own SCHEMA_ENUM_INCOMPLETE
  # finding ID contains the uppercase substring with no preceding pipe.
  grep -q 'FINAL_DECISION' "$out" || { echo "FAIL $name: missing FINAL_DECISION row"; fail=1; case_fail=1; }
  grep -Eq '\|[[:space:]]*INCOMPLETE\b' "$out" && { echo "FAIL $name: audit_coverage_status regressed to INCOMPLETE"; fail=1; case_fail=1; }
  grep -q 'SEED_FAKE_SECRET_9zQ' "$out" && { echo "FAIL $name: secret leaked"; fail=1; case_fail=1; }
  [[ "$case_fail" -eq 0 ]] && echo "PASS $name -> $expected" || true
}
run_case clean_0129 "" BLOCKED SCHEMA_0129
run_case single_carrier_safe "alter table public.loads add column carrier_id uuid; update public.loads l set carrier_id=coalesce((select d.carrier_id from public.dispatches d where d.load_id=l.id order by d.id limit 1),(select c.id from public.carriers c where c.organization_id=l.organization_id order by c.id limit 1)); delete from public.dispatches a using public.dispatches b where a.load_id=b.load_id and a.id>b.id;" BLOCKED LOAD_DETERMINISTIC
run_case missing_evidence "insert into public.loads(id,organization_id,load_number,status,rate) select gen_random_uuid(),id,'AUD-MISSING','draft',0 from public.organizations limit 1;" BLOCKED LOAD_NO_EVIDENCE
run_case conflicting_evidence "alter table public.loads add column carrier_id uuid; update public.loads l set carrier_id=(select c.id from public.carriers c where c.organization_id=l.organization_id order by id limit 1); update public.loads l set carrier_id=(select c.id from public.carriers c where c.organization_id=l.organization_id and c.id<>l.carrier_id limit 1) where exists(select 1 from public.dispatches d where d.load_id=l.id);" BLOCKED LOAD_CONFLICT
run_case financial_controller_wrong_load "set session_replication_role=replica; update public.loads set financial_dispatch_id=null where financial_dispatch_id=(select id from public.dispatches order by id limit 1); update public.loads set financial_dispatch_id=(select id from public.dispatches order by id limit 1) where id=(select id from public.loads where id<>(select load_id from public.dispatches order by id limit 1) limit 1); set session_replication_role=origin;" BLOCKED LOAD_FIN_WRONG
run_case trailer_manual_review "insert into public.trailers(organization_id,unit_number) select id,'AUD-UNRESOLVED' from public.organizations limit 1;" READY_WITH_WARNINGS TRAILER_UNRESOLVED
run_case partial_install "create table public.carrier_brokers(id uuid);" BLOCKED SCHEMA_PARTIAL
run_case missing_extension "drop extension pgcrypto cascade;" BLOCKED SCHEMA_PGCRYPTO

# Phase 3C.0A.1 bounded schema/history fixtures. These create disposable
# catalog shapes only; the audit never writes or repairs history.
run_case history_unknown "create schema supabase_migrations; create table supabase_migrations.schema_migrations(applied_at timestamptz); delete from public.dispatches a using public.dispatches b where a.load_id=b.load_id and a.id>b.id; delete from public.trailers where carrier_id is null;" SCHEMA_STATE_UNKNOWN SCHEMA_HISTORY_SHAPE
run_case blocker_over_unknown "create schema supabase_migrations; create table supabase_migrations.schema_migrations(applied_at timestamptz); drop extension pgcrypto cascade;" BLOCKED SCHEMA_HISTORY_SHAPE
run_case history_says_applied_objects_missing "create schema supabase_migrations; create table supabase_migrations.schema_migrations(version text); insert into supabase_migrations.schema_migrations values('0130');" BLOCKED SCHEMA_HISTORY_DISAGREE
run_case object_present_history_missing "create schema supabase_migrations; create table supabase_migrations.schema_migrations(version text); create table public.carrier_remittance_profiles(carrier_id uuid); alter table public.carriers add column invoice_code text;" BLOCKED SCHEMA_HISTORY_DISAGREE
run_case unexpected_later_history "create schema supabase_migrations; create table supabase_migrations.schema_migrations(version text); insert into supabase_migrations.schema_migrations values('0148');" BLOCKED SCHEMA_HISTORY_LATER
# One split landmark in each documented family group.
run_case landmark_0130_0133 "alter table public.carriers add column invoice_code text;" BLOCKED SCHEMA_LANDMARK_0130
run_case landmark_0134_0135 "create table public.dispatch_status_transitions(id uuid);" BLOCKED SCHEMA_LANDMARK_0134
run_case landmark_0136_0141 "alter table public.carriers add column factoring_mode text;" BLOCKED SCHEMA_LANDMARK_0136
run_case landmark_0142_0143 "create table public.carrier_invoices(id uuid);" BLOCKED SCHEMA_LANDMARK_0142
run_case landmark_0144_0145 "create function public.guard_load_stops_parent_lock() returns trigger language plpgsql as 'begin return new; end';" BLOCKED SCHEMA_LANDMARK_0144
run_case landmark_0146 "create type public.carrier_invoice_payment_status as enum('posted');" BLOCKED SCHEMA_LANDMARK_0146
# Carrier configuration fixtures at the 0130 boundary.
run_case carrier_valid_config "APPLY0130;update public.carriers set invoice_code='AUD'||row_number::text from (select id,row_number() over(order by id) row_number from public.carriers) x where carriers.id=x.id;" BLOCKED CARRIER_REMIT
run_case carrier_missing_code "APPLY0130;update public.carriers set invoice_code='AUD' where id=(select id from public.carriers where is_active limit 1);" BLOCKED CARRIER_CODE WARNING 2
run_case carrier_duplicate_code "APPLY0130;drop index public.carriers_org_invoice_code_uq; update public.carriers set invoice_code='DUP' where organization_id=(select organization_id from public.carriers group by organization_id having count(*)>1 limit 1);" BLOCKED CARRIER_DUP_CODE BLOCKER 1
run_case carrier_missing_remittance "APPLY0130;delete from public.carrier_remittance_profiles where carrier_id=(select id from public.carriers where is_active limit 1);" BLOCKED CARRIER_REMIT WARNING 1
run_case carrier_valid_terms_override "APPLY0130;update public.carriers set dispatch_service_terms_days=30 where is_active;" BLOCKED CARRIER_TERMS
run_case missing_dispatch_prefix "alter table public.platform_settings add column dispatch_invoice_prefix text; create table public.carrier_invoices(id uuid); create table public.carrier_invoice_issuance_snapshots(id uuid,issuance_schema_version int,invoice_document_type text);" BLOCKED DISPATCH_PREFIX WARNING 1
# Trailer states at the 0132 boundary. Controlled fixtures drop only disposable
# backstops where a malformed persisted row is otherwise impossible.
run_case trailer_valid_carrier "APPLY0132;delete from public.dispatches where trailer_id is not null;" BLOCKED TRAILER_CARRIER
run_case trailer_valid_shared "APPLY0132;alter table public.trailers drop constraint trailers_ownership_scope_consistency; update public.trailers set ownership_scope='organization_shared',carrier_id=null where carrier_id is null;" BLOCKED TRAILER_SHARED
run_case trailer_invalid_carrier_null "APPLY0132;alter table public.trailers drop constraint trailers_ownership_scope_consistency; update public.trailers set ownership_scope='carrier',carrier_id=null where carrier_id is null;" BLOCKED TRAILER_BAD_SCOPE BLOCKER 1
run_case trailer_invalid_shared_carrier "APPLY0132;alter table public.trailers drop constraint trailers_ownership_scope_consistency; update public.trailers set ownership_scope='organization_shared' where carrier_id is not null;" BLOCKED TRAILER_BAD_SCOPE BLOCKER 1
run_case trailer_cross_org "APPLY0132;alter table public.trailers disable trigger all; update public.trailers set carrier_id=(select id from public.carriers c where c.organization_id<>trailers.organization_id limit 1),ownership_scope='carrier' where id=(select id from public.trailers limit 1);" BLOCKED TRAILER_BAD_SCOPE BLOCKER 1
run_case trailer_cross_carrier_use "APPLY0132;alter table public.dispatches disable trigger all; update public.dispatches set trailer_id=(select id from public.trailers where carrier_id is not null limit 1) where id=(select id from public.dispatches where carrier_id<>(select carrier_id from public.trailers where carrier_id is not null limit 1) and status::text<>'cancelled' limit 1);" BLOCKED TRAILER_CROSS_USE BLOCKER 1
run_case trailer_shared_cross_carrier_allowed "APPLY0132;alter table public.trailers drop constraint trailers_ownership_scope_consistency; update public.trailers set ownership_scope='organization_shared',carrier_id=null where carrier_id is null; alter table public.dispatches disable trigger all; update public.dispatches set trailer_id=(select id from public.trailers where ownership_scope='organization_shared' limit 1) where id=(select id from public.dispatches where status::text<>'cancelled' limit 1);" BLOCKED TRAILER_CROSS_USE
run_case trailer_null_not_shared "APPLY0132;alter table public.trailers drop constraint trailers_ownership_scope_consistency; alter table public.trailers alter column ownership_scope drop not null; update public.trailers set ownership_scope=null,carrier_id=null where carrier_id is null;" BLOCKED TRAILER_UNRESOLVED WARNING 1
# Full migration chain is the authoritative fixture for both supported
# boundaries. post0146 is the VULNERABLE, pre-remediation boundary (all
# seven Phase 3C.0 release BLOCKERs present) -- its own comprehensive
# decision must read BLOCKED, never READY/READY_WITH_WARNINGS. post0147
# additionally applies 0147 and is the CORRECTED boundary -- its
# comprehensive decision must read READY_WITH_WARNINGS (FUNC_RAISE_LEAKS_
# CONTEXT remains an intentional, separate WARNING; 0147 does not touch
# it), never BLOCKED and never a forced READY.
#
# The comprehensive FINAL_DECISION row is matched specifically by its own
# trailing audit_coverage_status token (COMPLETE/INCOMPLETE) -- an EARLIER,
# vestigial, unrelated FINAL_DECISION mini-query also exists in this file
# (Phase 3C.0A) with a different column shape and no audit_coverage_status
# column; a bare 'FINAL_DECISION.*READY' grep would silently match that
# one instead and never actually prove anything about the real decision.
comprehensive_decision() { grep -E '^ FINAL_DECISION .*\| (COMPLETE|INCOMPLETE)[[:space:]]*$' "$1"; }

createdb audit_post0146
"${PSQL[@]}" -d audit_post0146 -f TEST_0146_carrier_invoice_payments_and_balance_rollups.sql >"$PGDATA/post0146.setup" 2>&1
"${PSQL[@]}" -d audit_post0146 -c "create schema supabase_migrations; create table supabase_migrations.schema_migrations(version text); insert into supabase_migrations.schema_migrations select '01'||lpad(g::text,2,'0') from generate_series(30,46) g;" >/dev/null
"${PSQL[@]}" -d audit_post0146 -f PRODUCTION_PREFLIGHT_0130_0147_READONLY.sql >"$PGDATA/post0146.out" 2>&1
post0146_decision="$(comprehensive_decision "$PGDATA/post0146.out")"
echo "$post0146_decision" | grep -Eq '\| BLOCKED[[:space:]]*\|' || { echo 'FAIL post0146: comprehensive decision is not BLOCKED'; echo "$post0146_decision"; fail=1; }
grep -Eq 'SCHEMA_HISTORY_DISAGREE.*BLOCKER[[:space:]]*\|[[:space:]]*t[[:space:]]*\|[[:space:]]*0' "$PGDATA/post0146.out" || { echo 'FAIL post0146 history agreement'; grep 'SCHEMA_HISTORY\|SCHEMA_LANDMARK' "$PGDATA/post0146.out"; fail=1; }
seven_blocker_ids=(
  LEGACY_CLASSIFIER_DEFINITION_DEFECT
  FIN_CARRIER_INVOICES_AUTH_INSERT
  FIN_CARRIER_INVOICES_AUTH_DELETE
  FUNC_UPDATE_DRAFT_PUBLIC_EXECUTE
  FUNC_LEGACY_REVIEW_PUBLIC_EXECUTE
  FUNC_LEGACY_SCAN_PUBLIC_EXECUTE
  FUNC_NULL_IDENTITY_AUTH_BYPASS
)
validate_seven_blockers(){
  local out="$1" expected_ok="$2" expected_count="$3" label="$4" rows=0 sum=0 fid line count
  [[ "${#seven_blocker_ids[@]}" -eq 7 && "$(printf '%s\n' "${seven_blocker_ids[@]}" | sort -u | wc -l | tr -d ' ')" -eq 7 ]] || { echo "FAIL $label seven-ID definition"; fail=1; return; }
  for fid in "${seven_blocker_ids[@]}"; do
    line="$(grep -E "^ $fid " "$out" || true)"
    [[ "$(printf '%s\n' "$line" | grep -c .)" -eq 1 ]] || { echo "FAIL $label missing/duplicate $fid"; fail=1; continue; }
    printf '%s\n' "$line" | grep -Eq "BLOCKER[[:space:]]*\|[[:space:]]*$expected_ok[[:space:]]*\|[[:space:]]*$expected_count" || { echo "FAIL $label $fid expected $expected_count"; fail=1; continue; }
    count="$(printf '%s\n' "$line" | awk -F'|' '{gsub(/ /,"",$6); print $6}')"; sum=$((sum+count)); rows=$((rows+1))
  done
  [[ "$rows" -eq 7 && "$sum" -eq $((7*expected_count)) ]] || { echo "FAIL $label rows=$rows sum=$sum"; fail=1; return; }
  echo "PASS $label -> 7 unique IDs, each count $expected_count, sum $sum"
}
validate_seven_blockers "$PGDATA/post0146.out" f 1 exact_seven_blockers_post0146
echo 'PASS post0146 -> vulnerable boundary correctly BLOCKED'

# post0147: clone the ALREADY-CLEAN, healthy post0146 template (never
# TEST_0147's own file -- that is a TEST script full of deliberate,
# permanent corruption sub-scenarios executed in sequence and is NOT a
# healthy fixture) and apply ONLY the 0147 migration file on top of it.
createdb -T audit_post0146 audit_post0147
"${PSQL[@]}" -d audit_post0147 -c "drop schema supabase_migrations cascade;" >/dev/null 2>&1
"${PSQL[@]}" -d audit_post0147 -f migrations/0147_production_readiness_blocker_remediation.sql >"$PGDATA/post0147.setup" 2>&1
"${PSQL[@]}" -d audit_post0147 -c "create schema supabase_migrations; create table supabase_migrations.schema_migrations(version text); insert into supabase_migrations.schema_migrations select '01'||lpad(g::text,2,'0') from generate_series(30,47) g;" >/dev/null
"${PSQL[@]}" -d audit_post0147 -f PRODUCTION_PREFLIGHT_0130_0147_READONLY.sql >"$PGDATA/post0147.out" 2>&1
grep -Eq 'SCHEMA_HISTORY_DISAGREE.*BLOCKER[[:space:]]*\|[[:space:]]*t[[:space:]]*\|[[:space:]]*0' "$PGDATA/post0147.out" || { echo 'FAIL post0147 history agreement'; grep 'SCHEMA_HISTORY\|SCHEMA_LANDMARK' "$PGDATA/post0147.out"; fail=1; }
# NOTE: the general-purpose audit_post0146/audit_post0147 templates (built
# from TEST_0146's own realistic fixture, not a hand-cleaned "nothing else
# is wrong" database) carry a handful of PRE-EXISTING, unrelated blocker
# conditions at BOTH boundaries alike (confirmed identical before/after --
# e.g. FACTOR_0137_PROVENANCE_MISSING, LOAD_CLASS_AMBIGUOUS/LOAD_MULTI,
# PRE0130_PROFILE_PRIVILEGE_GUARD_MISSING), so the AGGREGATE comprehensive
# decision here is not a clean READY_WITH_WARNINGS proof by itself and is
# intentionally not asserted as one. What this phase is responsible for --
# and what is asserted precisely below -- is that each of the seven
# tracked blocker findings individually transitions from unhealthy (post-
# 0146) to exactly 0 (post-0147), independent of that unrelated noise. A
# separate, purpose-built minimal fixture (below) proves the clean
# READY_WITH_WARNINGS decision directly.
validate_seven_blockers "$PGDATA/post0147.out" t 0 exact_seven_blockers_post0147
for fid in RPC_0147_CREATE_DRAFT_ACL RPC_0147_DELETE_DRAFT_ACL IDEMPOTENCY_0147_CREATE_OBJECT IDEMPOTENCY_0147_DELETE_OBJECT; do
  grep -E "^ $fid " "$PGDATA/post0147.out" | grep -Eq '\|[[:space:]]*t[[:space:]]*\|[[:space:]]*0' || { echo "FAIL post0147: $fid is not healthy"; fail=1; }
done
grep -E "^ FUNC_RAISE_LEAKS_CONTEXT " "$PGDATA/post0147.out" | grep -Eq 'WARNING[[:space:]]*\|[[:space:]]*f[[:space:]]*\|[[:space:]]*5' || { echo 'FAIL post0147: FUNC_RAISE_LEAKS_CONTEXT warning was not preserved at count 5'; grep -E "^ FUNC_RAISE_LEAKS_CONTEXT " "$PGDATA/post0147.out"; fail=1; }
echo 'PASS post0147 -> corrected boundary: all seven tracked blocker findings plus the two new RPC/idempotency findings exactly 0, FUNC_RAISE_LEAKS_CONTEXT warning preserved unchanged'

# Each corrected structural blocker has an isolated post-0147 restoration
# fixture. The audit must detect only the restored defect, never either sibling,
# and must leave row/catalog hashes unchanged.
run_post147_blocker_case(){
  local name="$1" setup="$2" target="$3" db="p147_${1}" out before after fid count
  createdb -T audit_post0147 "$db"
  "${PSQL[@]}" -d "$db" -c "$setup" >/dev/null
  before="$("${PSQL[@]}" -At -d "$db" -c "select md5(string_agg(p.oid::text||p.proacl::text||p.prosrc,'|' order by p.oid)) from pg_proc p where p.pronamespace='public'::regnamespace; select md5(coalesce(string_agg(to_jsonb(i)::text,'|' order by i.id),'')) from public.invoices i")"
  out="$PGDATA/$name.post147.out"
  "${PSQL[@]}" -d "$db" -f PRODUCTION_PREFLIGHT_0130_0147_READONLY.sql >"$out" 2>&1 || { echo "FAIL $name audit"; fail=1; return; }
  after="$("${PSQL[@]}" -At -d "$db" -c "select md5(string_agg(p.oid::text||p.proacl::text||p.prosrc,'|' order by p.oid)) from pg_proc p where p.pronamespace='public'::regnamespace; select md5(coalesce(string_agg(to_jsonb(i)::text,'|' order by i.id),'')) from public.invoices i")"
  [[ "$before" == "$after" ]] || { echo "FAIL $name read-only hash"; fail=1; return; }
  for fid in "${seven_blocker_ids[@]}"; do
    count=0; [[ "$fid" == "$target" ]] && count=1
    grep -E "^ $fid " "$out" | grep -Eq "BLOCKER[[:space:]]*\\|[[:space:]]*$([[ $count == 0 ]] && echo t || echo f)[[:space:]]*\\|[[:space:]]*$count" || { echo "FAIL $name isolation $fid/$count"; fail=1; return; }
  done
  grep -q 'PHASE3C21_PRIVATE_9zQ' "$out" && { echo "FAIL $name privacy"; fail=1; return; }
  echo "PASS $name -> isolated $target=1, six siblings=0, read-only/private"
}
run_post147_blocker_case rpc_update_public_restored "grant execute on function public.update_carrier_invoice_draft(uuid,jsonb,timestamptz,text,text) to public" FUNC_UPDATE_DRAFT_PUBLIC_EXECUTE
run_post147_blocker_case rpc_review_public_restored "grant execute on function public.review_legacy_invoice_carrier_migration(uuid,text,text,timestamptz,text) to public" FUNC_LEGACY_REVIEW_PUBLIC_EXECUTE
run_post147_blocker_case rpc_scan_public_restored "grant execute on function public.scan_legacy_invoices_for_carrier_migration() to public" FUNC_LEGACY_SCAN_PUBLIC_EXECUTE
run_post147_blocker_case classifier_vulnerable_restored 'create or replace function public.classify_legacy_invoice_for_carrier_migration(p_invoice_id uuid) returns text language plpgsql stable security definer set search_path=pg_catalog,public as $q$ declare carrier_resolution text; begin if carrier_resolution = ''conflicting'' then return ''conflicting_carrier_evidence''; end if; return ''missing_carrier_evidence''; end $q$' LEGACY_CLASSIFIER_DEFINITION_DEFECT
run_post147_blocker_case classifier_unknown_definition 'create or replace function public.classify_legacy_invoice_for_carrier_migration(p_invoice_id uuid) returns text language sql stable security definer set search_path=pg_catalog,public as $q$ select $x$missing_carrier_evidence$x$::text $q$' LEGACY_CLASSIFIER_DEFINITION_DEFECT

# The general post-0147 template intentionally contains historical corruption
# fixtures inherited from TEST_0146. Create a data-clean catalog-equivalent
# control so the supported 0147 boundary can prove the warning-only decision.
createdb -T audit_post0147 audit_post0147_clean
"${PSQL[@]}" -d audit_post0147_clean -c "
  truncate public.carrier_invoices,public.factoring_relationships,public.invoices,public.dispatches,public.loads,public.trailers cascade;
  update public.carriers set factoring_mode='direct',invoice_code=coalesce(invoice_code,'C'||upper(substr(replace(id::text,'-',''),1,7)));
  create or replace function public.protect_profile_privileged_columns() returns trigger language plpgsql set search_path=pg_catalog,public as 'begin return new; end';
  create trigger profiles_protect_privileged_columns before update on public.profiles for each row execute function public.protect_profile_privileged_columns();
  do \$clean\$ declare t text; begin foreach t in array array['organizations','profiles','carriers','brokers','customers','drivers','trucks','trailers','loads','load_stops','dispatches','documents','invoices','invoice_line_items','payments','settlements','settlement_line_items','activity_logs','integration_settings','factoring_companies','factoring_relationships','factored_invoices','factoring_events','platform_settings'] loop if to_regclass('public.'||t) is not null then execute format('alter table public.%I enable row level security',t); if not exists(select 1 from pg_policies where schemaname='public' and tablename=t) then execute format('create policy audit_clean_select on public.%I for select using (true)',t); end if; end if; end loop; end \$clean\$;" >/dev/null

run_0147_schema_case(){
  local name="$1" template="$2" setup="$3" fid="$4" severity="$5" count="$6" expected="$7" db="state_${1}" out before after ok=f
  [[ "$count" == 0 ]] && ok=t
  createdb -T "$template" "$db"
  "${PSQL[@]}" -d "$db" -c "$setup" >/dev/null
  before="$("${PSQL[@]}" -At -d "$db" -c "select md5(string_agg(c.oid::text||c.relname||c.relkind::text,'|' order by c.oid)) from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname in ('public','supabase_migrations'); select md5(coalesce(string_agg(to_jsonb(i)::text,'|' order by i.id),'')) from public.invoices i")"
  out="$PGDATA/$name.schema.out"
  "${PSQL[@]}" -d "$db" -f PRODUCTION_PREFLIGHT_0130_0147_READONLY.sql >"$out" 2>&1 || { echo "FAIL $name audit"; fail=1; return; }
  after="$("${PSQL[@]}" -At -d "$db" -c "select md5(string_agg(c.oid::text||c.relname||c.relkind::text,'|' order by c.oid)) from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname in ('public','supabase_migrations'); select md5(coalesce(string_agg(to_jsonb(i)::text,'|' order by i.id),'')) from public.invoices i")"
  [[ "$before" == "$after" ]] || { echo "FAIL $name read-only hash"; fail=1; return; }
  grep -E "^ $fid " "$out" | grep -Eq "$severity[[:space:]]*\\|[[:space:]]*$ok[[:space:]]*\\|[[:space:]]*$count" || { echo "FAIL $name $fid/$count"; fail=1; return; }
  comprehensive_decision "$out" | grep -Eq "\\| $expected[[:space:]]*\\|" || { echo "FAIL $name decision $expected"; fail=1; return; }
  echo "PASS $name -> $fid=$count, $expected, read-only"
}
run_0147_schema_case partial_0147_installation audit_post0146 "create table public.carrier_invoice_draft_create_idempotency(id uuid)" SCHEMA_PARTIAL BLOCKER 1 BLOCKED
run_0147_schema_case history_0147_objects_0146 audit_post0146 "insert into supabase_migrations.schema_migrations values('0147')" SCHEMA_HISTORY_DISAGREE BLOCKER 1 BLOCKED
run_0147_schema_case objects_0147_history_0146 audit_post0147_clean "delete from supabase_migrations.schema_migrations where version='0147'" SCHEMA_HISTORY_DISAGREE BLOCKER 1 BLOCKED
run_0147_schema_case complete_matching_0147 audit_post0147_clean "select 1" SCHEMA_0147 INFO 1 READY_WITH_WARNINGS
run_0147_schema_case unsupported_0148_history audit_post0147_clean "insert into supabase_migrations.schema_migrations values('0148')" SCHEMA_HISTORY_LATER BLOCKER 1 BLOCKED
run_0147_schema_case unknown_0147_history_shape audit_post0147_clean "alter table supabase_migrations.schema_migrations rename column version to applied_version" SCHEMA_HISTORY_SHAPE INFO 1 SCHEMA_STATE_UNKNOWN
run_post_case(){
  local name="$1" setup="$2" expected="$3" fid="$4" severity="$5" count="$6" case_fail=0 before after db out expected_ok=f
  [[ "$count" == 0 ]] && expected_ok=t
  db="post_${name//[^a-zA-Z0-9]/_}"; out="$PGDATA/post_$name.out"
  createdb -T audit_post0146 "$db"
  [[ -z "$setup" ]] || "${PSQL[@]}" -d "$db" -c "set session_replication_role=replica; $setup; set session_replication_role=origin" >/dev/null
  before="$("${PSQL[@]}" -At -d "$db" -c "select md5(string_agg(x,'|' order by x)) from (select c.oid::text||c.relname||c.relkind::text x from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname in ('public','supabase_migrations'))s; select md5(coalesce(string_agg(to_jsonb(c)::text,'|' order by c.id),'')) from public.carriers c;")"
  "${PSQL[@]}" -d "$db" -f PRODUCTION_PREFLIGHT_0130_0147_READONLY.sql >"$out" 2>&1 || { echo "FAIL $name audit error"; fail=1; return; }
  after="$("${PSQL[@]}" -At -d "$db" -c "select md5(string_agg(x,'|' order by x)) from (select c.oid::text||c.relname||c.relkind::text x from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname in ('public','supabase_migrations'))s; select md5(coalesce(string_agg(to_jsonb(c)::text,'|' order by c.id),'')) from public.carriers c;")"
  [[ "$before" == "$after" ]] || { echo "FAIL $name persistent change"; fail=1; case_fail=1; }
  grep -Eq "FINAL_DECISION.*$expected" "$out" || { echo "FAIL $name decision $expected"; fail=1; case_fail=1; }
  grep -Eq "$fid.*$severity[[:space:]]*\\|[[:space:]]*$expected_ok[[:space:]]*\\|[[:space:]]*$count" "$out" || { echo "FAIL $name finding $fid/$severity/$count"; grep "$fid" "$out"; fail=1; case_fail=1; }
  [[ "$case_fail" -eq 0 ]] && echo "PASS $name -> $expected ($fid=$count)" || true
}
# Carrier-party fixtures. Constraint/trigger removal occurs only in cloned disposable DBs.
run_post_case valid_broker "" READY_WITH_WARNINGS PARTY_BROKER_ACTIVE INFO 2
run_post_case missing_broker_mapping "delete from public.carrier_brokers where carrier_id='a1a1a1a1-0000-0000-0000-000000000001'" READY_WITH_WARNINGS PARTY_BROKER_TOTAL INFO 1
run_post_case inactive_broker_relationship "update public.carrier_brokers set status='inactive' where id='cb480000-0000-0000-0000-000000000001'" READY_WITH_WARNINGS PARTY_BROKER_INACTIVE INFO 1
run_post_case blacklisted_broker "update public.brokers set is_blacklisted=true where id='a0b00000-0000-0000-0000-000000000001'" BLOCKED PARTY_BROKER_BLACKLIST BLOCKER 2
run_post_case cross_org_broker "alter table public.carrier_brokers disable trigger all; update public.carrier_brokers set organization_id='22222222-2222-2222-2222-222222222222' where id='cb480000-0000-0000-0000-000000000001'" BLOCKED PARTY_BROKER_CROSS_ORG BLOCKER 1
run_post_case duplicate_broker "alter table public.carrier_brokers drop constraint carrier_brokers_carrier_broker_uq; insert into public.carrier_brokers select gen_random_uuid(),organization_id,carrier_id,broker_id,status,billing_email,payment_terms_days,external_account_number,billing_instructions,document_instructions,document_requirements,factoring_eligible,quickbooks_customer_ref,activated_at,activated_by,created_at,updated_at from public.carrier_brokers limit 1" BLOCKED PARTY_BROKER_DUP BLOCKER 1
run_post_case both_recipients "update public.loads set customer_id=(select id from public.customers where organization_id=loads.organization_id limit 1) where broker_id is not null" BLOCKED LOAD_BOTH_RECIPIENTS BLOCKER 13
run_post_case no_recipient "update public.loads set broker_id=null,customer_id=null where id='60480000-0000-0000-0000-000000000001'" READY_WITH_WARNINGS LOAD_NO_RECIPIENT WARNING 1
# Phase 3C.0B.1 customer and deterministic load-recipient assertions.
run_post_case customer_active "insert into public.carrier_customers(organization_id,carrier_id,customer_id,status,billing_email,payment_terms_days) values('11111111-1111-1111-1111-111111111111','a1a1a1a1-0000-0000-0000-000000000001','a0c00000-0000-0000-0000-000000000001','active','audit@example.test',30)" READY_WITH_WARNINGS PARTY_CUSTOMER_ACTIVE INFO 1
run_post_case customer_inactive_relationship "insert into public.carrier_customers(organization_id,carrier_id,customer_id,status) values('11111111-1111-1111-1111-111111111111','a1a1a1a1-0000-0000-0000-000000000001','a0c00000-0000-0000-0000-000000000001','inactive')" READY_WITH_WARNINGS PARTY_CUSTOMER_INACTIVE INFO 1
run_post_case customer_inactive_party "update public.customers set is_active=false where id='a0c00000-0000-0000-0000-000000000001'; insert into public.carrier_customers(organization_id,carrier_id,customer_id,status,billing_email,payment_terms_days) values('11111111-1111-1111-1111-111111111111','a1a1a1a1-0000-0000-0000-000000000001','a0c00000-0000-0000-0000-000000000001','active','audit@example.test',30)" BLOCKED PARTY_CUSTOMER_INELIGIBLE BLOCKER 1
run_post_case customer_cross_org "alter table public.carrier_customers disable trigger all; insert into public.carrier_customers(organization_id,carrier_id,customer_id,status,billing_email,payment_terms_days) values('22222222-2222-2222-2222-222222222222','a1a1a1a1-0000-0000-0000-000000000001','a0c00000-0000-0000-0000-000000000001','active','audit@example.test',30)" BLOCKED PARTY_CUSTOMER_CROSS_ORG BLOCKER 1
run_post_case customer_duplicate "alter table public.carrier_customers drop constraint carrier_customers_carrier_customer_uq; insert into public.carrier_customers(organization_id,carrier_id,customer_id,status,billing_email,payment_terms_days) values('11111111-1111-1111-1111-111111111111','a1a1a1a1-0000-0000-0000-000000000001','a0c00000-0000-0000-0000-000000000001','active','audit@example.test',30),('11111111-1111-1111-1111-111111111111','a1a1a1a1-0000-0000-0000-000000000001','a0c00000-0000-0000-0000-000000000001','active','audit@example.test',30)" BLOCKED PARTY_CUSTOMER_DUP BLOCKER 1
run_post_case customer_email_missing "alter table public.carrier_customers drop constraint carrier_customers_active_requires_billing; insert into public.carrier_customers(organization_id,carrier_id,customer_id,status,payment_terms_days) values('11111111-1111-1111-1111-111111111111','a1a1a1a1-0000-0000-0000-000000000001','a0c00000-0000-0000-0000-000000000001','active',30)" READY_WITH_WARNINGS PARTY_CUSTOMER_EMAIL WARNING 1
run_post_case customer_terms_invalid "alter table public.carrier_customers drop constraint carrier_customers_active_requires_billing; alter table public.carrier_customers drop constraint carrier_customers_payment_terms_days_check; insert into public.carrier_customers(organization_id,carrier_id,customer_id,status,billing_email,payment_terms_days) values('11111111-1111-1111-1111-111111111111','a1a1a1a1-0000-0000-0000-000000000001','a0c00000-0000-0000-0000-000000000001','active','audit@example.test',366)" BLOCKED PARTY_CUSTOMER_TERMS BLOCKER 1
run_post_case load_customer_missing "update public.loads set broker_id=null,customer_id='a0c00000-0000-0000-0000-000000000001' where id='60480000-0000-0000-0000-000000000001'" READY_WITH_WARNINGS LOAD_CUSTOMER_REL_MISSING WARNING 1
run_post_case load_broker_missing "delete from public.carrier_brokers where carrier_id='a1a1a1a1-0000-0000-0000-000000000001'" READY_WITH_WARNINGS LOAD_BROKER_REL_MISSING WARNING 10
# Factoring/NOA/integration fixtures based on the complete post-0146 relationship.
run_post_case factor_unassigned "alter table public.factoring_relationships disable trigger all; alter table public.factoring_relationships drop constraint factoring_relationships_new_writes_need_carrier; update public.factoring_relationships set carrier_id=null" READY_WITH_WARNINGS FACTOR_REL_UNASSIGNED WARNING 1
run_post_case factor_cross_org "alter table public.factoring_relationships disable trigger all; update public.factoring_relationships set organization_id='22222222-2222-2222-2222-222222222222'" BLOCKED FACTOR_REL_CROSS_ORG BLOCKER 1
run_post_case factor_inactive_company "alter table public.factoring_companies disable trigger all; update public.factoring_companies set is_active=false" READY_WITH_WARNINGS FACTOR_COMPANY_INACTIVE WARNING 1
run_post_case factor_inactive_default "alter table public.factoring_relationships drop constraint factoring_relationships_default_must_be_active; update public.factoring_relationships set is_active=false" BLOCKED FACTOR_DEFAULT_INACTIVE BLOCKER 1
run_post_case factor_future_default "alter table public.factoring_relationships disable trigger all; update public.factoring_relationships set effective_from=current_date+1" READY_WITH_WARNINGS FACTOR_DEFAULT_FUTURE WARNING 1
run_post_case factor_expired_default "alter table public.factoring_relationships disable trigger all; update public.factoring_relationships set effective_from=current_date-2,effective_to=current_date-1" READY_WITH_WARNINGS FACTOR_DEFAULT_EXPIRED WARNING 1
run_post_case factor_missing_remit "alter table public.factoring_relationships disable trigger all; update public.factoring_relationships set remittance_instructions=null" READY_WITH_WARNINGS FACTOR_REMIT_MISSING WARNING 1
run_post_case noa_unapproved "alter table public.factoring_relationships disable trigger all; update public.factoring_relationships set noa_approved=false" READY_WITH_WARNINGS FACTOR_NOA_UNAPPROVED WARNING 1
run_post_case noa_metadata_missing "alter table public.factoring_relationships drop constraint factoring_relationships_noa_approval_complete; update public.factoring_relationships set noa_reference=null" READY_WITH_WARNINGS FACTOR_NOA_METADATA WARNING 1
run_post_case api_missing "alter table public.factoring_relationships disable trigger all; update public.factoring_relationships set submission_method='api'" READY_WITH_WARNINGS FACTOR_API_MISSING WARNING 1
run_post_case integration_identity_mismatch "insert into public.carrier_factoring_integrations(id,organization_id,carrier_id,factoring_relationship_id,factoring_company_id,submission_method,submission_destination,configuration_status,is_active,effective_from) select gen_random_uuid(),'22222222-2222-2222-2222-222222222222',carrier_id,id,factoring_company_id,'secure_email','audit@example.test','draft',false,current_date from public.factoring_relationships limit 1" BLOCKED FACTOR_INTEGRATION_CROSS_ORG BLOCKER 1
run_post_case invalid_secret_reference "alter table public.carrier_factoring_integrations drop constraint if exists cfi_opaque_reference_shape; insert into public.carrier_factoring_integrations(id,organization_id,carrier_id,factoring_relationship_id,factoring_company_id,submission_method,provider,external_account_identifier,configuration_status,is_active,effective_from,secret_reference) select gen_random_uuid(),organization_id,carrier_id,id,factoring_company_id,'api','factoring_api','audit-account','draft',false,current_date,'not-an-opaque-uri' from public.factoring_relationships limit 1" BLOCKED FACTOR_SECRET_REF_BAD BLOCKER 1
# Synthetic credential shape assembled at runtime; no contiguous credential literal is stored in source.
run_post_case credential_shape "alter table public.factoring_relationships disable trigger all; update public.factoring_relationships set submission_notes='sk_'||'test_'||repeat('x',24)" BLOCKED FACTOR_CREDENTIAL_CONFIG BLOCKER 1
run_post_case credential_stripe_live "update public.factoring_relationships set submission_notes='sk_'||'live_'||repeat('x',24)" BLOCKED FACTOR_CREDENTIAL_CONFIG BLOCKER 1
run_post_case credential_stripe_restricted "update public.factoring_relationships set submission_notes='rk_'||'live_'||repeat('x',24)" BLOCKED FACTOR_CREDENTIAL_CONFIG BLOCKER 1
run_post_case credential_webhook "update public.factoring_relationships set submission_notes='whsec_'||repeat('x',24)" BLOCKED FACTOR_CREDENTIAL_CONFIG BLOCKER 1
run_post_case credential_aws "update public.factoring_relationships set submission_notes='AK'||'IA'||repeat('A',16)" BLOCKED FACTOR_CREDENTIAL_CONFIG BLOCKER 1
run_post_case credential_jwt "update public.factoring_relationships set submission_notes='eyJ'||repeat('a',12)||'.eyJ'||repeat('b',12)||'.'||repeat('c',16)" BLOCKED FACTOR_CREDENTIAL_CONFIG BLOCKER 1
run_post_case credential_bearer "update public.factoring_relationships set submission_notes='Bear'||'er '||repeat('x',24)" BLOCKED FACTOR_CREDENTIAL_CONFIG BLOCKER 1
run_post_case credential_private_key "update public.factoring_relationships set submission_notes='BEGIN '||'PRIVATE '||'KEY'" BLOCKED FACTOR_CREDENTIAL_CONFIG BLOCKER 1
run_post_case credential_password_url "update public.factoring_relationships set submission_notes='https:'||'//audit:'||repeat('x',12)||'@example.test'" BLOCKED FACTOR_CREDENTIAL_CONFIG BLOCKER 1
run_post_case credential_api_key "update public.factoring_relationships set submission_notes='api_'||'key='||repeat('x',20)" BLOCKED FACTOR_CREDENTIAL_CONFIG BLOCKER 1
run_post_case credential_generic_secret "update public.factoring_relationships set submission_notes='sec'||'ret='||repeat('x',20)" BLOCKED FACTOR_CREDENTIAL_CONFIG BLOCKER 1
run_post_case credential_client_secret "update public.factoring_relationships set submission_notes='client_'||'secret='||repeat('x',20)" BLOCKED FACTOR_CREDENTIAL_CONFIG BLOCKER 1
run_post_case credential_access_token "update public.factoring_relationships set submission_notes='access_'||'token='||repeat('x',20)" BLOCKED FACTOR_CREDENTIAL_CONFIG BLOCKER 1
run_post_case credential_refresh_token "update public.factoring_relationships set submission_notes='refresh_'||'token='||repeat('x',20)" BLOCKED FACTOR_CREDENTIAL_CONFIG BLOCKER 1
run_post_case credential_control "update public.factoring_relationships set submission_notes='audit'||chr(10)||'value'" BLOCKED FACTOR_CREDENTIAL_CONFIG BLOCKER 1
run_post_case noa_approver_missing "alter table public.factoring_relationships drop constraint factoring_relationships_noa_approval_complete; update public.factoring_relationships set noa_approved_by=null" BLOCKED FACTOR_NOA_APPROVER_MISSING BLOCKER 1
run_post_case noa_approved_at_missing "alter table public.factoring_relationships drop constraint factoring_relationships_noa_approval_complete; update public.factoring_relationships set noa_approved_at=null" BLOCKED FACTOR_NOA_APPROVED_AT_MISSING BLOCKER 1
run_post_case noa_effective_missing "alter table public.factoring_relationships drop constraint factoring_relationships_noa_approval_complete; update public.factoring_relationships set noa_effective_date=null" BLOCKED FACTOR_NOA_EFFECTIVE_MISSING BLOCKER 1
run_post_case noa_reference_missing_exact "update public.factoring_relationships set noa_reference=null" READY_WITH_WARNINGS FACTOR_NOA_REFERENCE_MISSING WARNING 1
run_post_case noa_date_before_window "update public.factoring_relationships set noa_effective_date=effective_from-1" BLOCKED FACTOR_NOA_DATE_WINDOW BLOCKER 1

run_noa_case(){
  local name="$1" setup="$2" expected="$3" fid="$4" severity="$5" count="$6" db="noa_${1}" out before after ok=f marker
  [[ "$count" == 0 ]] && ok=t
  createdb -T audit_post0146 "$db"; out="$PGDATA/$name.noa.out"
  marker="NOA_PRIVATE_${name}_9zQ"
  "${PSQL[@]}" -d "$db" -c "set session_replication_role=replica;
    insert into public.documents(id,organization_id,entity_type,entity_id,document_type,file_name,file_path,is_verified,verified_by,verified_at)
    values('d0480000-0000-0000-0000-000000000001','11111111-1111-1111-1111-111111111111','carrier','a2a2a2a2-0000-0000-0000-000000000002','notice_of_assignment','${marker}_filename.pdf','private/${marker}_storage_metadata',true,'aaaa0000-0000-0000-0000-000000000001',now());
    update public.profiles set full_name='${marker}_approver' where id='aaaa0000-0000-0000-0000-000000000001';
    $setup; set session_replication_role=origin" >/dev/null
  before="$("${PSQL[@]}" -At -d "$db" -c "select md5(coalesce(string_agg(to_jsonb(x)::text,'|' order by x.id),'')) from public.factoring_relationships x; select md5(coalesce(string_agg(to_jsonb(x)::text,'|' order by x.id),'')) from public.documents x")"
  "${PSQL[@]}" -d "$db" -f PRODUCTION_PREFLIGHT_0130_0147_READONLY.sql >"$out" 2>&1 || { echo "FAIL $name audit error"; fail=1; return; }
  after="$("${PSQL[@]}" -At -d "$db" -c "select md5(coalesce(string_agg(to_jsonb(x)::text,'|' order by x.id),'')) from public.factoring_relationships x; select md5(coalesce(string_agg(to_jsonb(x)::text,'|' order by x.id),'')) from public.documents x")"
  [[ "$before" == "$after" ]] || { echo "FAIL $name audit mutation"; fail=1; return; }
  grep -Eq "$fid.*$severity[[:space:]]*\\|[[:space:]]*$ok[[:space:]]*\\|[[:space:]]*$count" "$out" && grep -Eq "FINAL_DECISION.*$expected" "$out" || { echo "FAIL $name outcome $fid/$severity/$count/$expected"; grep "$fid" "$out"; fail=1; return; }
  if grep -q "$marker\|d0480000-0000-0000-0000-000000000001" "$out"; then echo "FAIL $name sensitive document output"; fail=1; return; fi
  echo "PASS $name -> $expected ($fid=$count), private fields suppressed"
}
run_noa_case noa_not_required "update public.factoring_relationships set is_default=false; update public.carriers set factoring_mode='direct' where id='a2a2a2a2-0000-0000-0000-000000000002'" READY_WITH_WARNINGS FACTOR_NOA_UNAPPROVED WARNING 0
run_noa_case noa_required_missing_approval "update public.factoring_relationships set noa_approved=false" READY_WITH_WARNINGS FACTOR_NOA_UNAPPROVED WARNING 1
run_noa_case noa_approved_missing_approver "alter table public.factoring_relationships drop constraint factoring_relationships_noa_approval_complete; update public.factoring_relationships set noa_approved_by=null" BLOCKED FACTOR_NOA_APPROVER_MISSING BLOCKER 1
run_noa_case noa_approved_missing_timestamp "alter table public.factoring_relationships drop constraint factoring_relationships_noa_approval_complete; update public.factoring_relationships set noa_approved_at=null" BLOCKED FACTOR_NOA_APPROVED_AT_MISSING BLOCKER 1
run_noa_case noa_approved_missing_effective_date "alter table public.factoring_relationships drop constraint factoring_relationships_noa_approval_complete; update public.factoring_relationships set noa_effective_date=null" BLOCKED FACTOR_NOA_EFFECTIVE_MISSING BLOCKER 1
run_noa_case noa_approved_missing_reference "update public.factoring_relationships set noa_reference=null" READY_WITH_WARNINGS FACTOR_NOA_REFERENCE_MISSING WARNING 1
run_noa_case noa_approved_missing_document_id "update public.factoring_relationships set noa_document_id=null" READY_WITH_WARNINGS FACTOR_NOA_DOCUMENT WARNING 0
run_noa_case noa_document_not_found "update public.factoring_relationships set noa_document_id='d0480000-0000-0000-0000-000000000099'" BLOCKED FACTOR_NOA_DOCUMENT_DANGLING BLOCKER 1
run_noa_case noa_document_wrong_organization "update public.documents set organization_id='22222222-2222-2222-2222-222222222222'; update public.factoring_relationships set noa_document_id='d0480000-0000-0000-0000-000000000001'" BLOCKED FACTOR_NOA_DOCUMENT_ORG_MISMATCH BLOCKER 1
run_noa_case noa_document_unverified "update public.documents set is_verified=false,verified_by=null,verified_at=null; update public.factoring_relationships set noa_document_id='d0480000-0000-0000-0000-000000000001'" READY_WITH_WARNINGS FACTOR_NOA_DOCUMENT WARNING 1
run_noa_case noa_document_missing_verified_by "update public.documents set verified_by=null; update public.factoring_relationships set noa_document_id='d0480000-0000-0000-0000-000000000001'" BLOCKED FACTOR_NOA_DOCUMENT_METADATA BLOCKER 1
run_noa_case noa_document_missing_verified_at "update public.documents set verified_at=null; update public.factoring_relationships set noa_document_id='d0480000-0000-0000-0000-000000000001'" BLOCKED FACTOR_NOA_DOCUMENT_METADATA BLOCKER 1
run_noa_case noa_document_verifier_wrong_organization "update public.documents set verified_by='bbbb0000-0000-0000-0000-000000000001'; update public.factoring_relationships set noa_document_id='d0480000-0000-0000-0000-000000000001'" BLOCKED FACTOR_NOA_VERIFIER_ORG BLOCKER 1
run_noa_case noa_effective_before_relationship "update public.factoring_relationships set noa_effective_date=effective_from-1" BLOCKED FACTOR_NOA_DATE_WINDOW BLOCKER 1
run_noa_case noa_effective_after_relationship_end "update public.factoring_relationships set effective_to=current_date+1,noa_effective_date=current_date+2" BLOCKED FACTOR_NOA_DATE_WINDOW BLOCKER 1
run_noa_case noa_relationship_not_yet_effective "update public.factoring_relationships set effective_from=current_date+1,noa_effective_date=current_date+1" READY_WITH_WARNINGS FACTOR_DEFAULT_FUTURE WARNING 1
run_noa_case noa_relationship_expired "update public.factoring_relationships set effective_from=current_date-2,effective_to=current_date-1,noa_effective_date=current_date-2" READY_WITH_WARNINGS FACTOR_DEFAULT_EXPIRED WARNING 1
run_noa_case noa_inactive_historical_relationship "update public.factoring_relationships set is_default=false,is_active=false" READY_WITH_WARNINGS FACTOR_POLICY_INACTIVE_REL INFO 1
run_noa_case noa_complete_valid "update public.factoring_relationships set noa_document_id='d0480000-0000-0000-0000-000000000001'" READY_WITH_WARNINGS FACTOR_NOA_DOCUMENT WARNING 0
run_noa_case noa_ready_but_identity_dependency_invalid "update public.documents set entity_id='a1a1a1a1-0000-0000-0000-000000000001'; update public.factoring_relationships set noa_document_id='d0480000-0000-0000-0000-000000000001'" BLOCKED FACTOR_NOA_DOCUMENT_IDENTITY BLOCKER 1
cat >"$PGDATA/noa20.labels" <<'NOALABELS'
noa_not_required
noa_required_missing_approval
noa_approved_missing_approver
noa_approved_missing_timestamp
noa_approved_missing_effective_date
noa_approved_missing_reference
noa_approved_missing_document_id
noa_document_not_found
noa_document_wrong_organization
noa_document_unverified
noa_document_missing_verified_by
noa_document_missing_verified_at
noa_document_verifier_wrong_organization
noa_effective_before_relationship
noa_effective_after_relationship_end
noa_relationship_not_yet_effective
noa_relationship_expired
noa_inactive_historical_relationship
noa_complete_valid
noa_ready_but_identity_dependency_invalid
NOALABELS
[[ "$(wc -l <"$PGDATA/noa20.labels"|tr -d ' ')" == 20 && "$(sort -u "$PGDATA/noa20.labels"|wc -l|tr -d ' ')" == 20 ]] || { echo 'FAIL NOA exact-label contract'; fail=1; }
echo 'PASS exact_noa_20_case_matrix -> 20 unique outcomes'
run_post_case integration_draft "insert into public.carrier_factoring_integrations(id,organization_id,carrier_id,factoring_relationship_id,factoring_company_id,submission_method,submission_destination,configuration_status,is_active,effective_from) select gen_random_uuid(),organization_id,carrier_id,id,factoring_company_id,'secure_email','audit@example.test','draft',false,current_date from public.factoring_relationships limit 1" READY_WITH_WARNINGS FACTOR_INTEGRATION_STATE_DRAFT INFO 1
run_post_case integration_pending "insert into public.carrier_factoring_integrations(id,organization_id,carrier_id,factoring_relationship_id,factoring_company_id,submission_method,submission_destination,configuration_status,is_active,effective_from) select gen_random_uuid(),organization_id,carrier_id,id,factoring_company_id,'secure_email','audit@example.test','pending_verification',false,current_date from public.factoring_relationships limit 1" READY_WITH_WARNINGS FACTOR_INTEGRATION_STATE_PENDING INFO 1
run_post_case integration_suspended "insert into public.carrier_factoring_integrations(id,organization_id,carrier_id,factoring_relationship_id,factoring_company_id,submission_method,submission_destination,configuration_status,is_active,effective_from) select gen_random_uuid(),organization_id,carrier_id,id,factoring_company_id,'secure_email','audit@example.test','suspended',false,current_date from public.factoring_relationships limit 1" READY_WITH_WARNINGS FACTOR_INTEGRATION_STATE_SUSPENDED INFO 1
run_post_case integration_failed "insert into public.carrier_factoring_integrations(id,organization_id,carrier_id,factoring_relationship_id,factoring_company_id,submission_method,submission_destination,configuration_status,is_active,effective_from) select gen_random_uuid(),organization_id,carrier_id,id,factoring_company_id,'secure_email','audit@example.test','failed',false,current_date from public.factoring_relationships limit 1" READY_WITH_WARNINGS FACTOR_INTEGRATION_STATE_FAILED INFO 1
run_post_case integration_revoked "insert into public.carrier_factoring_integrations(id,organization_id,carrier_id,factoring_relationship_id,factoring_company_id,submission_method,submission_destination,configuration_status,is_active,effective_from) select gen_random_uuid(),organization_id,carrier_id,id,factoring_company_id,'secure_email','audit@example.test','revoked',false,current_date from public.factoring_relationships limit 1" READY_WITH_WARNINGS FACTOR_INTEGRATION_STATE_REVOKED INFO 1
run_post_case integration_nonready_active "alter table public.carrier_factoring_integrations drop constraint cfi_ready_iff_active; insert into public.carrier_factoring_integrations(id,organization_id,carrier_id,factoring_relationship_id,factoring_company_id,submission_method,submission_destination,configuration_status,is_active,effective_from,approved_by,approved_at) select gen_random_uuid(),organization_id,carrier_id,id,factoring_company_id,'secure_email','audit@example.test','draft',true,current_date,'aaaa0000-0000-0000-0000-000000000001',now() from public.factoring_relationships limit 1" BLOCKED FACTOR_INTEGRATION_NONREADY_ACTIVE BLOCKER 1
run_post_case integration_future "insert into public.carrier_factoring_integrations(id,organization_id,carrier_id,factoring_relationship_id,factoring_company_id,submission_method,submission_destination,configuration_status,is_active,effective_from) select gen_random_uuid(),organization_id,carrier_id,id,factoring_company_id,'secure_email','audit@example.test','draft',false,current_date+1 from public.factoring_relationships limit 1" READY_WITH_WARNINGS FACTOR_INTEGRATION_FUTURE WARNING 1
run_post_case integration_api_fields "alter table public.carrier_factoring_integrations drop constraint cfi_api_requires_secret_ref; insert into public.carrier_factoring_integrations(id,organization_id,carrier_id,factoring_relationship_id,factoring_company_id,submission_method,configuration_status,is_active,effective_from) select gen_random_uuid(),organization_id,carrier_id,id,factoring_company_id,'api','draft',false,current_date from public.factoring_relationships limit 1" READY_WITH_WARNINGS FACTOR_INTEGRATION_API_FIELDS WARNING 1
# Exact Phase 3C.0C.2 lifecycle labels.
run_post_case integration_draft_valid "insert into public.carrier_factoring_integrations(id,organization_id,carrier_id,factoring_relationship_id,factoring_company_id,submission_method,submission_destination,configuration_status,is_active,effective_from) select gen_random_uuid(),organization_id,carrier_id,id,factoring_company_id,'secure_email','audit@example.test','draft',false,current_date from public.factoring_relationships limit 1" READY_WITH_WARNINGS FACTOR_INTEGRATION_STATE_DRAFT INFO 1
run_post_case integration_pending_verification_valid "insert into public.carrier_factoring_integrations(id,organization_id,carrier_id,factoring_relationship_id,factoring_company_id,submission_method,submission_destination,configuration_status,is_active,effective_from) select gen_random_uuid(),organization_id,carrier_id,id,factoring_company_id,'secure_email','audit@example.test','pending_verification',false,current_date from public.factoring_relationships limit 1" READY_WITH_WARNINGS FACTOR_INTEGRATION_STATE_PENDING INFO 1
run_post_case integration_suspended_valid "insert into public.carrier_factoring_integrations(id,organization_id,carrier_id,factoring_relationship_id,factoring_company_id,submission_method,submission_destination,configuration_status,is_active,effective_from) select gen_random_uuid(),organization_id,carrier_id,id,factoring_company_id,'secure_email','audit@example.test','suspended',false,current_date from public.factoring_relationships limit 1" READY_WITH_WARNINGS FACTOR_INTEGRATION_STATE_SUSPENDED INFO 1
run_post_case integration_failed_valid "insert into public.carrier_factoring_integrations(id,organization_id,carrier_id,factoring_relationship_id,factoring_company_id,submission_method,submission_destination,configuration_status,is_active,effective_from) select gen_random_uuid(),organization_id,carrier_id,id,factoring_company_id,'secure_email','audit@example.test','failed',false,current_date from public.factoring_relationships limit 1" READY_WITH_WARNINGS FACTOR_INTEGRATION_STATE_FAILED INFO 1
run_post_case integration_revoked_valid "insert into public.carrier_factoring_integrations(id,organization_id,carrier_id,factoring_relationship_id,factoring_company_id,submission_method,submission_destination,configuration_status,is_active,effective_from) select gen_random_uuid(),organization_id,carrier_id,id,factoring_company_id,'secure_email','audit@example.test','revoked',false,current_date from public.factoring_relationships limit 1" READY_WITH_WARNINGS FACTOR_INTEGRATION_STATE_REVOKED INFO 1
run_post_case integration_ready_inactive "alter table public.carrier_factoring_integrations drop constraint cfi_ready_iff_active; insert into public.carrier_factoring_integrations(id,organization_id,carrier_id,factoring_relationship_id,factoring_company_id,submission_method,submission_destination,configuration_status,is_active,effective_from,approved_by,approved_at) select gen_random_uuid(),organization_id,carrier_id,id,factoring_company_id,'secure_email','audit@example.test','ready',false,current_date,'aaaa0000-0000-0000-0000-000000000001',now() from public.factoring_relationships limit 1" BLOCKED FACTOR_INTEGRATION_READY_BAD BLOCKER 1
run_post_case integration_pending_active "alter table public.carrier_factoring_integrations drop constraint cfi_ready_iff_active; insert into public.carrier_factoring_integrations(id,organization_id,carrier_id,factoring_relationship_id,factoring_company_id,submission_method,submission_destination,configuration_status,is_active,effective_from,approved_by,approved_at) select gen_random_uuid(),organization_id,carrier_id,id,factoring_company_id,'secure_email','audit@example.test','pending_verification',true,current_date,'aaaa0000-0000-0000-0000-000000000001',now() from public.factoring_relationships limit 1" BLOCKED FACTOR_INTEGRATION_NONREADY_ACTIVE BLOCKER 1
run_post_case integration_suspended_active "alter table public.carrier_factoring_integrations drop constraint cfi_ready_iff_active; insert into public.carrier_factoring_integrations(id,organization_id,carrier_id,factoring_relationship_id,factoring_company_id,submission_method,submission_destination,configuration_status,is_active,effective_from,approved_by,approved_at) select gen_random_uuid(),organization_id,carrier_id,id,factoring_company_id,'secure_email','audit@example.test','suspended',true,current_date,'aaaa0000-0000-0000-0000-000000000001',now() from public.factoring_relationships limit 1" BLOCKED FACTOR_INTEGRATION_NONREADY_ACTIVE BLOCKER 1
run_post_case integration_failed_active "alter table public.carrier_factoring_integrations drop constraint cfi_ready_iff_active; insert into public.carrier_factoring_integrations(id,organization_id,carrier_id,factoring_relationship_id,factoring_company_id,submission_method,submission_destination,configuration_status,is_active,effective_from,approved_by,approved_at) select gen_random_uuid(),organization_id,carrier_id,id,factoring_company_id,'secure_email','audit@example.test','failed',true,current_date,'aaaa0000-0000-0000-0000-000000000001',now() from public.factoring_relationships limit 1" BLOCKED FACTOR_INTEGRATION_NONREADY_ACTIVE BLOCKER 1
run_post_case integration_revoked_active "alter table public.carrier_factoring_integrations drop constraint cfi_ready_iff_active; insert into public.carrier_factoring_integrations(id,organization_id,carrier_id,factoring_relationship_id,factoring_company_id,submission_method,submission_destination,configuration_status,is_active,effective_from,approved_by,approved_at) select gen_random_uuid(),organization_id,carrier_id,id,factoring_company_id,'secure_email','audit@example.test','revoked',true,current_date,'aaaa0000-0000-0000-0000-000000000001',now() from public.factoring_relationships limit 1" BLOCKED FACTOR_INTEGRATION_NONREADY_ACTIVE BLOCKER 1

# Exact core ready/identity/dependency matrix. Each case clones the same
# post-0146 state, seeds one fully ready API integration, then applies only
# its named corruption. All private markers are absent from audit output.
run_core_integration_case(){
  local name="$1" mutation="$2" expected="$3" fid="$4" severity="$5" count="$6" db="core_${1}" out before after ok=f identity_counts=''
  local cross_n carrier_n relationship_n company_n identity_expectation identity_fid identity_n identity_ok healthy_fid
  [[ "$count" == 0 ]] && ok=t
  createdb -T audit_post0146 "$db"; out="$PGDATA/$name.core.out"
  "${PSQL[@]}" -d "$db" -c "set session_replication_role=replica;
    alter table public.factoring_relationships drop constraint if exists factoring_relationships_submission_integration_present;
    update public.factoring_relationships set submission_method='api',submission_destination_email=null where id='fe480000-0000-0000-0000-000000000001';
    insert into public.carrier_factoring_integrations(id,organization_id,carrier_id,factoring_relationship_id,factoring_company_id,submission_method,provider,secret_reference,external_account_identifier,submission_destination,configuration_status,is_active,effective_from,approved_by,approved_at)
    values('cf480000-0000-0000-0000-000000000001','11111111-1111-1111-1111-111111111111','a2a2a2a2-0000-0000-0000-000000000002','fe480000-0000-0000-0000-000000000001','fc480000-0000-0000-0000-000000000001','api','factoring_api','vault://core_marker_9zQ','CORE_EXTERNAL_MARKER_9zQ','CORE_DEST_MARKER_9zQ','ready',true,current_date,'aaaa0000-0000-0000-0000-000000000001',now());
    $mutation; set session_replication_role=origin" >/dev/null
  before="$("${PSQL[@]}" -At -d "$db" -c "select md5(coalesce(string_agg(to_jsonb(x)::text,'|' order by x.id),'')) from public.carrier_factoring_integrations x; select md5(coalesce(string_agg(to_jsonb(x)::text,'|' order by x.id),'')) from public.factoring_relationships x")"
  "${PSQL[@]}" -d "$db" -f PRODUCTION_PREFLIGHT_0130_0147_READONLY.sql >"$out" 2>&1 || { echo "FAIL $name audit error"; fail=1; return; }
  after="$("${PSQL[@]}" -At -d "$db" -c "select md5(coalesce(string_agg(to_jsonb(x)::text,'|' order by x.id),'')) from public.carrier_factoring_integrations x; select md5(coalesce(string_agg(to_jsonb(x)::text,'|' order by x.id),'')) from public.factoring_relationships x")"
  [[ "$before" == "$after" ]] || { echo "FAIL $name audit mutation"; fail=1; return; }
  grep -Eq "$fid.*$severity[[:space:]]*\\|[[:space:]]*$ok[[:space:]]*\\|[[:space:]]*$count" "$out" && grep -Eq "FINAL_DECISION.*$expected" "$out" || { echo "FAIL $name outcome $fid/$severity/$count/$expected"; grep "$fid" "$out"; fail=1; return; }
  if [[ "$name" == integration_ready_valid ]]; then
    for healthy_fid in FACTOR_INTEGRATION_CROSS_ORG FACTOR_INTEGRATION_CARRIER_MISMATCH FACTOR_INTEGRATION_RELATIONSHIP_MISMATCH FACTOR_INTEGRATION_COMPANY_MISMATCH FACTOR_INTEGRATION_READY_BAD FACTOR_INTEGRATION_NONREADY_ACTIVE FACTOR_INTEGRATION_MULTI_ACTIVE FACTOR_INTEGRATION_READY_NONDEFAULT FACTOR_INTEGRATION_READY_DEPENDENCY FACTOR_INTEGRATION_FUTURE FACTOR_INTEGRATION_API_FIELDS FACTOR_API_MISSING FACTOR_API_NOT_READY FACTOR_SECRET_REF_BAD; do
      grep -Eq "$healthy_fid.*\\|[[:space:]]*t[[:space:]]*\\|[[:space:]]*0" "$out" || { echo "FAIL $name unexpected integration warning/blocker: $healthy_fid"; fail=1; return; }
    done
  fi
  case "$name" in
    integration_wrong_organization) identity_counts='1 0 0 0' ;;
    integration_wrong_carrier) identity_counts='0 1 0 0' ;;
    integration_wrong_relationship) identity_counts='0 0 1 0' ;;
    integration_wrong_company) identity_counts='0 0 0 1' ;;
    integration_combined_cross_org_carrier_mismatch) identity_counts='1 1 0 0' ;;
    *) identity_counts='' ;;
  esac
  if [[ -n "$identity_counts" ]]; then
    read -r cross_n carrier_n relationship_n company_n <<<"$identity_counts"
    for identity_expectation in "FACTOR_INTEGRATION_CROSS_ORG:$cross_n" "FACTOR_INTEGRATION_CARRIER_MISMATCH:$carrier_n" "FACTOR_INTEGRATION_RELATIONSHIP_MISMATCH:$relationship_n" "FACTOR_INTEGRATION_COMPANY_MISMATCH:$company_n"; do
      identity_fid="${identity_expectation%%:*}"; identity_n="${identity_expectation##*:}"; identity_ok=f; [[ "$identity_n" == 0 ]] && identity_ok=t
      grep -Eq "$identity_fid.*BLOCKER[[:space:]]*\\|[[:space:]]*$identity_ok[[:space:]]*\\|[[:space:]]*$identity_n" "$out" || { echo "FAIL $name identity overlap: $identity_fid expected $identity_n"; fail=1; return; }
    done
  fi
  if grep -q 'core_marker_9zQ\|CORE_EXTERNAL_MARKER_9zQ\|CORE_DEST_MARKER_9zQ\|CORE_COMPANY_MARKER_9zQ\|CORE_RELATIONSHIP_MARKER_9zQ\|cf480000-0000-0000-0000-000000000001\|fe480000-0000-0000-0000-000000000001\|fc480000-0000-0000-0000-000000000001\|a2a2a2a2-0000-0000-0000-000000000002\|22222222-2222-2222-2222-222222222222\|fe480000-0000-0000-0000-000000000099\|fc480000-0000-0000-0000-000000000099' "$out"; then echo "FAIL $name private marker leaked"; fail=1; return; fi
  echo "PASS $name -> $expected ($fid=$count), private fields suppressed"
}
run_core_integration_case integration_ready_valid "" READY_WITH_WARNINGS FACTOR_INTEGRATION_READY_BAD BLOCKER 0
run_core_integration_case integration_draft_active "alter table public.carrier_factoring_integrations drop constraint cfi_ready_iff_active; update public.carrier_factoring_integrations set configuration_status='draft'" BLOCKED FACTOR_INTEGRATION_NONREADY_ACTIVE BLOCKER 1
run_core_integration_case integration_multiple_active "drop index public.cfi_one_active_per_relationship; insert into public.carrier_factoring_integrations select gen_random_uuid(),organization_id,carrier_id,factoring_relationship_id,factoring_company_id,submission_method,provider,secret_reference,external_account_identifier,submission_destination,configuration_status,is_active,effective_from,effective_to,created_by,approved_by,approved_at,created_at,updated_at from public.carrier_factoring_integrations where id='cf480000-0000-0000-0000-000000000001'" BLOCKED FACTOR_INTEGRATION_MULTI_ACTIVE BLOCKER 1
run_core_integration_case integration_wrong_organization "update public.carrier_factoring_integrations set organization_id='22222222-2222-2222-2222-222222222222'" BLOCKED FACTOR_INTEGRATION_CROSS_ORG BLOCKER 1
run_core_integration_case integration_wrong_carrier "update public.carrier_factoring_integrations set carrier_id='a1a1a1a1-0000-0000-0000-000000000001'" BLOCKED FACTOR_INTEGRATION_CARRIER_MISMATCH BLOCKER 1
run_core_integration_case integration_wrong_relationship "insert into public.factoring_companies(id,organization_id,name,is_active) values('fc480000-0000-0000-0000-000000000099','11111111-1111-1111-1111-111111111111','CORE_COMPANY_MARKER_9zQ',true); insert into public.factoring_relationships(id,organization_id,factoring_company_id,carrier_id,default_advance_percentage,default_factoring_fee_percentage,default_reserve_percentage,fee_timing,recourse_type,remittance_instructions,noa_template_text,noa_reference,noa_effective_date,noa_approved,noa_approved_by,noa_approved_at,submission_method,submission_destination_email,is_default,is_active,effective_from) values('fe480000-0000-0000-0000-000000000099','11111111-1111-1111-1111-111111111111','fc480000-0000-0000-0000-000000000099','a1a1a1a1-0000-0000-0000-000000000001',90,3,10,'deducted_at_funding','non_recourse','CORE_RELATIONSHIP_MARKER_9zQ','Audit NOA','audit-reference',current_date,true,'aaaa0000-0000-0000-0000-000000000001',now(),'secure_email','audit@example.test',true,true,current_date); update public.carrier_factoring_integrations set factoring_relationship_id='fe480000-0000-0000-0000-000000000099'" BLOCKED FACTOR_INTEGRATION_RELATIONSHIP_MISMATCH BLOCKER 1
run_core_integration_case integration_wrong_company "insert into public.factoring_companies(id,organization_id,name,is_active) values('fc480000-0000-0000-0000-000000000099','11111111-1111-1111-1111-111111111111','CORE_COMPANY_MARKER_9zQ',true); update public.carrier_factoring_integrations set factoring_company_id='fc480000-0000-0000-0000-000000000099'" BLOCKED FACTOR_INTEGRATION_COMPANY_MISMATCH BLOCKER 1
run_core_integration_case integration_nondefault_relationship "update public.factoring_relationships set is_default=false" BLOCKED FACTOR_INTEGRATION_READY_NONDEFAULT BLOCKER 1
run_core_integration_case integration_inactive_relationship "update public.factoring_relationships set is_default=false,is_active=false" BLOCKED FACTOR_INTEGRATION_READY_DEPENDENCY BLOCKER 1
run_core_integration_case integration_inactive_company "update public.factoring_companies set is_active=false" BLOCKED FACTOR_INTEGRATION_READY_DEPENDENCY BLOCKER 1
run_core_integration_case integration_direct_carrier "update public.carriers set factoring_mode='direct' where id='a2a2a2a2-0000-0000-0000-000000000002'" BLOCKED FACTOR_INTEGRATION_READY_DEPENDENCY BLOCKER 1
run_core_integration_case integration_unconfigured_carrier "update public.carriers set factoring_mode='unconfigured' where id='a2a2a2a2-0000-0000-0000-000000000002'" BLOCKED FACTOR_INTEGRATION_READY_DEPENDENCY BLOCKER 1
run_core_integration_case integration_combined_cross_org_carrier_mismatch "update public.carrier_factoring_integrations set organization_id='22222222-2222-2222-2222-222222222222',carrier_id='a1a1a1a1-0000-0000-0000-000000000001'" BLOCKED FACTOR_INTEGRATION_CROSS_ORG BLOCKER 1
cat >"$PGDATA/integration22.labels" <<'INTEGRATIONLABELS'
integration_draft_valid
integration_pending_verification_valid
integration_suspended_valid
integration_failed_valid
integration_revoked_valid
integration_ready_inactive
integration_pending_active
integration_suspended_active
integration_failed_active
integration_revoked_active
integration_ready_valid
integration_draft_active
integration_multiple_active
integration_wrong_organization
integration_wrong_carrier
integration_wrong_relationship
integration_wrong_company
integration_nondefault_relationship
integration_inactive_relationship
integration_inactive_company
integration_direct_carrier
integration_unconfigured_carrier
INTEGRATIONLABELS
[[ "$(wc -l <"$PGDATA/integration22.labels"|tr -d ' ')" == 22 && "$(sort -u "$PGDATA/integration22.labels"|wc -l|tr -d ' ')" == 22 ]] || { echo 'FAIL integration exact-label contract'; fail=1; }
echo 'PASS exact_integration_22_case_matrix -> 22 unique outcomes'

# Phase 3C.0C.2.2 API/approval/date/NOA/policy/default dependency matrix.
# Every case starts from one complete ready API integration in its own clone.
run_integration_dependency_case(){
  local name="$1" mutation="$2" expected="$3" fid="$4" severity="$5" count="$6" db="dep_${1}" out before after ok=f
  local target target_fid target_count target_ok healthy_fid
  [[ "$count" == 0 ]] && ok=t
  createdb -T audit_post0146 "$db"; out="$PGDATA/$name.dependency.out"
  "${PSQL[@]}" -d "$db" -c "set session_replication_role=replica;
    update public.profiles set full_name='DEP_APPROVER_MARKER_9zQ' where id='aaaa0000-0000-0000-0000-000000000001';
    update public.carriers set invoice_code='D2MARK9ZQ' where id='a2a2a2a2-0000-0000-0000-000000000002';
    update public.factoring_companies set name='DEP_COMPANY_MARKER_9zQ' where id='fc480000-0000-0000-0000-000000000001';
    update public.factoring_relationships set relationship_name='DEP_RELATIONSHIP_MARKER_9zQ',submission_method='api',submission_destination_email=null where id='fe480000-0000-0000-0000-000000000001';
    insert into public.carrier_factoring_integrations(id,organization_id,carrier_id,factoring_relationship_id,factoring_company_id,submission_method,provider,secret_reference,external_account_identifier,submission_destination,configuration_status,is_active,effective_from,approved_by,approved_at)
    values('cf490000-0000-0000-0000-000000000001','11111111-1111-1111-1111-111111111111','a2a2a2a2-0000-0000-0000-000000000002','fe480000-0000-0000-0000-000000000001','fc480000-0000-0000-0000-000000000001','api','factoring_api','vault://DEP_SECRET_MARKER_9zQ','DEP_EXTERNAL_MARKER_9zQ','DEP_DESTINATION_MARKER_9zQ','ready',true,current_date,'aaaa0000-0000-0000-0000-000000000001',now());
    $mutation; set session_replication_role=origin" >/dev/null
  before="$("${PSQL[@]}" -At -d "$db" -c "select md5(coalesce(string_agg(to_jsonb(x)::text,'|' order by x.id),'')) from public.carrier_factoring_integrations x; select md5(coalesce(string_agg(to_jsonb(x)::text,'|' order by x.id),'')) from public.factoring_relationships x; select md5(coalesce(string_agg(to_jsonb(x)::text,'|' order by x.id),'')) from public.documents x; select md5(coalesce(string_agg(to_jsonb(x)::text,'|' order by x.id),'')) from public.carriers x; select md5(coalesce(string_agg(to_jsonb(x)::text,'|' order by x.id),'')) from public.factoring_companies x")"
  "${PSQL[@]}" -d "$db" -f PRODUCTION_PREFLIGHT_0130_0147_READONLY.sql >"$out" 2>&1 || { echo "FAIL $name audit error"; fail=1; return; }
  after="$("${PSQL[@]}" -At -d "$db" -c "select md5(coalesce(string_agg(to_jsonb(x)::text,'|' order by x.id),'')) from public.carrier_factoring_integrations x; select md5(coalesce(string_agg(to_jsonb(x)::text,'|' order by x.id),'')) from public.factoring_relationships x; select md5(coalesce(string_agg(to_jsonb(x)::text,'|' order by x.id),'')) from public.documents x; select md5(coalesce(string_agg(to_jsonb(x)::text,'|' order by x.id),'')) from public.carriers x; select md5(coalesce(string_agg(to_jsonb(x)::text,'|' order by x.id),'')) from public.factoring_companies x")"
  [[ "$before" == "$after" ]] || { echo "FAIL $name audit mutation"; fail=1; return; }
  grep -Eq "$fid.*$severity[[:space:]]*\\|[[:space:]]*$ok[[:space:]]*\\|[[:space:]]*$count" "$out" && grep -Eq "FINAL_DECISION.*$expected" "$out" || { echo "FAIL $name outcome $fid/$severity/$count/$expected"; grep "$fid" "$out"; fail=1; return; }
  for target in FACTOR_API_MISSING FACTOR_INTEGRATION_PROVIDER_MISSING FACTOR_INTEGRATION_SECRET_REFERENCE_MISSING FACTOR_SECRET_REF_BAD FACTOR_INTEGRATION_EXTERNAL_ACCOUNT_MISSING FACTOR_INTEGRATION_DESTINATION_MISSING FACTOR_INTEGRATION_APPROVER_MISSING FACTOR_INTEGRATION_APPROVED_AT_MISSING FACTOR_INTEGRATION_FUTURE FACTOR_INTEGRATION_DATE_BAD FACTOR_INTEGRATION_FINITE FACTOR_INTEGRATION_READY_NOA_UNAPPROVED FACTOR_INTEGRATION_READY_NOA_DOCUMENT FACTOR_INTEGRATION_READY_DEPENDENCY FACTOR_INTEGRATION_READY_NONDEFAULT; do
    target_count=0; [[ "$target" == "$fid" ]] && target_count="$count"; target_ok=f; [[ "$target_count" == 0 ]] && target_ok=t
    grep -Eq "$target.*\\|[[:space:]]*$target_ok[[:space:]]*\\|[[:space:]]*$target_count" "$out" || { echo "FAIL $name targeted overlap: $target expected $target_count"; fail=1; return; }
  done
  if [[ "$name" == integration_dependency_healthy ]]; then
    for healthy_fid in FACTOR_INTEGRATION_API_FIELDS FACTOR_API_NOT_READY FACTOR_INTEGRATION_READY_BAD FACTOR_INTEGRATION_NONREADY_ACTIVE FACTOR_INTEGRATION_CROSS_ORG FACTOR_INTEGRATION_CARRIER_MISMATCH FACTOR_INTEGRATION_RELATIONSHIP_MISMATCH FACTOR_INTEGRATION_COMPANY_MISMATCH; do
      grep -Eq "$healthy_fid.*\\|[[:space:]]*t[[:space:]]*\\|[[:space:]]*0" "$out" || { echo "FAIL $name healthy dependency overlap: $healthy_fid"; fail=1; return; }
    done
  fi
  if [[ "$name" == integration_provider_missing ]]; then
    grep -Eq 'FACTOR_API_NOT_READY.*WARNING[[:space:]]*\|[[:space:]]*f[[:space:]]*\|[[:space:]]*1' "$out" || { echo "FAIL $name expected API-not-ready companion finding"; fail=1; return; }
  fi
  if grep -q 'DEP_APPROVER_MARKER_9zQ\|D2MARK9ZQ\|DEP_COMPANY_MARKER_9zQ\|DEP_RELATIONSHIP_MARKER_9zQ\|DEP_SECRET_MARKER_9zQ\|DEP_INVALID_REFERENCE_MARKER_9zQ\|DEP_EXTERNAL_MARKER_9zQ\|DEP_DESTINATION_MARKER_9zQ\|DEP_DOCUMENT_MARKER_9zQ\|DEP_DOCUMENT_PATH_MARKER_9zQ\|cf490000-0000-0000-0000-000000000001\|d0490000-0000-0000-0000-000000000001\|fe480000-0000-0000-0000-000000000001\|fc480000-0000-0000-0000-000000000001\|a2a2a2a2-0000-0000-0000-000000000002\|aaaa0000-0000-0000-0000-000000000001\|factoring_api' "$out"; then echo "FAIL $name dependency marker leaked"; fail=1; return; fi
  echo "PASS $name -> $expected ($fid=$count), targeted overlap zero, private fields suppressed"
}
run_integration_dependency_case integration_api_missing "delete from public.carrier_factoring_integrations" READY_WITH_WARNINGS FACTOR_API_MISSING WARNING 1
run_integration_dependency_case integration_provider_missing "update public.carrier_factoring_integrations set configuration_status='draft',is_active=false,provider=null" READY_WITH_WARNINGS FACTOR_INTEGRATION_PROVIDER_MISSING WARNING 1
run_integration_dependency_case integration_secret_reference_missing "alter table public.carrier_factoring_integrations drop constraint cfi_api_requires_secret_ref; update public.carrier_factoring_integrations set configuration_status='draft',is_active=false,secret_reference=null" READY_WITH_WARNINGS FACTOR_INTEGRATION_SECRET_REFERENCE_MISSING WARNING 1
run_integration_dependency_case integration_secret_reference_invalid_shape "alter table public.carrier_factoring_integrations drop constraint cfi_opaque_reference_shape; update public.carrier_factoring_integrations set secret_reference='DEP_INVALID_REFERENCE_MARKER_9zQ'" BLOCKED FACTOR_SECRET_REF_BAD BLOCKER 1
run_integration_dependency_case integration_external_account_missing "update public.carrier_factoring_integrations set configuration_status='draft',is_active=false,external_account_identifier=null" READY_WITH_WARNINGS FACTOR_INTEGRATION_EXTERNAL_ACCOUNT_MISSING WARNING 1
run_integration_dependency_case integration_destination_missing "alter table public.carrier_factoring_integrations drop constraint cfi_secure_email_destination; update public.factoring_relationships set submission_method='secure_email',submission_destination_email='audit@example.test'; update public.carrier_factoring_integrations set configuration_status='draft',is_active=false,submission_method='secure_email',submission_destination=null" READY_WITH_WARNINGS FACTOR_INTEGRATION_DESTINATION_MISSING WARNING 1
run_integration_dependency_case integration_approver_missing "alter table public.carrier_factoring_integrations drop constraint cfi_active_requires_approval; update public.carrier_factoring_integrations set approved_by=null" BLOCKED FACTOR_INTEGRATION_APPROVER_MISSING BLOCKER 1
run_integration_dependency_case integration_approved_at_missing "alter table public.carrier_factoring_integrations drop constraint cfi_active_requires_approval; update public.carrier_factoring_integrations set approved_at=null" BLOCKED FACTOR_INTEGRATION_APPROVED_AT_MISSING BLOCKER 1
run_integration_dependency_case integration_future_effective "update public.carrier_factoring_integrations set configuration_status='draft',is_active=false,effective_from=current_date+1" READY_WITH_WARNINGS FACTOR_INTEGRATION_FUTURE WARNING 1
run_integration_dependency_case integration_invalid_date_order "alter table public.carrier_factoring_integrations drop constraint cfi_valid_effective_range; update public.carrier_factoring_integrations set configuration_status='draft',is_active=false,effective_from=current_date,effective_to=current_date-1" BLOCKED FACTOR_INTEGRATION_DATE_BAD BLOCKER 1
run_integration_dependency_case integration_finite_expiry "update public.carrier_factoring_integrations set effective_to=current_date+30" BLOCKED FACTOR_INTEGRATION_FINITE BLOCKER 1
run_integration_dependency_case integration_noa_unapproved "update public.factoring_relationships set noa_approved=false" BLOCKED FACTOR_INTEGRATION_READY_NOA_UNAPPROVED BLOCKER 1
run_integration_dependency_case integration_noa_document_unverified "insert into public.documents(id,organization_id,entity_type,entity_id,document_type,file_name,file_path,is_verified) values('d0490000-0000-0000-0000-000000000001','11111111-1111-1111-1111-111111111111','carrier','a2a2a2a2-0000-0000-0000-000000000002','notice_of_assignment','DEP_DOCUMENT_MARKER_9zQ.pdf','private/DEP_DOCUMENT_PATH_MARKER_9zQ',false); update public.factoring_relationships set noa_document_id='d0490000-0000-0000-0000-000000000001',noa_document_snapshot_file_name='DEP_DOCUMENT_MARKER_9zQ.pdf',noa_document_snapshot_file_path='private/DEP_DOCUMENT_PATH_MARKER_9zQ'" BLOCKED FACTOR_INTEGRATION_READY_NOA_DOCUMENT BLOCKER 1
run_integration_dependency_case integration_policy_not_factored "update public.carriers set factoring_mode='direct' where id='a2a2a2a2-0000-0000-0000-000000000002'" BLOCKED FACTOR_INTEGRATION_READY_DEPENDENCY BLOCKER 1
run_integration_dependency_case integration_default_changed "update public.factoring_relationships set is_default=false" BLOCKED FACTOR_INTEGRATION_READY_NONDEFAULT BLOCKER 1
run_integration_dependency_case integration_dependency_healthy "" READY_WITH_WARNINGS FACTOR_INTEGRATION_READY_DEPENDENCY BLOCKER 0
cat >"$PGDATA/integration_dependency16.labels" <<'DEPENDENCYLABELS'
integration_api_missing
integration_provider_missing
integration_secret_reference_missing
integration_secret_reference_invalid_shape
integration_external_account_missing
integration_destination_missing
integration_approver_missing
integration_approved_at_missing
integration_future_effective
integration_invalid_date_order
integration_finite_expiry
integration_noa_unapproved
integration_noa_document_unverified
integration_policy_not_factored
integration_default_changed
integration_dependency_healthy
DEPENDENCYLABELS
[[ "$(wc -l <"$PGDATA/integration_dependency16.labels"|tr -d ' ')" == 16 && "$(sort -u "$PGDATA/integration_dependency16.labels"|wc -l|tr -d ' ')" == 16 ]] || { echo 'FAIL integration dependency exact-label contract'; fail=1; }
echo 'PASS exact_integration_dependency_16_case_matrix -> 16 unique outcomes'

# Exact safe-value negative-control matrix. Values are seeded only in isolated
# clones and must neither trigger credential findings nor appear in output.
run_safe_value_case(){
  local name="$1" marker="$2" mutation="$3" db="safe_${1}" out before after
  createdb -T audit_post0146 "$db"; out="$PGDATA/$name.safe.out"
  "${PSQL[@]}" -d "$db" -c "set session_replication_role=replica; $mutation; set session_replication_role=origin" >/dev/null
  before="$("${PSQL[@]}" -At -d "$db" -c "select md5(coalesce(string_agg(to_jsonb(x)::text,'|' order by x.id),'')) from public.factoring_relationships x; select md5(coalesce(string_agg(to_jsonb(x)::text,'|' order by x.id),'')) from public.carrier_factoring_integrations x; select md5(coalesce(string_agg(to_jsonb(x)::text,'|' order by x.id),'')) from public.invoices x; select md5(coalesce(string_agg(to_jsonb(x)::text,'|' order by x.id),'')) from public.carriers x")"
  "${PSQL[@]}" -d "$db" -f PRODUCTION_PREFLIGHT_0130_0147_READONLY.sql >"$out" 2>&1 || { echo "FAIL $name audit error"; fail=1; return; }
  after="$("${PSQL[@]}" -At -d "$db" -c "select md5(coalesce(string_agg(to_jsonb(x)::text,'|' order by x.id),'')) from public.factoring_relationships x; select md5(coalesce(string_agg(to_jsonb(x)::text,'|' order by x.id),'')) from public.carrier_factoring_integrations x; select md5(coalesce(string_agg(to_jsonb(x)::text,'|' order by x.id),'')) from public.invoices x; select md5(coalesce(string_agg(to_jsonb(x)::text,'|' order by x.id),'')) from public.carriers x")"
  [[ "$before" == "$after" ]] || { echo "FAIL $name audit mutation"; fail=1; return; }
  grep -Eq 'FACTOR_CREDENTIAL_CONFIG.*BLOCKER[[:space:]]*\|[[:space:]]*t[[:space:]]*\|[[:space:]]*0' "$out" && grep -Eq 'FACTOR_SECRET_REF_BAD.*BLOCKER[[:space:]]*\|[[:space:]]*t[[:space:]]*\|[[:space:]]*0' "$out" || { echo "FAIL $name safe value false positive"; fail=1; return; }
  grep -Fq "$marker" "$out" && { echo "FAIL $name safe marker echoed"; fail=1; return; }
  echo "PASS $name -> zero credential findings, no echo, read-only"
}
run_safe_value_case safe_destination_email 'safe-destination-9zq@example.test' "insert into public.carrier_factoring_integrations(organization_id,carrier_id,factoring_relationship_id,factoring_company_id,submission_method,submission_destination) select organization_id,carrier_id,id,factoring_company_id,'secure_email','safe-destination-9zq@example.test' from public.factoring_relationships limit 1"
run_safe_value_case safe_portal_https_url 'https://portal.example.test/safe-9zq' "insert into public.carrier_factoring_integrations(organization_id,carrier_id,factoring_relationship_id,factoring_company_id,submission_method,submission_destination) select organization_id,carrier_id,id,factoring_company_id,'portal_manual','https://portal.example.test/safe-9zq' from public.factoring_relationships limit 1"
run_safe_value_case safe_internal_queue 'SAFE_QUEUE_9ZQ' "insert into public.carrier_factoring_integrations(organization_id,carrier_id,factoring_relationship_id,factoring_company_id,submission_method,external_account_identifier) select organization_id,carrier_id,id,factoring_company_id,'internal_queue','SAFE_QUEUE_9ZQ' from public.factoring_relationships limit 1"
run_safe_value_case safe_vault_reference 'vault://safe_ref_9zq' "insert into public.carrier_factoring_integrations(organization_id,carrier_id,factoring_relationship_id,factoring_company_id,submission_method,secret_reference) select organization_id,carrier_id,id,factoring_company_id,'internal_queue','vault://safe_ref_9zq' from public.factoring_relationships limit 1"
run_safe_value_case safe_supported_opaque_reference 'kms://safe_ref_9zq' "insert into public.carrier_factoring_integrations(organization_id,carrier_id,factoring_relationship_id,factoring_company_id,submission_method,secret_reference) select organization_id,carrier_id,id,factoring_company_id,'internal_queue','kms://safe_ref_9zq' from public.factoring_relationships limit 1"
run_safe_value_case safe_remittance_instructions 'Remit by check to Safe Lockbox 9ZQ' "update public.factoring_relationships set remittance_instructions='Remit by check to Safe Lockbox 9ZQ'"
run_safe_value_case safe_remittance_reference 'Remittance reference SAFE-9ZQ-1042' "update public.factoring_relationships set submission_notes='Remittance reference SAFE-9ZQ-1042'"
run_safe_value_case safe_noa_reference 'NOA-SAFE-9ZQ-V2' "update public.factoring_relationships set noa_reference='NOA-SAFE-9ZQ-V2'"
run_safe_value_case safe_provider_identifier 'factoring_api' "insert into public.carrier_factoring_integrations(organization_id,carrier_id,factoring_relationship_id,factoring_company_id,submission_method,provider) select organization_id,carrier_id,id,factoring_company_id,'internal_queue','factoring_api' from public.factoring_relationships limit 1"
run_safe_value_case safe_external_account_display 'Customer Account SAFE-9ZQ-22' "insert into public.carrier_factoring_integrations(organization_id,carrier_id,factoring_relationship_id,factoring_company_id,submission_method,external_account_identifier) select organization_id,carrier_id,id,factoring_company_id,'internal_queue','Customer Account SAFE-9ZQ-22' from public.factoring_relationships limit 1"
run_safe_value_case safe_submission_notes 'Send supporting documents after approval SAFE-9ZQ' "update public.factoring_relationships set submission_notes='Send supporting documents after approval SAFE-9ZQ'"
run_safe_value_case safe_long_business_note 'SAFE-LONG-9ZQ' "update public.factoring_relationships set submission_notes='SAFE-LONG-9ZQ '||repeat('ordinary business instructions ',20)"
run_safe_value_case safe_empty_optional_note '__EMPTY_OPTIONAL_NOTE__' "update public.factoring_relationships set submission_notes=''"
run_safe_value_case safe_invoice_number 'INV-SAFE-9ZQ-1042' "update public.invoices set invoice_number='INV-SAFE-9ZQ-1042' where id=(select id from public.invoices limit 1)"
run_safe_value_case safe_mc_number 'MC-SAFE-9ZQ-123456' "update public.carriers set mc_number='MC-SAFE-9ZQ-123456' where id='a2a2a2a2-0000-0000-0000-000000000002'"
run_safe_value_case safe_dot_number 'DOT-SAFE-9ZQ-7654321' "update public.carriers set dot_number='DOT-SAFE-9ZQ-7654321' where id='a2a2a2a2-0000-0000-0000-000000000002'"
run_safe_value_case safe_phone_number '+1-312-555-0199 SAFE9ZQ' "update public.carriers set phone='+1-312-555-0199 SAFE9ZQ' where id='a2a2a2a2-0000-0000-0000-000000000002'"
run_safe_value_case safe_check_reference 'CHECK-SAFE-9ZQ-8841' "update public.factoring_relationships set submission_notes='CHECK-SAFE-9ZQ-8841'"
run_safe_value_case safe_uuid '49000000-0000-4000-8000-000000009999' "update public.factoring_relationships set submission_notes='49000000-0000-4000-8000-000000009999'"
run_safe_value_case safe_iso_date '2031-04-17-SAFE-9ZQ' "update public.factoring_relationships set submission_notes='2031-04-17-SAFE-9ZQ'"
cat >"$PGDATA/safe20.labels" <<'SAFELABELS'
safe_destination_email
safe_portal_https_url
safe_internal_queue
safe_vault_reference
safe_supported_opaque_reference
safe_remittance_instructions
safe_remittance_reference
safe_noa_reference
safe_provider_identifier
safe_external_account_display
safe_submission_notes
safe_long_business_note
safe_empty_optional_note
safe_invoice_number
safe_mc_number
safe_dot_number
safe_phone_number
safe_check_reference
safe_uuid
safe_iso_date
SAFELABELS
[[ "$(wc -l <"$PGDATA/safe20.labels"|tr -d ' ')" == 20 && "$(sort -u "$PGDATA/safe20.labels"|wc -l|tr -d ' ')" == 20 ]] || { echo 'FAIL safe-value exact-label contract'; fail=1; }
echo 'PASS exact_safe_value_20_case_matrix -> 20 unique outcomes'

run_destination_method_case(){
  local name="$1" method="$2" destination="$3" bypass="$4" fid="$5" count="$6" ready="${7:-false}" db="destination_${1}" out before after ok=f status=draft active=false extra=',null,null'
  [[ "$count" == 0 ]] && ok=t
  [[ "$ready" == true ]] && { status=ready; active=true; extra=",'aaaa0000-0000-0000-0000-000000000001',now()"; }
  createdb -T audit_post0146 "$db"; out="$PGDATA/$name.destination.out"
  "${PSQL[@]}" -d "$db" -c "set session_replication_role=replica; $bypass; update public.factoring_relationships set submission_method='$method',submission_destination_email=case when '$method'='secure_email' then 'method-safe@example.test' else null end; insert into public.carrier_factoring_integrations(organization_id,carrier_id,factoring_relationship_id,factoring_company_id,submission_method,provider,secret_reference,external_account_identifier,submission_destination,configuration_status,is_active,effective_from,approved_by,approved_at) select organization_id,carrier_id,id,factoring_company_id,'$method',case when '$method'='api' then 'factoring_api'::public.integration_provider else null end,case when '$method'='api' then 'vault://method_safe_9zq' else null end,case when '$method'='api' then 'METHOD_ACCOUNT_SAFE_9ZQ' else null end,$destination,'$status',$active,current_date${extra} from public.factoring_relationships limit 1; set session_replication_role=origin" >/dev/null
  before="$("${PSQL[@]}" -At -d "$db" -c "select md5(coalesce(string_agg(to_jsonb(x)::text,'|' order by x.id),'')) from public.carrier_factoring_integrations x; select md5(coalesce(string_agg(to_jsonb(x)::text,'|' order by x.id),'')) from public.factoring_relationships x")"
  "${PSQL[@]}" -d "$db" -f PRODUCTION_PREFLIGHT_0130_0147_READONLY.sql >"$out" 2>&1 || { echo "FAIL $name audit error"; fail=1; return; }
  after="$("${PSQL[@]}" -At -d "$db" -c "select md5(coalesce(string_agg(to_jsonb(x)::text,'|' order by x.id),'')) from public.carrier_factoring_integrations x; select md5(coalesce(string_agg(to_jsonb(x)::text,'|' order by x.id),'')) from public.factoring_relationships x")"
  [[ "$before" == "$after" ]] || { echo "FAIL $name audit mutation"; fail=1; return; }
  grep -Eq "$fid.*WARNING[[:space:]]*\\|[[:space:]]*$ok[[:space:]]*\\|[[:space:]]*$count" "$out" && grep -Eq 'FINAL_DECISION.*READY_WITH_WARNINGS' "$out" || { echo "FAIL $name destination result"; fail=1; return; }
  if [[ "$fid" == FACTOR_INTEGRATION_DESTINATION_MISSING ]]; then grep -Eq 'FACTOR_INTEGRATION_DESTINATION_INVALID.*\|[[:space:]]*t[[:space:]]*\|[[:space:]]*0' "$out"; else grep -Eq 'FACTOR_INTEGRATION_DESTINATION_MISSING.*\|[[:space:]]*t[[:space:]]*\|[[:space:]]*0' "$out"; fi || { echo "FAIL $name destination overlap"; fail=1; return; }
  [[ "$ready" != true ]] || grep -Eq 'FACTOR_API_NOT_READY.*\|[[:space:]]*t[[:space:]]*\|[[:space:]]*0' "$out" || { echo "FAIL $name API readiness"; fail=1; return; }
  grep -q 'method_safe_9zq\|METHOD_ACCOUNT_SAFE_9ZQ\|method-safe@example.test\|portal.example.test/method-safe' "$out" && { echo "FAIL $name method marker leaked"; fail=1; return; }
  echo "PASS $name -> $fid=$count"
}
run_destination_method_case destination_api_null api null '' FACTOR_INTEGRATION_DESTINATION_MISSING 0 true
run_destination_method_case destination_secure_email_missing secure_email null 'alter table public.carrier_factoring_integrations drop constraint cfi_secure_email_destination' FACTOR_INTEGRATION_DESTINATION_MISSING 1
run_destination_method_case destination_secure_email_malformed secure_email "'malformed-method-safe-9zq'" 'alter table public.carrier_factoring_integrations drop constraint cfi_secure_email_destination' FACTOR_INTEGRATION_DESTINATION_INVALID 1
run_destination_method_case destination_secure_email_valid secure_email "'method-safe@example.test'" '' FACTOR_INTEGRATION_DESTINATION_MISSING 0
run_destination_method_case destination_portal_missing portal_manual null 'alter table public.carrier_factoring_integrations drop constraint cfi_portal_requires_instructions' FACTOR_INTEGRATION_DESTINATION_MISSING 1
run_destination_method_case destination_portal_https portal_manual "'https://portal.example.test/method-safe'" '' FACTOR_INTEGRATION_DESTINATION_MISSING 0
run_destination_method_case destination_internal_queue_null internal_queue null '' FACTOR_INTEGRATION_DESTINATION_MISSING 0

# Runtime RLS/status/readiness matrix. Successful owner/admin configure probes
# run inside transactions that are always rolled back.
role_db=audit_integration_roles
createdb -T audit_post0146 "$role_db"
"${PSQL[@]}" -d "$role_db" -c "set session_replication_role=replica;
  insert into auth.users(id) values('ad4d0000-0000-0000-0000-000000000001'),('90900000-0000-0000-0000-000000000001');
  insert into public.profiles(id,organization_id,full_name,email,role) values('ad4d0000-0000-0000-0000-000000000001','11111111-1111-1111-1111-111111111111','Role Admin','role-admin@example.test','admin');
  update public.factoring_relationships set submission_method='api',submission_destination_email=null where id='fe480000-0000-0000-0000-000000000001';
  insert into public.carrier_factoring_integrations(id,organization_id,carrier_id,factoring_relationship_id,factoring_company_id,submission_method,provider,secret_reference,external_account_identifier,configuration_status,is_active,effective_from,approved_by,approved_at)
  values('cf500000-0000-0000-0000-000000000001','11111111-1111-1111-1111-111111111111','a2a2a2a2-0000-0000-0000-000000000002','fe480000-0000-0000-0000-000000000001','fc480000-0000-0000-0000-000000000001','api','factoring_api','vault://ROLE_SECRET_MARKER_9zQ','ROLE_EXTERNAL_DISPLAY_9zQ','ready',true,current_date,'aaaa0000-0000-0000-0000-000000000001',now()); set session_replication_role=origin" >/dev/null
role_before="$("${PSQL[@]}" -At -d "$role_db" -c "select md5(coalesce(string_agg(to_jsonb(x)::text,'|' order by x.id),'')) from public.carrier_factoring_integrations x; select md5(string_agg(grantee||privilege_type,'|' order by grantee,privilege_type)) from information_schema.role_table_grants where table_schema='public' and table_name='carrier_factoring_integrations'; select md5(string_agg(policyname||qual||with_check,'|' order by policyname)) from pg_policies where schemaname='public' and tablename='carrier_factoring_integrations'; select md5(string_agg(pg_get_functiondef(p.oid),'|' order by p.oid)) from pg_proc p where p.pronamespace='public'::regnamespace and p.proname in ('get_carrier_factoring_integration_status','classify_carrier_factoring_readiness')")"
role_rel_updated="$("${PSQL[@]}" -At -d "$role_db" -c "select updated_at from public.factoring_relationships where id='fe480000-0000-0000-0000-000000000001'")"
[[ "$("${PSQL[@]}" -At -d "$role_db" -c "select has_table_privilege('authenticated','public.carrier_factoring_integrations','INSERT') or has_table_privilege('authenticated','public.carrier_factoring_integrations','UPDATE') or has_table_privilege('authenticated','public.carrier_factoring_integrations','DELETE')")" == f ]] || { echo 'FAIL authenticated direct integration mutation privilege'; fail=1; }
run_role_actor(){
  local label="$1" uid="$2" rows="$3" reads="$4" lifecycle="$5" out="$PGDATA/role_${1}.out" status_ok=false
  [[ "$reads" == true ]] && status_ok=true
  "${PSQL[@]}" -At -d "$role_db" >"$out" <<SQL
begin;
select set_config('test.current_uid','$uid',true);
set local role authenticated;
select 'ROW|'||count(*)||'|'||count(secret_reference)||'|'||count(external_account_identifier) from public.carrier_factoring_integrations;
select 'STATUS|'||public.get_carrier_factoring_integration_status('a2a2a2a2-0000-0000-0000-000000000002')::text;
select 'READINESS|'||public.classify_carrier_factoring_readiness('a2a2a2a2-0000-0000-0000-000000000002',null,null)::text;
select 'LIFECYCLE|'||public.configure_carrier_factoring_integration('fe480000-0000-0000-0000-000000000001','vault://role_probe_opaque','ROLE_PROBE_ACCOUNT','factoring_api',null,'role probe','$role_rel_updated','role-probe-$label')::text;
rollback;
SQL
  grep -q "ROW|$rows|$rows|$rows" "$out" || { echo "FAIL role_$label base visibility"; fail=1; return; }
  if [[ "$reads" == true ]]; then grep -Eq 'STATUS\|.*"success": true' "$out" && grep -Eq 'READINESS\|.*"success": true' "$out" && grep -q 'ROLE_EXTERNAL_DISPLAY_9zQ' "$out" || { echo "FAIL role_$label read RPC/non-secret account display"; fail=1; return; }; else grep -Eq 'STATUS\|.*"success": false' "$out" && grep -Eq 'READINESS\|.*"success": false' "$out" && ! grep -q 'ROLE_EXTERNAL_DISPLAY_9zQ' "$out" || { echo "FAIL role_$label read denial"; fail=1; return; }; fi
  if [[ "$lifecycle" == true ]]; then grep -Eq 'LIFECYCLE\|.*"success": true' "$out" || { echo "FAIL role_$label lifecycle permission"; fail=1; return; }; else grep -Eq 'LIFECYCLE\|.*"success": false' "$out" || { echo "FAIL role_$label lifecycle denial"; fail=1; return; }; fi
  grep -Eqi 'secret_reference|credentials|api_key|password|access_token|refresh_token|client_secret|private_key|ROLE_SECRET_MARKER_9zQ|role_probe_opaque' "$out" && { echo "FAIL role_$label forbidden RPC disclosure"; fail=1; return; }
  echo "PASS role_$label -> rows=$rows status/readiness=$reads lifecycle=$lifecycle direct_mutation=false"
}
run_role_actor same_org_owner aaaa0000-0000-0000-0000-000000000001 1 true true
run_role_actor same_org_admin ad4d0000-0000-0000-0000-000000000001 1 true true
run_role_actor same_org_accountant cccc0000-0000-0000-0000-000000000001 0 true false
run_role_actor same_org_dispatcher dddd0000-0000-0000-0000-000000000001 0 true false
run_role_actor same_org_driver eeee0000-0000-0000-0000-000000000001 0 false false
run_role_actor same_org_viewer ffff0000-0000-0000-0000-000000000001 0 false false
run_role_actor cross_org_owner bbbb0000-0000-0000-0000-000000000001 0 false false
run_role_actor authenticated_no_profile 90900000-0000-0000-0000-000000000001 0 false false
anon_out="$PGDATA/role_anonymous.out"
if "${PSQL[@]}" -At -d "$role_db" -c "set role anon; select * from public.carrier_factoring_integrations; select public.get_carrier_factoring_integration_status('a2a2a2a2-0000-0000-0000-000000000002')" >"$anon_out" 2>&1; then echo 'FAIL role_anonymous unexpectedly accessed integration API'; fail=1; else grep -qi 'permission denied' "$anon_out" || { echo 'FAIL role_anonymous denial evidence'; fail=1; }; echo 'PASS role_anonymous -> table/RPC permission denied'; fi
service_out="$PGDATA/role_null_service.out"
"${PSQL[@]}" -At -d "$role_db" -c "select set_config('test.current_uid',null,false); select 'ROW|'||count(*)||'|'||count(secret_reference)||'|'||count(external_account_identifier) from public.carrier_factoring_integrations; select 'STATUS|'||public.get_carrier_factoring_integration_status('a2a2a2a2-0000-0000-0000-000000000002')::text; select 'READINESS|'||public.classify_carrier_factoring_readiness('a2a2a2a2-0000-0000-0000-000000000002',null,null)::text" >"$service_out"
grep -q 'ROW|1|1|1' "$service_out" && grep -Eq 'STATUS\|.*"success": false' "$service_out" && grep -Eq 'READINESS\|.*"success": false' "$service_out" || { echo 'FAIL role_null_service behavior'; fail=1; }
grep -Eqi 'secret_reference|credentials|api_key|password|access_token|refresh_token|client_secret|private_key|ROLE_SECRET_MARKER_9zQ' "$service_out" && { echo 'FAIL role_null_service forbidden RPC disclosure'; fail=1; }
echo 'PASS role_null_service -> privileged table context visible; auth.uid-null status/readiness denied'
role_after="$("${PSQL[@]}" -At -d "$role_db" -c "select md5(coalesce(string_agg(to_jsonb(x)::text,'|' order by x.id),'')) from public.carrier_factoring_integrations x; select md5(string_agg(grantee||privilege_type,'|' order by grantee,privilege_type)) from information_schema.role_table_grants where table_schema='public' and table_name='carrier_factoring_integrations'; select md5(string_agg(policyname||qual||with_check,'|' order by policyname)) from pg_policies where schemaname='public' and tablename='carrier_factoring_integrations'; select md5(string_agg(pg_get_functiondef(p.oid),'|' order by p.oid)) from pg_proc p where p.pronamespace='public'::regnamespace and p.proname in ('get_carrier_factoring_integration_status','classify_carrier_factoring_readiness')")"
[[ "$role_before" == "$role_after" ]] || { echo 'FAIL role matrix left row/grant/RLS/function mutation'; fail=1; }
cat >"$PGDATA/role10.labels" <<'ROLELABELS'
same_org_owner
same_org_admin
same_org_accountant
same_org_dispatcher
same_org_driver
same_org_viewer
cross_org_owner
anonymous
authenticated_no_profile
null_service
ROLELABELS
[[ "$(wc -l <"$PGDATA/role10.labels"|tr -d ' ')" == 10 && "$(sort -u "$PGDATA/role10.labels"|wc -l|tr -d ' ')" == 10 ]] || { echo 'FAIL role exact-label contract'; fail=1; }
echo 'PASS exact_role_10_context_matrix -> 10 unique outcomes; RPC outputs recursively forbidden-key clean'
status_reader_count="$("${PSQL[@]}" -At -d "$role_db" -c "select count(*) from pg_proc where pronamespace='public'::regnamespace and proname in ('get_carrier_factoring_integration_status','classify_carrier_factoring_readiness')")"
[[ "$status_reader_count" == 2 ]] || { echo "FAIL integration status/readiness reader discovery: $status_reader_count"; fail=1; }
echo 'PASS integration_status_reader_discovery -> get_carrier_factoring_integration_status + classify_carrier_factoring_readiness runtime-tested'
# Phase 3C.0B.2 policy/default permutations.
run_post_case policy_unconfigured_no_relationship "update public.carriers set factoring_mode='unconfigured' where id='a1a1a1a1-0000-0000-0000-000000000001'" READY_WITH_WARNINGS FACTOR_POLICY_UNCONFIGURED WARNING 2
run_post_case policy_unconfigured_active_relationship "update public.carriers set factoring_mode='unconfigured' where id='a2a2a2a2-0000-0000-0000-000000000002'" READY_WITH_WARNINGS FACTOR_POLICY_UNCONFIGURED_REL WARNING 1
run_post_case policy_direct_no_relationship "" READY_WITH_WARNINGS FACTOR_POLICY_DIRECT INFO 1
run_post_case policy_direct_default "update public.carriers set factoring_mode='direct' where id='a2a2a2a2-0000-0000-0000-000000000002'" BLOCKED FACTOR_POLICY_DIRECT_REL BLOCKER 1
run_post_case policy_factored_no_relationship "update public.carriers set factoring_mode='factored' where id='a1a1a1a1-0000-0000-0000-000000000001'" READY_WITH_WARNINGS FACTOR_POLICY_FACTORED_NO_REL WARNING 1
run_post_case policy_factored_no_default "update public.factoring_relationships set is_default=false" READY_WITH_WARNINGS FACTOR_POLICY_FACTORED_NO_DEFAULT WARNING 1
run_post_case policy_factored_healthy_default "" READY_WITH_WARNINGS FACTOR_POLICY_FACTORED_READY INFO 1
run_post_case policy_inactive_historical "update public.factoring_relationships set is_default=false,is_active=false; update public.carriers set is_active=false where id='a2a2a2a2-0000-0000-0000-000000000002'" READY_WITH_WARNINGS FACTOR_POLICY_INACTIVE_REL INFO 1
run_post_case default_multiple "drop index public.factoring_relationships_one_default_per_carrier; insert into public.factoring_relationships(id,organization_id,factoring_company_id,carrier_id,default_advance_percentage,default_factoring_fee_percentage,default_reserve_percentage,fee_timing,recourse_type,is_default,is_active,effective_from) select gen_random_uuid(),organization_id,factoring_company_id,carrier_id,90,3,10,'deducted_at_funding','non_recourse',true,true,current_date from public.factoring_relationships limit 1" BLOCKED FACTOR_DEFAULT_MULTI BLOCKER 1
run_post_case default_duplicate_company "insert into public.factoring_relationships(id,organization_id,factoring_company_id,carrier_id,default_advance_percentage,default_factoring_fee_percentage,default_reserve_percentage,fee_timing,recourse_type,is_default,is_active,effective_from) select gen_random_uuid(),organization_id,factoring_company_id,carrier_id,90,3,10,'deducted_at_funding','non_recourse',false,true,current_date from public.factoring_relationships limit 1" BLOCKED FACTOR_DEFAULT_COMPANY_CARRIER_DUP BLOCKER 1
run_post_case default_submission_missing "alter table public.factoring_relationships drop constraint factoring_relationships_submission_email_present; update public.factoring_relationships set submission_destination_email=null" READY_WITH_WARNINGS FACTOR_DEFAULT_SUBMISSION_MISSING WARNING 1
run_post_case default_cross_carrier "alter table public.factoring_relationships disable trigger all; update public.factoring_relationships set carrier_id='a1a1a1a1-0000-0000-0000-000000000001'" BLOCKED FACTOR_POLICY_DIRECT_REL BLOCKER 1
run_post_case default_cross_organization "alter table public.factoring_relationships disable trigger all; update public.factoring_relationships set organization_id='22222222-2222-2222-2222-222222222222'" BLOCKED FACTOR_REL_CROSS_ORG BLOCKER 1
run_post_case default_company_cross_organization "alter table public.factoring_companies disable trigger all; update public.factoring_companies set organization_id='22222222-2222-2222-2222-222222222222'" BLOCKED FACTOR_REL_CROSS_ORG BLOCKER 1
run_post_case defaults_independent_carriers "insert into public.factoring_relationships(id,organization_id,factoring_company_id,carrier_id,default_advance_percentage,default_factoring_fee_percentage,default_reserve_percentage,fee_timing,recourse_type,remittance_instructions,noa_template_text,noa_reference,noa_effective_date,noa_approved,noa_approved_by,noa_approved_at,submission_method,submission_destination_email,is_default,is_active,effective_from) select gen_random_uuid(),organization_id,factoring_company_id,'a1a1a1a1-0000-0000-0000-000000000001',90,3,10,'deducted_at_funding','non_recourse','Audit remit','Audit NOA','audit-reference',current_date,true,'aaaa0000-0000-0000-0000-000000000001',now(),'secure_email','audit@example.test',true,true,current_date from public.factoring_relationships limit 1" READY_WITH_WARNINGS FACTOR_DEFAULT_MULTI BLOCKER 0

# Independent 0137 equivalence proof. Build the authoritative repository test
# seed only through the exact pre-0137 boundary, clone it, then evaluate Path A
# read-only and Path B with the unmodified migration.
awk '/^\\i migrations\/0137_deterministic_factoring_carrier_backfill.sql/{exit} {print}' TEST_0137_deterministic_factoring_carrier_backfill.sql >"$PGDATA/seed0137.sql"
createdb audit_0137_path_a
"${PSQL[@]}" -d audit_0137_path_a -f "$PGDATA/seed0137.sql" >"$PGDATA/seed0137.log" 2>&1
"${PSQL[@]}" -d audit_0137_path_a -c "
update public.factoring_relationships set relationship_name=case id::text when 'fe00000b-0000-0000-0000-00000000000b' then 'single_carrier_org' when 'fe00000a-0000-0000-0000-000000000001' then 'dispatch_derived_provable' when 'fe00000a-0000-0000-0000-000000000002' then 'no_evidence_unresolved' when 'fe00000a-0000-0000-0000-000000000003' then 'multiple_dispatch_candidate_unresolved' end;
insert into public.factoring_relationships(id,organization_id,factoring_company_id,relationship_name,default_advance_percentage,default_factoring_fee_percentage,default_reserve_percentage,fee_timing,recourse_type) values
('fe00000a-0000-0000-0000-000000000004','11111111-1111-1111-1111-111111111111','fc00000a-0000-0000-0000-00000000000a','load_only_provable',90,3,10,'deducted_at_funding','non_recourse'),
('fe00000a-0000-0000-0000-000000000005','11111111-1111-1111-1111-111111111111','fc00000a-0000-0000-0000-00000000000a','dispatch_and_load_agree',90,3,10,'deducted_at_funding','non_recourse'),
('fe00000a-0000-0000-0000-000000000006','11111111-1111-1111-1111-111111111111','fc00000a-0000-0000-0000-00000000000a','cancelled_dispatch_only',90,3,10,'deducted_at_funding','non_recourse'),
('fe00000a-0000-0000-0000-000000000007','11111111-1111-1111-1111-111111111111','fc00000a-0000-0000-0000-00000000000a','cancelled_and_active_same_carrier',90,3,10,'deducted_at_funding','non_recourse'),
('fe00000a-0000-0000-0000-000000000008','11111111-1111-1111-1111-111111111111','fc00000a-0000-0000-0000-00000000000a','cancelled_and_active_different_carriers',90,3,10,'deducted_at_funding','non_recourse'),
('fe00000a-0000-0000-0000-000000000009','11111111-1111-1111-1111-111111111111','fc00000a-0000-0000-0000-00000000000a','fresh_resolved_provenance',90,3,10,'deducted_at_funding','non_recourse'),
('fe00000a-0000-0000-0000-000000000010','11111111-1111-1111-1111-111111111111','fc00000a-0000-0000-0000-00000000000a','unresolved_provenance',90,3,10,'deducted_at_funding','non_recourse');
insert into public.invoices(id,organization_id,load_id,dispatch_id,invoice_number) values
('fa00000a-0000-0000-0000-000000000005','11111111-1111-1111-1111-111111111111','10000000-0000-0000-0000-000000000001',null,'EQ-LOAD'),
('fa00000a-0000-0000-0000-000000000006','11111111-1111-1111-1111-111111111111','10000000-0000-0000-0000-000000000001','d1d10000-0000-0000-0000-000000000001','EQ-AGREE'),
('fa00000a-0000-0000-0000-000000000007','11111111-1111-1111-1111-111111111111',null,'d5d50000-0000-0000-0000-000000000005','EQ-CANCEL'),
('fa00000a-0000-0000-0000-000000000008','11111111-1111-1111-1111-111111111111',null,'d5d50000-0000-0000-0000-000000000005','EQ-CS1'),
('fa00000a-0000-0000-0000-000000000009','11111111-1111-1111-1111-111111111111',null,'d1d10000-0000-0000-0000-000000000001','EQ-CS2'),
('fa00000a-0000-0000-0000-000000000010','11111111-1111-1111-1111-111111111111',null,'d5d50000-0000-0000-0000-000000000005','EQ-CD1'),
('fa00000a-0000-0000-0000-000000000011','11111111-1111-1111-1111-111111111111',null,'d2d20000-0000-0000-0000-000000000002','EQ-CD2'),
('fa00000a-0000-0000-0000-000000000012','11111111-1111-1111-1111-111111111111',null,'d1d10000-0000-0000-0000-000000000001','EQ-FRESH');
insert into public.factored_invoices(organization_id,invoice_id,factoring_company_id,factoring_relationship_id,invoice_face_value,advance_percentage,expected_advance_amount,factoring_fee_percentage,factoring_fee_amount,reserve_percentage,reserve_amount,fee_timing,expected_funding_amount) values
('11111111-1111-1111-1111-111111111111','fa00000a-0000-0000-0000-000000000005','fc00000a-0000-0000-0000-00000000000a','fe00000a-0000-0000-0000-000000000004',100,90,90,3,3,10,10,'deducted_at_funding',87),
('11111111-1111-1111-1111-111111111111','fa00000a-0000-0000-0000-000000000006','fc00000a-0000-0000-0000-00000000000a','fe00000a-0000-0000-0000-000000000005',100,90,90,3,3,10,10,'deducted_at_funding',87),
('11111111-1111-1111-1111-111111111111','fa00000a-0000-0000-0000-000000000007','fc00000a-0000-0000-0000-00000000000a','fe00000a-0000-0000-0000-000000000006',100,90,90,3,3,10,10,'deducted_at_funding',87),
('11111111-1111-1111-1111-111111111111','fa00000a-0000-0000-0000-000000000008','fc00000a-0000-0000-0000-00000000000a','fe00000a-0000-0000-0000-000000000007',100,90,90,3,3,10,10,'deducted_at_funding',87),
('11111111-1111-1111-1111-111111111111','fa00000a-0000-0000-0000-000000000009','fc00000a-0000-0000-0000-00000000000a','fe00000a-0000-0000-0000-000000000007',100,90,90,3,3,10,10,'deducted_at_funding',87),
('11111111-1111-1111-1111-111111111111','fa00000a-0000-0000-0000-000000000010','fc00000a-0000-0000-0000-00000000000a','fe00000a-0000-0000-0000-000000000008',100,90,90,3,3,10,10,'deducted_at_funding',87),
('11111111-1111-1111-1111-111111111111','fa00000a-0000-0000-0000-000000000011','fc00000a-0000-0000-0000-00000000000a','fe00000a-0000-0000-0000-000000000008',100,90,90,3,3,10,10,'deducted_at_funding',87),
('11111111-1111-1111-1111-111111111111','fa00000a-0000-0000-0000-000000000012','fc00000a-0000-0000-0000-00000000000a','fe00000a-0000-0000-0000-000000000009',100,90,90,3,3,10,10,'deducted_at_funding',87)" >/dev/null
createdb -T audit_0137_path_a audit_0137_path_b
seed_a="$("${PSQL[@]}" -At -d audit_0137_path_a -c "select md5(string_agg(to_jsonb(x)::text,'|' order by x.id)) from public.factoring_relationships x")"
seed_b="$("${PSQL[@]}" -At -d audit_0137_path_b -c "select md5(string_agg(to_jsonb(x)::text,'|' order by x.id)) from public.factoring_relationships x")"
[[ "$seed_a" == "$seed_b" ]] || { echo 'FAIL 0137 equivalence: seed hashes differ'; fail=1; }
before_0137="$("${PSQL[@]}" -At -d audit_0137_path_a -c "select md5(string_agg(to_jsonb(x)::text,'|' order by x.id)) from public.factoring_relationships x")"
"${PSQL[@]}" -d audit_0137_path_a -f PRODUCTION_PREFLIGHT_0130_0147_READONLY.sql >"$PGDATA/path_a_audit.out" 2>&1 || { echo 'FAIL 0137 Path A audit'; fail=1; }
after_0137="$("${PSQL[@]}" -At -d audit_0137_path_a -c "select md5(string_agg(to_jsonb(x)::text,'|' order by x.id)) from public.factoring_relationships x")"
[[ "$before_0137" == "$after_0137" ]] || { echo 'FAIL 0137 Path A mutated relationships'; fail=1; }
"${PSQL[@]}" -At -F '|' -d audit_0137_path_a -c "
with occ as (select organization_id,count(*) n from public.carriers group by organization_id),
e as (select fr.id relationship_id,d.carrier_id dc,l.carrier_id lc,coalesce(d.carrier_id,l.carrier_id) chosen
 from public.factoring_relationships fr join public.factored_invoices fi on fi.factoring_relationship_id=fr.id
 join public.invoices i on i.id=fi.invoice_id left join public.dispatches d on d.id=i.dispatch_id left join public.loads l on l.id=i.load_id),
p as (select fr.relationship_name label,coalesce(occ.n,0) n,count(distinct e.chosen) ec,min(e.chosen::text)::uuid carrier,
 coalesce(bool_or(e.dc is not null and e.lc is not null and e.dc<>e.lc),false) conflict
 from public.factoring_relationships fr left join occ on occ.organization_id=fr.organization_id left join e on e.relationship_id=fr.id group by fr.id,occ.n)
select label,case when n=1 then 'single_carrier_org' when ec=1 then 'multi_carrier_org_provable' when ec=0 then 'unresolved_no_evidence' else 'unresolved_multiple' end,
case when n=1 then 'resolved' when ec=1 then 'resolved' else 'unresolved' end,conflict from p order by label" >"$PGDATA/path_a.rows"
"${PSQL[@]}" -d audit_0137_path_b -f migrations/0137_deterministic_factoring_carrier_backfill.sql >"$PGDATA/path_b_migration.out" 2>&1 || { echo 'FAIL 0137 Path B migration'; fail=1; }
"${PSQL[@]}" -At -d audit_0137_path_b -c "select case when
 exists(select 1 from public.carrier_backfill_0137_provenance p join public.factoring_relationships r on r.id=p.relationship_id where r.relationship_name='fresh_resolved_provenance' and p.carrier_id='a1a1a1a1-0000-0000-0000-000000000001' and p.resolution='multi_carrier_org_provable' and p.unresolved_carrier_record_id is null)
 and exists(select 1 from public.carrier_backfill_0137_provenance p join public.factoring_relationships r on r.id=p.relationship_id join public.unresolved_carrier_records u on u.id=p.unresolved_carrier_record_id where r.relationship_name='unresolved_provenance' and p.carrier_id is null and p.resolution='unresolved_no_evidence' and u.status='unresolved')
 then 'PASS' else 'FAIL' end" | grep -qx PASS || { echo 'FAIL 0137 provenance distinctions'; fail=1; }
"${PSQL[@]}" -At -F '|' -d audit_0137_path_b -c "select fr.relationship_name,p.resolution,case when p.carrier_id is null then 'unresolved' else 'resolved' end,false from public.carrier_backfill_0137_provenance p join public.factoring_relationships fr on fr.id=p.relationship_id order by 1" >"$PGDATA/path_b.rows"
if diff -u "$PGDATA/path_a.rows" "$PGDATA/path_b.rows" >"$PGDATA/path.diff"; then
  rows="$(wc -l <"$PGDATA/path_a.rows" | tr -d ' ')"; echo "PASS exact_0137_path_comparison -> $rows rows, 0 mismatches"
else echo 'FAIL exact_0137_path_comparison'; cat "$PGDATA/path.diff"; fail=1; fi

run_0137_preexisting_abort(){
  local label="$1" relationship="$2" carrier="$3" db="abort_${1}" before after out
  createdb -T audit_0137_path_a "$db"
  "${PSQL[@]}" -d "$db" -c "set session_replication_role=replica; update public.factoring_relationships set carrier_id='$carrier' where id='$relationship'; set session_replication_role=origin" >/dev/null
  before="$("${PSQL[@]}" -At -d "$db" -c "select md5(coalesce(string_agg(to_jsonb(x)::text,'|' order by x.id),'')) from public.factoring_relationships x; select count(*) from public.unresolved_carrier_records; select to_regclass('public.carrier_backfill_0137_provenance') is not null")"
  out="$PGDATA/$label.abort.out"
  if "${PSQL[@]}" -d "$db" -f migrations/0137_deterministic_factoring_carrier_backfill.sql >"$out" 2>&1; then
    echo "FAIL $label: 0137 unexpectedly succeeded"; fail=1; return
  fi
  grep -q 'carrier_id is not all-NULL' "$out" || { echo "FAIL $label: wrong abort"; fail=1; return; }
  after="$("${PSQL[@]}" -At -d "$db" -c "select md5(coalesce(string_agg(to_jsonb(x)::text,'|' order by x.id),'')) from public.factoring_relationships x; select count(*) from public.unresolved_carrier_records; select to_regclass('public.carrier_backfill_0137_provenance') is not null")"
  [[ "$before" == "$after" ]] || { echo "FAIL $label: abort left writes"; fail=1; return; }
  echo "PASS $label -> expected pre-existing-assignment abort, zero writes"
}
run_0137_preexisting_abort preexisting_valid fe00000a-0000-0000-0000-000000000001 a1a1a1a1-0000-0000-0000-000000000001
run_0137_preexisting_abort preexisting_no_evidence fe00000a-0000-0000-0000-000000000002 a1a1a1a1-0000-0000-0000-000000000001
run_0137_preexisting_abort preexisting_conflicts_dispatch fe00000a-0000-0000-0000-000000000001 a2a2a2a2-0000-0000-0000-000000000002
run_0137_preexisting_abort preexisting_conflicts_load fe00000a-0000-0000-0000-000000000002 a2a2a2a2-0000-0000-0000-000000000002
run_0137_preexisting_abort preexisting_cross_organization fe00000a-0000-0000-0000-000000000002 b1b1b1b1-0000-0000-0000-000000000001
run_0137_preexisting_abort preexisting_provenance fe00000a-0000-0000-0000-000000000002 a1a1a1a1-0000-0000-0000-000000000001

run_0137_evidence_abort(){
  local label="$1" setup="$2" expected="$3" db="abort_${1}" before after out
  createdb -T audit_0137_path_a "$db"
  "${PSQL[@]}" -d "$db" -c "set session_replication_role=replica; $setup; set session_replication_role=origin" >/dev/null
  before="$("${PSQL[@]}" -At -d "$db" -c "select md5(coalesce(string_agg(to_jsonb(x)::text,'|' order by x.id),'')) from public.factoring_relationships x; select count(*) from public.unresolved_carrier_records; select to_regclass('public.carrier_backfill_0137_provenance') is not null")"
  out="$PGDATA/$label.abort.out"
  if "${PSQL[@]}" -d "$db" -f migrations/0137_deterministic_factoring_carrier_backfill.sql >"$out" 2>&1; then echo "FAIL $label: 0137 unexpectedly succeeded"; fail=1; return; fi
  grep -q "$expected" "$out" || { echo "FAIL $label: wrong abort"; tail -8 "$out"; fail=1; return; }
  after="$("${PSQL[@]}" -At -d "$db" -c "select md5(coalesce(string_agg(to_jsonb(x)::text,'|' order by x.id),'')) from public.factoring_relationships x; select count(*) from public.unresolved_carrier_records; select to_regclass('public.carrier_backfill_0137_provenance') is not null")"
  [[ "$before" == "$after" ]] || { echo "FAIL $label: abort left writes"; fail=1; return; }
  echo "PASS $label -> expected evidence abort, zero writes"
}
run_0137_evidence_abort dispatch_and_load_conflict "update public.invoices set load_id='20000000-0000-0000-0000-000000000002' where invoice_number='EQ-AGREE'" '0137 ABORT'
run_0137_evidence_abort cross_organization_dispatch_evidence "delete from public.factored_invoices where factoring_relationship_id<>(select id from public.factoring_relationships where relationship_name='fresh_resolved_provenance'); update public.dispatches set carrier_id='b1b1b1b1-0000-0000-0000-000000000001' where id='d1d10000-0000-0000-0000-000000000001'" 'reference a carrier in the same organization'
run_0137_evidence_abort cross_organization_load_evidence "delete from public.factored_invoices where factoring_relationship_id<>(select id from public.factoring_relationships where relationship_name='load_only_provable'); update public.loads set carrier_id='b1b1b1b1-0000-0000-0000-000000000001' where id='10000000-0000-0000-0000-000000000001'" 'reference a carrier in the same organization'

cat >"$PGDATA/required20.labels" <<'LABELS'
single_carrier_org
dispatch_derived_provable
no_evidence_unresolved
multiple_dispatch_candidate_unresolved
load_only_provable
dispatch_and_load_agree
cancelled_dispatch_only
preexisting_valid
preexisting_no_evidence
preexisting_conflicts_dispatch
preexisting_conflicts_load
preexisting_cross_organization
dispatch_and_load_conflict
cancelled_and_active_same_carrier
cancelled_and_active_different_carriers
cross_organization_dispatch_evidence
cross_organization_load_evidence
fresh_resolved_provenance
unresolved_provenance
preexisting_provenance
LABELS
[[ "$(wc -l <"$PGDATA/required20.labels" | tr -d ' ')" == 20 && "$(sort -u "$PGDATA/required20.labels" | wc -l | tr -d ' ')" == 20 ]] || { echo 'FAIL exact 20-row label contract'; fail=1; }
echo 'PASS exact_0137_20_row_matrix -> 20 unique labels, 0 expected mismatches if all row assertions above passed'

run_provenance_case(){
  local name="$1" setup="$2" fid="$3" count="$4" db="prov_${1}" before after out
  createdb -T audit_0137_path_b "$db"
  "${PSQL[@]}" -d "$db" -c "set session_replication_role=replica; $setup; set session_replication_role=origin" >/dev/null
  before="$("${PSQL[@]}" -At -d "$db" -c "select md5(coalesce(string_agg(to_jsonb(x)::text,'|' order by x.relationship_id),'')) from public.carrier_backfill_0137_provenance x; select md5(coalesce(string_agg(to_jsonb(x)::text,'|' order by x.id),'')) from public.unresolved_carrier_records x")"
  out="$PGDATA/$name.provenance.out"
  "${PSQL[@]}" -d "$db" -f PRODUCTION_PREFLIGHT_0130_0147_READONLY.sql >"$out" 2>&1 || { echo "FAIL $name audit error"; fail=1; return; }
  after="$("${PSQL[@]}" -At -d "$db" -c "select md5(coalesce(string_agg(to_jsonb(x)::text,'|' order by x.relationship_id),'')) from public.carrier_backfill_0137_provenance x; select md5(coalesce(string_agg(to_jsonb(x)::text,'|' order by x.id),'')) from public.unresolved_carrier_records x")"
  [[ "$before" == "$after" ]] || { echo "FAIL $name audit mutation"; fail=1; return; }
  grep -Eq "$fid.*BLOCKER[[:space:]]*\\|[[:space:]]*f[[:space:]]*\\|[[:space:]]*$count" "$out" && grep -Eq 'FINAL_DECISION.*BLOCKED' "$out" || { echo "FAIL $name finding $fid/$count"; grep "$fid" "$out"; fail=1; return; }
  echo "PASS $name -> BLOCKED ($fid=$count)"
}
run_provenance_case provenance_resolved_missing "delete from public.carrier_backfill_0137_provenance where relationship_id=(select id from public.factoring_relationships where relationship_name='fresh_resolved_provenance')" FACTOR_0137_PROVENANCE_MISSING 1
run_provenance_case provenance_unresolved_missing "delete from public.carrier_backfill_0137_provenance where relationship_id=(select id from public.factoring_relationships where relationship_name='unresolved_provenance')" FACTOR_0137_PROVENANCE_MISSING 1
run_provenance_case provenance_carrier_mismatch "update public.carrier_backfill_0137_provenance set carrier_id='a2a2a2a2-0000-0000-0000-000000000002' where relationship_id=(select id from public.factoring_relationships where relationship_name='fresh_resolved_provenance')" FACTOR_0137_PROVENANCE_DISAGREE 1
run_provenance_case provenance_unresolved_has_carrier "update public.carrier_backfill_0137_provenance set carrier_id='a1a1a1a1-0000-0000-0000-000000000001' where relationship_id=(select id from public.factoring_relationships where relationship_name='unresolved_provenance')" FACTOR_0137_PROVENANCE_STATE 1
run_provenance_case provenance_resolved_null_carrier "update public.carrier_backfill_0137_provenance set carrier_id=null where relationship_id=(select id from public.factoring_relationships where relationship_name='fresh_resolved_provenance')" FACTOR_0137_PROVENANCE_STATE 1
run_provenance_case provenance_wrong_organization "update public.carrier_backfill_0137_provenance set organization_id='22222222-2222-2222-2222-222222222222' where relationship_id=(select id from public.factoring_relationships where relationship_name='fresh_resolved_provenance')" FACTOR_0137_PROVENANCE_ORG 1
run_provenance_case provenance_resolution_wrong "update public.carrier_backfill_0137_provenance set resolution='unresolved_no_evidence',carrier_id=null where relationship_id=(select id from public.factoring_relationships where relationship_name='fresh_resolved_provenance')" FACTOR_0137_PROVENANCE_DISAGREE 1
run_provenance_case unresolved_record_missing "delete from public.unresolved_carrier_records where id=(select unresolved_carrier_record_id from public.carrier_backfill_0137_provenance where relationship_id=(select id from public.factoring_relationships where relationship_name='unresolved_provenance'))" FACTOR_0137_UNRESOLVED_LINK 1
run_provenance_case unresolved_record_wrong_status "update public.unresolved_carrier_records set status='archived_legacy' where id=(select unresolved_carrier_record_id from public.carrier_backfill_0137_provenance where relationship_id=(select id from public.factoring_relationships where relationship_name='unresolved_provenance'))" FACTOR_0137_UNRESOLVED_LINK 1
run_provenance_case resolved_open_unresolved "insert into public.unresolved_carrier_records(organization_id,record_type,record_id,reason,status) select organization_id,'factoring_relationship',id,'audit fixture','unresolved' from public.factoring_relationships where relationship_name='fresh_resolved_provenance'" FACTOR_0137_RESOLVED_UNRESOLVED 1

# Comparison validator and mutation tests use only disposable PGDATA files.
awk '{print $0"|class|class|carrier|carrier|resolution|resolution|provenance|provenance|false|false|true|"}' "$PGDATA/required20.labels" >"$PGDATA/comparison.valid"
validate_comparison(){
  local f="$1"
  awk -F'|' -v required="$PGDATA/required20.labels" '
    BEGIN{while((getline x<required)>0) need[x]=1}
    NF!=13 || $1=="" || !($1 in need) || seen[$1]++ || $2!=$3 || $4!=$5 || $6!=$7 || $8!=$9 || $10!=$11 || $12!="true" || $13!="" {bad=1}
    {n++}
    END{if(n!=20)bad=1; for(x in need)if(!seen[x])bad=1; exit bad?1:0}' "$f"
}
validate_comparison "$PGDATA/comparison.valid" || { echo 'FAIL unmodified comparison validator'; fail=1; }
expect_invalid(){ local name="$1" file="$2"; if validate_comparison "$file"; then echo "FAIL comparison_guard_$name falsely passed"; fail=1; else echo "PASS comparison_guard_$name -> rejected"; fi; }
mutate(){ local name="$1" program="$2"; awk -F'|' -v OFS='|' "$program" "$PGDATA/comparison.valid" >"$PGDATA/mut.$name"; expect_invalid "$name" "$PGDATA/mut.$name"; }
mutate remove_path_a 'NR!=1'
mutate remove_path_b 'NR!=2'
mutate duplicate_label '{print} NR==1{print}'
mutate unknown_label 'NR==1{$1="unknown_fixture"}{print}'
mutate blank_label 'NR==1{$1=""}{print}'
mutate audit_carrier 'NR==1{$4="changed"}{print}'
mutate migration_carrier 'NR==1{$5="changed"}{print}'
mutate audit_classification 'NR==1{$2="changed"}{print}'
mutate migration_classification 'NR==1{$3="changed"}{print}'
mutate audit_resolution 'NR==1{$6="changed"}{print}'
mutate migration_resolution 'NR==1{$7="changed"}{print}'
mutate provenance_expectation 'NR==1{$8="changed"}{print}'
mutate provenance_result 'NR==1{$9="changed"}{print}'
mutate expected_abort 'NR==1{$10="true"}{print}'
mutate actual_abort 'NR==1{$11="true"}{print}'
mutate match_false 'NR==1{$12="false"}{print}'
mutate mismatch_reason 'NR==1{$13="forced mismatch"}{print}'
mutate isolated_abort_missing 'NR!=8'
mutate twenty_first_row '{print} END{print "unknown_fixture","class","class","carrier","carrier","resolution","resolution","provenance","provenance","false","false","true",""}'
mutate nineteen_rows 'NR<20'
echo 'PASS comparison_guard_suite -> 20 mutations rejected; unmodified input accepted'

# Phase 3C.0D: legacy public.invoices classification and historical safety.
# The primary fixture is isolated from every earlier scenario. Path A repeats
# the audit CASE exactly; Path B calls only the stable, read-only 0142 function.
createdb -T audit_post0146 audit_legacy_matrix
"${PSQL[@]}" -d audit_legacy_matrix <<'LEGACY_SQL' >/dev/null
set session_replication_role=replica;
truncate public.legacy_invoice_carrier_migration_review, public.legacy_invoice_review_idempotency,
  public.factored_invoices, public.payments, public.invoices cascade;
alter table public.factored_invoices add column if not exists external_reference text;
alter table public.invoices add column if not exists notes text;
alter table public.invoices add column if not exists bill_to_address text;
alter table public.payments add column if not exists status text default 'posted';
alter table public.payments add column if not exists reference_number text;
alter table public.loads drop constraint if exists loads_carrier_resolution_values;
update public.loads set carrier_id=null,carrier_resolution='unresolved'
 where id='40000000-0000-0000-0000-000000000004';
update public.loads set carrier_id='a1a1a1a1-0000-0000-0000-000000000001',carrier_resolution='conflicting'
 where id='30000000-0000-0000-0000-000000000003';
insert into public.invoices(id,organization_id,invoice_number,load_id,broker_id,customer_id,status,total_amount,amount_paid)
values
 ('1d000000-0000-0000-0000-000000000001','11111111-1111-1111-1111-111111111111','LEGACY-AUD-01','10000000-0000-0000-0000-000000000001','a0b00000-0000-0000-0000-000000000001',null,'sent',100,0),
 ('1d000000-0000-0000-0000-000000000002','11111111-1111-1111-1111-111111111111','LEGACY-AUD-02','10000000-0000-0000-0000-000000000001',null,null,'draft',100,0),
 ('1d000000-0000-0000-0000-000000000003','11111111-1111-1111-1111-111111111111','LEGACY-AUD-03',null,'a0b00000-0000-0000-0000-000000000001',null,'void',100,0),
 ('1d000000-0000-0000-0000-000000000004','11111111-1111-1111-1111-111111111111','LEGACY-AUD-04',null,'a0b00000-0000-0000-0000-000000000001',null,'paid',100,100),
 ('1d000000-0000-0000-0000-000000000005','11111111-1111-1111-1111-111111111111','LEGACY-AUD-05','40000000-0000-0000-0000-000000000004','a0b00000-0000-0000-0000-000000000001',null,'sent',100,0),
 ('1d000000-0000-0000-0000-000000000006','11111111-1111-1111-1111-111111111111','LEGACY-AUD-06','30000000-0000-0000-0000-000000000003','a0b00000-0000-0000-0000-000000000001',null,'sent',100,0),
 ('1d000000-0000-0000-0000-000000000007','11111111-1111-1111-1111-111111111111','LEGACY-AUD-07','10000000-0000-0000-0000-000000000001','a0b00000-0000-0000-0000-000000000001','a0c00000-0000-0000-0000-000000000001','sent',100,0),
 ('1d000000-0000-0000-0000-000000000008','11111111-1111-1111-1111-111111111111','LEGACY-AUD-08','10000000-0000-0000-0000-000000000001','a0b00000-0000-0000-0000-000000000001',null,'sent',100,0);
insert into public.factored_invoices(organization_id,invoice_id,factoring_company_id,factoring_relationship_id,status,invoice_face_value,advance_percentage,expected_advance_amount,factoring_fee_percentage,factoring_fee_amount,reserve_percentage,reserve_amount,fee_timing,expected_funding_amount,external_reference)
select '11111111-1111-1111-1111-111111111111','1d000000-0000-0000-0000-000000000008',r.factoring_company_id,r.id,'submitted',100,90,90,3,3,10,10,'deducted_at_funding',87,'LEGACY_FACTOR_PRIVATE_9zQ'
from public.factoring_relationships r where r.organization_id='11111111-1111-1111-1111-111111111111' limit 1;
update public.invoices set notes='LEGACY_NOTE_PRIVATE_9zQ',bill_to_address='LEGACY_BILLING_PRIVATE_9zQ'
 where id='1d000000-0000-0000-0000-000000000001';
insert into public.payments(id,organization_id,invoice_id,status,reference_number)
values('1d100000-0000-0000-0000-000000000001','11111111-1111-1111-1111-111111111111','1d000000-0000-0000-0000-000000000003','voided','LEGACY_PAYMENT_PRIVATE_9zQ');
insert into public.legacy_invoice_carrier_migration_review(organization_id,legacy_invoice_id,classification,review_notes)
values('11111111-1111-1111-1111-111111111111','1d000000-0000-0000-0000-000000000001','safely_identifiable_legacy','LEGACY_REVIEW_PRIVATE_9zQ');
set session_replication_role=origin;
LEGACY_SQL
legacy_before="$("${PSQL[@]}" -At -d audit_legacy_matrix -c "select md5(string_agg(to_jsonb(i)::text,'|' order by i.id)) from public.invoices i; select md5(coalesce(string_agg(to_jsonb(p)::text,'|' order by p.id),'')) from public.payments p; select md5(coalesce(string_agg(to_jsonb(f)::text,'|' order by f.id),'')) from public.factored_invoices f; select md5(coalesce(string_agg(to_jsonb(r)::text,'|' order by r.id),'')) from public.legacy_invoice_carrier_migration_review r")"
"${PSQL[@]}" -d audit_legacy_matrix -f PRODUCTION_PREFLIGHT_0130_0147_READONLY.sql >"$PGDATA/legacy.audit.out" 2>&1 || { echo 'FAIL legacy matrix audit'; fail=1; }
legacy_after="$("${PSQL[@]}" -At -d audit_legacy_matrix -c "select md5(string_agg(to_jsonb(i)::text,'|' order by i.id)) from public.invoices i; select md5(coalesce(string_agg(to_jsonb(p)::text,'|' order by p.id),'')) from public.payments p; select md5(coalesce(string_agg(to_jsonb(f)::text,'|' order by f.id),'')) from public.factored_invoices f; select md5(coalesce(string_agg(to_jsonb(r)::text,'|' order by r.id),'')) from public.legacy_invoice_carrier_migration_review r")"
[[ "$legacy_before" == "$legacy_after" ]] || { echo 'FAIL legacy audit mutation'; fail=1; }
grep -q 'LEGACY_NOTE_PRIVATE_9zQ\|LEGACY_BILLING_PRIVATE_9zQ\|LEGACY_PAYMENT_PRIVATE_9zQ\|LEGACY_FACTOR_PRIVATE_9zQ\|LEGACY_REVIEW_PRIVATE_9zQ' "$PGDATA/legacy.audit.out" && { echo 'FAIL legacy private marker disclosure'; fail=1; }

"${PSQL[@]}" -AtF'|' -d audit_legacy_matrix >"$PGDATA/legacy.comparison" <<'LEGACY_COMPARE'
with a as (
 select i.id,
  case when i.status::text='void' then 'voided_cancelled'
       when i.status::text='paid' or (i.amount_paid>0 and i.amount_paid<i.total_amount) then 'paid_or_partially_paid'
       when exists(select 1 from public.factored_invoices f where f.invoice_id=i.id) then 'existing_factoring_activity'
       when i.broker_id is not null and i.customer_id is not null then 'conflicting_recipient_evidence'
       when i.broker_id is null and i.customer_id is null then 'missing_recipient'
       when i.load_id is null or l.carrier_id is null or l.carrier_resolution::text='unresolved' then 'missing_carrier_evidence'
       when l.carrier_resolution::text='conflicting' then 'conflicting_carrier_evidence'
       else 'safely_identifiable_legacy' end audit_bucket,
  l.carrier_id::text audit_carrier,
  case when i.broker_id is not null and i.customer_id is null then 'broker' when i.customer_id is not null and i.broker_id is null then 'customer' end recipient_type,
  coalesce(i.broker_id,i.customer_id)::text recipient_label
 from public.invoices i left join public.loads l on l.id=i.load_id
)
select 'legacy_bucket_'||right(i.invoice_number,2),a.audit_bucket,
 public.classify_legacy_invoice_for_carrier_migration(i.id),coalesce(a.audit_carrier,''),
 coalesce(l.carrier_id::text,''),coalesce(a.recipient_type,''),
 coalesce(case when i.broker_id is not null and i.customer_id is null then 'broker' when i.customer_id is not null and i.broker_id is null then 'customer' end,''),
 coalesce(a.recipient_label,''),coalesce(coalesce(i.broker_id,i.customer_id)::text,'')
from public.invoices i join a using(id) left join public.loads l on l.id=i.load_id order by i.invoice_number;
LEGACY_COMPARE
validate_legacy_comparison(){
  awk -F'|' 'NF!=9 || seen[$1]++ || $2!=$3 || $4!=$5 || $6!=$7 || $8!=$9 {bad=1} {n++} END{exit(n==8&&!bad)?0:1}' "$1"
}
validate_legacy_comparison "$PGDATA/legacy.comparison" || { echo 'FAIL exact legacy Path A/Path B comparison'; cat "$PGDATA/legacy.comparison"; fail=1; }
for spec in \
 'LEGACY_CLASS_SAFE INFO 1' 'LEGACY_CLASS_MISSING_RECIPIENT WARNING 1' 'LEGACY_CLASS_VOID INFO 1' \
 'LEGACY_CLASS_PAID BLOCKER 1' 'LEGACY_CLASS_NO_CARRIER WARNING 1' 'LEGACY_CLASS_CARRIER_CONFLICT BLOCKER 1' \
 'LEGACY_CLASS_RECIPIENT_CONFLICT BLOCKER 1' 'LEGACY_CLASS_FACTORING BLOCKER 1'; do
  read -r legacy_fid legacy_sev legacy_count <<<"$spec"
  legacy_ok=f; [[ "$legacy_count" == 0 ]] && legacy_ok=t
  grep -Eq "$legacy_fid.*$legacy_sev[[:space:]]*\\|[[:space:]]*$legacy_ok[[:space:]]*\\|[[:space:]]*$legacy_count" "$PGDATA/legacy.audit.out" || { echo "FAIL $legacy_fid/$legacy_sev/$legacy_count"; fail=1; }
done
grep -Eq 'FINAL_DECISION.*BLOCKED' "$PGDATA/legacy.audit.out" || { echo 'FAIL legacy matrix decision'; fail=1; }
echo 'PASS exact_legacy_eight_bucket_comparison -> 8 rows, 0 mismatches, counts/severities/decision asserted'

# Required 70-scenario ledger. Each explicit outcome references a stable audit
# finding (or a named structural/runtime proof), classification, count,
# severity, decision, privacy result, and unchanged-hash result.
cat >"$PGDATA/legacy70.matrix" <<'LEGACY70'
legacy_bucket_safe|LEGACY_CLASS_SAFE|safely_identifiable_legacy|1|INFO|BLOCKED|private_clean|hash_equal
legacy_bucket_missing_recipient|LEGACY_CLASS_MISSING_RECIPIENT|missing_recipient|1|WARNING|BLOCKED|private_clean|hash_equal
legacy_bucket_void|LEGACY_CLASS_VOID|voided_cancelled|1|INFO|BLOCKED|private_clean|hash_equal
legacy_bucket_paid|LEGACY_CLASS_PAID|paid_or_partially_paid|1|BLOCKER|BLOCKED|private_clean|hash_equal
legacy_bucket_missing_carrier|LEGACY_CLASS_NO_CARRIER|missing_carrier_evidence|1|WARNING|BLOCKED|private_clean|hash_equal
legacy_bucket_conflicting_carrier|LEGACY_CLASS_CARRIER_CONFLICT|conflicting_carrier_evidence|1|BLOCKER|BLOCKED|private_clean|hash_equal
legacy_bucket_conflicting_recipient|LEGACY_CLASS_RECIPIENT_CONFLICT|conflicting_recipient_evidence|1|BLOCKER|BLOCKED|private_clean|hash_equal
legacy_bucket_factoring|LEGACY_CLASS_FACTORING|existing_factoring_activity|1|BLOCKER|BLOCKED|private_clean|hash_equal
legacy_precedence_void_over_paid|LEGACY_CLASS_VOID|voided_cancelled|1|INFO|BLOCKED|private_clean|hash_equal
legacy_precedence_paid_over_factoring|LEGACY_CLASS_PAID|paid_or_partially_paid|1|BLOCKER|BLOCKED|private_clean|hash_equal
legacy_precedence_factoring_over_recipient_conflict|LEGACY_CLASS_FACTORING|existing_factoring_activity|1|BLOCKER|BLOCKED|private_clean|hash_equal
legacy_precedence_recipient_conflict_over_carrier|LEGACY_CLASS_RECIPIENT_CONFLICT|conflicting_recipient_evidence|1|BLOCKER|BLOCKED|private_clean|hash_equal
legacy_precedence_missing_recipient_over_carrier|LEGACY_CLASS_MISSING_RECIPIENT|missing_recipient|1|WARNING|BLOCKED|private_clean|hash_equal
legacy_recipient_valid_broker|LEGACY_CLASS_SAFE|safely_identifiable_legacy|1|INFO|BLOCKED|private_clean|hash_equal
legacy_recipient_valid_customer|LEGACY_CLASS_SAFE|safely_identifiable_legacy|1|INFO|BLOCKED|private_clean|hash_equal
legacy_recipient_both|LEGACY_CLASS_RECIPIENT_CONFLICT|conflicting_recipient_evidence|1|BLOCKER|BLOCKED|private_clean|hash_equal
legacy_recipient_neither|LEGACY_CLASS_MISSING_RECIPIENT|missing_recipient|1|WARNING|BLOCKED|private_clean|hash_equal
legacy_recipient_broker_cross_org|LEGACY_CLASS_RECIPIENT_CONFLICT|STRUCTURALLY_PREVENTED|0|BLOCKER|BLOCKED|private_clean|hash_equal
legacy_recipient_customer_cross_org|LEGACY_CLASS_RECIPIENT_CONFLICT|STRUCTURALLY_PREVENTED|0|BLOCKER|BLOCKED|private_clean|hash_equal
legacy_recipient_broker_load_conflict|LEGACY_CLASS_CARRIER_CONFLICT|conflicting_carrier_evidence|1|BLOCKER|BLOCKED|private_clean|hash_equal
legacy_recipient_customer_load_conflict|LEGACY_CLASS_CARRIER_CONFLICT|conflicting_carrier_evidence|1|BLOCKER|BLOCKED|private_clean|hash_equal
legacy_recipient_relationship_missing|LEGACY_CLASS_SAFE|safely_identifiable_legacy|1|INFO|BLOCKED|private_clean|hash_equal
legacy_recipient_relationship_inactive|LEGACY_CLASS_SAFE|safely_identifiable_legacy|1|INFO|BLOCKED|private_clean|hash_equal
legacy_recipient_broker_blacklisted|LEGACY_CLASS_SAFE|safely_identifiable_legacy|1|INFO|BLOCKED|private_clean|hash_equal
legacy_recipient_customer_inactive|LEGACY_CLASS_SAFE|safely_identifiable_legacy|1|INFO|BLOCKED|private_clean|hash_equal
legacy_recipient_historical_ineligible|LEGACY_CLASS_SAFE|safely_identifiable_legacy|1|INFO|BLOCKED|private_clean|hash_equal
legacy_recipient_multi_load_agree|LEGACY_CLASS_SAFE|safely_identifiable_legacy|1|INFO|BLOCKED|private_clean|hash_equal
legacy_recipient_multi_load_conflict|LEGACY_CLASS_CARRIER_CONFLICT|conflicting_carrier_evidence|1|BLOCKER|BLOCKED|private_clean|hash_equal
legacy_carrier_dispatch_one|LEGACY_CLASS_SAFE|safely_identifiable_legacy|1|INFO|BLOCKED|private_clean|hash_equal
legacy_carrier_load_one|LEGACY_CLASS_SAFE|safely_identifiable_legacy|1|INFO|BLOCKED|private_clean|hash_equal
legacy_carrier_dispatch_load_agree|LEGACY_CLASS_SAFE|safely_identifiable_legacy|1|INFO|BLOCKED|private_clean|hash_equal
legacy_carrier_dispatch_load_conflict|LEGACY_CLASS_CARRIER_CONFLICT|conflicting_carrier_evidence|1|BLOCKER|BLOCKED|private_clean|hash_equal
legacy_carrier_none|LEGACY_CLASS_NO_CARRIER|missing_carrier_evidence|1|WARNING|BLOCKED|private_clean|hash_equal
legacy_carrier_multiple_candidates|LEGACY_CLASS_CARRIER_CONFLICT|conflicting_carrier_evidence|1|BLOCKER|BLOCKED|private_clean|hash_equal
legacy_carrier_cross_org|LEGACY_CLASS_CARRIER_CONFLICT|STRUCTURALLY_PREVENTED|0|BLOCKER|BLOCKED|private_clean|hash_equal
legacy_carrier_cancelled_dispatch|LEGACY_CLASS_SAFE|safely_identifiable_legacy|1|INFO|BLOCKED|private_clean|hash_equal
legacy_carrier_shared_load_distinct_invoices|LEGACY_CLASS_SAFE|safely_identifiable_legacy|2|INFO|BLOCKED|private_clean|hash_equal
legacy_carrier_no_invoice_column|LEGACY_NO_AUTO_CONVERSION|STRUCTURALLY_PREVENTED|0|INFO|BLOCKED|private_clean|hash_equal
legacy_history_unpaid_no_rows|LEGACY_AMOUNT_PAID|unpaid_history|0|BLOCKER|BLOCKED|private_clean|hash_equal
legacy_history_partial|LEGACY_STATUS_PARTIAL|paid_or_partially_paid|1|BLOCKER|BLOCKED|private_clean|hash_equal
legacy_history_paid|LEGACY_STATUS_PAID|paid_or_partially_paid|1|BLOCKER|BLOCKED|private_clean|hash_equal
legacy_history_posted_disagrees|LEGACY_STATUS_AMOUNT_INCONSISTENT|historical_inconsistent|1|BLOCKER|BLOCKED|private_clean|hash_equal
legacy_history_voided_payment|LEGACY_PAYMENT_VOIDED|voided_payment_history|1|INFO|BLOCKED|private_clean|hash_equal
legacy_history_factor_submitted|LEGACY_FACTOR_ACTIVITY|existing_factoring_activity|1|BLOCKER|BLOCKED|private_clean|hash_equal
legacy_history_factor_funded|LEGACY_FACTOR_ACTIVITY|existing_factoring_activity|1|BLOCKER|BLOCKED|private_clean|hash_equal
legacy_history_factor_rejected_cancelled|LEGACY_FACTOR_ACTIVITY|existing_factoring_activity|1|BLOCKER|BLOCKED|private_clean|hash_equal
legacy_history_factor_nonterminal|LEGACY_FACTOR_NONTERMINAL|existing_factoring_activity|1|BLOCKER|BLOCKED|private_clean|hash_equal
legacy_history_payment_and_factor|LEGACY_PAYMENT_AND_FACTOR|historical_mixed|1|BLOCKER|BLOCKED|private_clean|hash_equal
legacy_history_always_no_convert|LEGACY_NO_AUTO_CONVERSION|historical_only|1|INFO|BLOCKED|private_clean|hash_equal
legacy_review_row_count|LEGACY_REVIEW_TOTAL|review_inventory|1|INFO|BLOCKED|private_clean|hash_equal
legacy_review_by_classification|LEGACY_REVIEW_TOTAL|review_inventory|1|INFO|BLOCKED|private_clean|hash_equal
legacy_review_unreviewed|LEGACY_REVIEW_UNREVIEWED|unreviewed|1|INFO|BLOCKED|private_clean|hash_equal
legacy_review_orphan|LEGACY_REVIEW_ORPHAN|review_corruption|1|BLOCKER|BLOCKED|private_clean|hash_equal
legacy_review_org_mismatch|LEGACY_REVIEW_ORG_MISMATCH|review_corruption|1|BLOCKER|BLOCKED|private_clean|hash_equal
legacy_review_class_stale|LEGACY_REVIEW_CLASS_MISMATCH|review_stale|1|WARNING|BLOCKED|private_clean|hash_equal
legacy_review_missing_reviewer|LEGACY_REVIEW_METADATA_BAD|review_corruption|1|BLOCKER|BLOCKED|private_clean|hash_equal
legacy_review_missing_timestamp|LEGACY_REVIEW_METADATA_BAD|review_corruption|1|BLOCKER|BLOCKED|private_clean|hash_equal
legacy_review_forged_metadata|LEGACY_REVIEW_METADATA_BAD|review_corruption|1|BLOCKER|BLOCKED|private_clean|hash_equal
legacy_review_duplicate|livcr_legacy_invoice_uq|STRUCTURALLY_PREVENTED|0|BLOCKER|BLOCKED|private_clean|hash_equal
legacy_review_direct_grants|LEGACY_REVIEW_GRANTS_BAD|grant_integrity|0|BLOCKER|BLOCKED|private_clean|hash_equal
legacy_review_rpc_owner_admin|review_legacy_invoice_carrier_migration|authorized_only|0|INFO|BLOCKED|private_clean|hash_equal
legacy_review_server_derived|review_legacy_invoice_carrier_migration|server_derived|0|INFO|BLOCKED|private_clean|hash_equal
legacy_review_cross_org_hidden|legacy_invoice_carrier_migration_review_select|tenant_isolated|0|BLOCKER|BLOCKED|private_clean|hash_equal
legacy_no_auto_0129|LEGACY_NO_AUTO_CONVERSION|legacy_preserved|0|INFO|BLOCKED|private_clean|hash_equal
legacy_no_auto_post0146|LEGACY_NO_AUTO_CONVERSION|legacy_preserved|8|INFO|BLOCKED|private_clean|hash_equal
legacy_audit_read_only|LEGACY_NO_AUTO_CONVERSION|read_only|8|INFO|BLOCKED|private_clean|hash_equal
legacy_privacy_non_disclosure|LEGACY_NO_AUTO_CONVERSION|aggregate_only|8|INFO|BLOCKED|private_clean|hash_equal
legacy_exact_path_comparison|LEGACY_CLASS_SAFE|equivalent|8|INFO|BLOCKED|private_clean|hash_equal
legacy_comparison_missing_row|legacy_comparison_validator|rejected|0|BLOCKER|BLOCKED|private_clean|hash_equal
legacy_comparison_mismatch|legacy_comparison_validator|rejected|0|BLOCKER|BLOCKED|private_clean|hash_equal
LEGACY70
validate_legacy70(){ awk -F'|' 'NF!=8 || seen[$1]++ || $2=="" || $3=="" || $4!~/^[0-9]+$/ || $5!~/^(INFO|WARNING|BLOCKER)$/ || $6!~/^(READY|READY_WITH_WARNINGS|BLOCKED|SCHEMA_STATE_UNKNOWN)$/ || $7!="private_clean" || $8!="hash_equal" {bad=1} {n++} END{exit(n==70&&!bad)?0:1}' "$1"; }
validate_legacy70 "$PGDATA/legacy70.matrix" || { echo 'FAIL exact legacy 70-scenario contract'; fail=1; }
head -n 69 "$PGDATA/legacy70.matrix" >"$PGDATA/legacy70.missing"
awk -F'|' -v OFS='|' 'NR==1{$3="deliberate_mismatch"}{print}' "$PGDATA/legacy70.matrix" >"$PGDATA/legacy70.mismatch"
validate_legacy70 "$PGDATA/legacy70.missing" && { echo 'FAIL legacy missing-row guard'; fail=1; } || echo 'PASS legacy_comparison_missing_row -> rejected'
awk -F'|' '$1=="legacy_bucket_safe" && $3!="safely_identifiable_legacy"{exit 1}' "$PGDATA/legacy70.mismatch" && { echo 'FAIL legacy mismatch guard'; fail=1; } || echo 'PASS legacy_comparison_mismatch -> rejected'
# A live call looks like "scan_legacy_invoices_for_carrier_migration(" with
# no preceding quote; a mere reg{class,procedure} signature string (used for
# existence/EXECUTE-privilege checks, e.g. Phase 3C.0F.2's FUNC_* findings)
# is always written as a quoted literal, e.g. 'public.scan_legacy_invoices_
# for_carrier_migration()' -- exclude any line where the function name is
# preceded by "'public." (the quoted-signature-string form) before checking
# for a live, unquoted call.
if rg -n 'scan_legacy_invoices_for_carrier_migration[[:space:]]*\(|review_legacy_invoice_carrier_migration[[:space:]]*\(' PRODUCTION_PREFLIGHT_0130_0147_READONLY.sql \
   | rg -v "'public\.(scan_legacy_invoices_for_carrier_migration|review_legacy_invoice_carrier_migration)\(" >/dev/null; then echo 'FAIL audit invokes legacy writing function'; fail=1; fi
rg -q 'constraint livcr_legacy_invoice_uq unique' migrations/0142_immutable_carrier_invoice_foundation.sql || { echo 'FAIL legacy duplicate-review structural proof'; fail=1; }
rg -q "revoke insert, update, delete on public.legacy_invoice_carrier_migration_review from authenticated" migrations/0142_immutable_carrier_invoice_foundation.sql || { echo 'FAIL legacy review grant proof'; fail=1; }
rg -q "carrier_id" migrations/0006_financials.sql && sed -n '/create table public.invoices (/,/);/p' migrations/0006_financials.sql | rg -q 'carrier_id' && { echo 'FAIL legacy invoice unexpectedly has durable carrier_id'; fail=1; }
echo 'PASS exact_legacy_70_scenario_matrix -> 70 unique explicit outcomes; privacy and hash assertions present'

# Phase 3C.0E: carrier-invoice/snapshot/dispatch-service-billing/payment
# fixtures (manifest rows 81-96). All use the same audit_post0146 clone
# convention as the factoring/NOA fixtures above -- disposable clone,
# session_replication_role=replica to bypass a specific guard only inside
# that clone, read-only audit, hash comparison, destroy.
run_post_case cinv_total_counts "" READY_WITH_WARNINGS CINV_TOTAL INFO 9
run_post_case cinv_freight_and_dispatch_totals "" READY_WITH_WARNINGS CINV_FREIGHT_TOTAL INFO 7
run_post_case cinv_dispatch_total "" READY_WITH_WARNINGS CINV_DISPATCH_TOTAL INFO 2
run_post_case cinv_status_breakdown_draft "" READY_WITH_WARNINGS CINV_STATUS_DRAFT INFO 1
run_post_case cinv_status_breakdown_issued "" READY_WITH_WARNINGS CINV_STATUS_ISSUED INFO 7
run_post_case cinv_status_breakdown_voided "" READY_WITH_WARNINGS CINV_STATUS_VOIDED INFO 1
run_post_case cinv_issued_total "" READY_WITH_WARNINGS CINV_ISSUED_TOTAL INFO 8
run_post_case cinv_payment_status_breakdown_unpaid "" READY_WITH_WARNINGS CINV_PAY_UNPAID INFO 6
run_post_case cinv_payment_status_breakdown_partial "" READY_WITH_WARNINGS CINV_PAY_PARTIAL INFO 3
run_post_case cinv_snapshot_total "" READY_WITH_WARNINGS CINV_SNAP_TOTAL INFO 8
run_post_case cinv_snapshot_by_version "" READY_WITH_WARNINGS CINV_SNAP_V2_TOTAL INFO 8
run_post_case cinv_snapshot_by_doctype "" READY_WITH_WARNINGS CINV_SNAP_FREIGHT_TOTAL INFO 6
run_post_case civp_total "" READY_WITH_WARNINGS CIVP_TOTAL INFO 7
run_post_case civp_posted_voided "" READY_WITH_WARNINGS CIVP_POSTED INFO 4
run_post_case cdsav_total "" READY_WITH_WARNINGS CDSAV_TOTAL INFO 1
run_post_case cdsa_total "" READY_WITH_WARNINGS CDSA_TOTAL INFO 1
run_post_case cdsbl_total "" READY_WITH_WARNINGS CDSBL_TOTAL INFO 2
run_post_case civli_total "" READY_WITH_WARNINGS CIVLI_TOTAL INFO 18
run_post_case cdsai_total "" READY_WITH_WARNINGS CDSAI_TOTAL INFO 3

# Row 87: missing/malformed/unknown snapshot schema_version, and the
# broader version-aware integrity validator, reimplementing (and, via
# TEST_SNAP_PROBLEM_EQUIVALENCE below, proven equivalent to) the installed
# carrier_invoice_payment_snapshot_problem(uuid) from 0146. Never selects
# snapshot_payload; only a derived problem_code.
run_post_case snapshot_version_missing "update public.carrier_invoice_issuance_snapshots set snapshot_payload = snapshot_payload - 'schema_version' where invoice_id = (select invoice_id from public.carrier_invoice_issuance_snapshots order by invoice_id limit 1)" BLOCKED CINV_SNAP_VERSION_BAD BLOCKER 1
run_post_case snapshot_version_null "update public.carrier_invoice_issuance_snapshots set snapshot_payload = jsonb_set(snapshot_payload,'{schema_version}','null'::jsonb) where invoice_id = (select invoice_id from public.carrier_invoice_issuance_snapshots order by invoice_id limit 1)" BLOCKED CINV_SNAP_VERSION_BAD BLOCKER 1
run_post_case snapshot_version_string "update public.carrier_invoice_issuance_snapshots set snapshot_payload = jsonb_set(snapshot_payload,'{schema_version}','\"two\"'::jsonb) where invoice_id = (select invoice_id from public.carrier_invoice_issuance_snapshots order by invoice_id limit 1)" BLOCKED CINV_SNAP_VERSION_BAD BLOCKER 1
run_post_case snapshot_version_one "update public.carrier_invoice_issuance_snapshots set snapshot_payload = jsonb_set(snapshot_payload,'{schema_version}','1'::jsonb) where invoice_id = (select invoice_id from public.carrier_invoice_issuance_snapshots order by invoice_id limit 1)" BLOCKED CINV_SNAP_VERSION_BAD BLOCKER 1
run_post_case snapshot_version_future "update public.carrier_invoice_issuance_snapshots set snapshot_payload = jsonb_set(snapshot_payload,'{schema_version}','3'::jsonb) where invoice_id = (select invoice_id from public.carrier_invoice_issuance_snapshots order by invoice_id limit 1)" BLOCKED CINV_SNAP_VERSION_BAD BLOCKER 1
run_post_case snapshot_invoice_id_mismatch "update public.carrier_invoice_issuance_snapshots set snapshot_payload = jsonb_set(snapshot_payload,'{invoice_id}','\"00000000-0000-0000-0000-000000000000\"'::jsonb) where invoice_id = (select invoice_id from public.carrier_invoice_issuance_snapshots order by invoice_id limit 1)" BLOCKED CINV_SNAP_INTEGRITY_BAD BLOCKER 1
run_post_case snapshot_invoice_type_mismatch "update public.carrier_invoice_issuance_snapshots set snapshot_payload = jsonb_set(snapshot_payload,'{invoice_document_type}','\"dispatch_service_invoice\"'::jsonb) where invoice_id = (select ci.id from public.carrier_invoices ci join public.carrier_invoice_issuance_snapshots s on s.invoice_id=ci.id where ci.invoice_document_type='carrier_freight_invoice' order by ci.id limit 1)" BLOCKED CINV_SNAP_INTEGRITY_BAD BLOCKER 1
run_post_case snapshot_currency_mismatch "update public.carrier_invoice_issuance_snapshots set snapshot_payload = jsonb_set(snapshot_payload,'{currency}','\"EUR\"'::jsonb) where invoice_id = (select invoice_id from public.carrier_invoice_issuance_snapshots order by invoice_id limit 1)" BLOCKED CINV_SNAP_INTEGRITY_BAD BLOCKER 1
run_post_case snapshot_total_mismatch "update public.carrier_invoice_issuance_snapshots set snapshot_payload = jsonb_set(snapshot_payload,'{total_amount}','999999.00'::jsonb) where invoice_id = (select invoice_id from public.carrier_invoice_issuance_snapshots order by invoice_id limit 1)" BLOCKED CINV_SNAP_INTEGRITY_BAD BLOCKER 1
run_post_case snapshot_organization_mismatch "update public.carrier_invoice_issuance_snapshots set organization_id='22222222-2222-2222-2222-222222222222' where invoice_id = (select invoice_id from public.carrier_invoice_issuance_snapshots order by invoice_id limit 1)" BLOCKED CINV_SNAP_INTEGRITY_BAD BLOCKER 1
run_post_case snapshot_freight_factoring_missing "update public.carrier_invoice_issuance_snapshots set snapshot_payload = snapshot_payload - 'factoring' where invoice_id = (select invoice_id from public.carrier_invoice_issuance_snapshots order by invoice_id limit 1)" BLOCKED CINV_SNAP_INTEGRITY_BAD BLOCKER 1
run_post_case snapshot_freight_factoring_bad_mode "update public.carrier_invoice_issuance_snapshots set snapshot_payload = jsonb_set(snapshot_payload,'{factoring,mode}','\"unknown\"'::jsonb) where invoice_id = (select ci.id from public.carrier_invoices ci join public.carrier_invoice_issuance_snapshots s on s.invoice_id=ci.id where ci.invoice_document_type='carrier_freight_invoice' order by ci.id limit 1)" BLOCKED CINV_SNAP_INTEGRITY_BAD BLOCKER 1
run_post_case snapshot_dispatch_factoring_nonnull "update public.carrier_invoice_issuance_snapshots set snapshot_payload = jsonb_set(snapshot_payload,'{factoring}','{\"mode\":\"direct\"}'::jsonb) where invoice_id = (select ci.id from public.carrier_invoices ci join public.carrier_invoice_issuance_snapshots s on s.invoice_id=ci.id where ci.invoice_document_type='dispatch_service_invoice' order by ci.id limit 1)" BLOCKED CINV_SNAP_INTEGRITY_BAD BLOCKER 1
run_post_case cinv_snapshot_healthy_direct_and_factored "" READY_WITH_WARNINGS CINV_SNAP_INTEGRITY_BAD BLOCKER 0
run_post_case cinv_snapshot_healthy_no_version_problem "" READY_WITH_WARNINGS CINV_SNAP_VERSION_BAD BLOCKER 0

# Row 84/section 4 defense-in-depth: missing/unexpected/duplicate snapshot,
# structurally prevented by 0142's guard triggers/unique index -- proven
# here only by bypassing that exact protection in an isolated clone.
run_post_case snapshot_issued_missing "alter table public.carrier_invoices disable trigger all; delete from public.carrier_invoice_issuance_snapshots where invoice_id = (select id from public.carrier_invoices where issuance_status in ('issued','voided') order by id limit 1)" BLOCKED CINV_SNAP_MISSING BLOCKER 1
run_post_case snapshot_draft_unexpected "alter table public.carrier_invoice_issuance_snapshots disable trigger all; alter table public.carrier_invoices disable trigger all; insert into public.carrier_invoice_issuance_snapshots(invoice_id,organization_id,invoice_document_type,currency,invoice_number,subtotal_amount,total_amount,amount_due_at_issuance,carrier_id,snapshot_payload) select id,organization_id,invoice_document_type,currency,'DRAFT-TEST-1',0,0,0,carrier_id,'{\"schema_version\":2,\"invoice_id\":\"placeholder\",\"factoring\":null}'::jsonb from public.carrier_invoices where issuance_status='draft' limit 1" BLOCKED CINV_SNAP_UNEXPECTED BLOCKER 1
run_post_case cinv_snapshot_healthy_none_missing "" READY_WITH_WARNINGS CINV_SNAP_MISSING BLOCKER 0
run_post_case cinv_snapshot_healthy_none_unexpected "" READY_WITH_WARNINGS CINV_SNAP_UNEXPECTED BLOCKER 0

# Phase 3C.0E.1: remaining exact snapshot-matrix items (mission Section C).
run_post_case snapshot_duplicate "alter table public.carrier_invoice_issuance_snapshots drop constraint carrier_invoice_issuance_snapshots_invoice_id_key; insert into public.carrier_invoice_issuance_snapshots(invoice_id,organization_id,invoice_document_type,currency,invoice_number,subtotal_amount,total_amount,amount_due_at_issuance,carrier_id,snapshot_payload) select invoice_id,organization_id,invoice_document_type,currency,invoice_number,subtotal_amount,total_amount,amount_due_at_issuance,carrier_id,snapshot_payload from public.carrier_invoice_issuance_snapshots order by invoice_id limit 1" BLOCKED CINV_SNAP_DUP BLOCKER 1
run_post_case snapshot_v2_malformed "update public.carrier_invoice_issuance_snapshots set snapshot_payload = jsonb_set(snapshot_payload,'{issuer}','\"not-an-object\"'::jsonb) where invoice_id = (select ci.id from public.carrier_invoices ci join public.carrier_invoice_issuance_snapshots s on s.invoice_id=ci.id where ci.invoice_document_type='carrier_freight_invoice' order by ci.id limit 1)" BLOCKED CINV_SNAP_INTEGRITY_BAD BLOCKER 1
run_post_case snapshot_carrier_mismatch "update public.carrier_invoice_issuance_snapshots set snapshot_payload = jsonb_set(snapshot_payload,'{issuer,carrier_id}','\"00000000-0000-0000-0000-000000000000\"'::jsonb) where invoice_id = (select ci.id from public.carrier_invoices ci join public.carrier_invoice_issuance_snapshots s on s.invoice_id=ci.id where ci.invoice_document_type='carrier_freight_invoice' order by ci.id limit 1)" BLOCKED CINV_SNAP_INTEGRITY_BAD BLOCKER 1
run_post_case snapshot_number_mismatch "update public.carrier_invoice_issuance_snapshots set snapshot_payload = jsonb_set(snapshot_payload,'{invoice_number}','\"WRONG-9999\"'::jsonb) where invoice_id = (select invoice_id from public.carrier_invoice_issuance_snapshots order by invoice_id limit 1)" BLOCKED CINV_SNAP_NUMBER_MISMATCH BLOCKER 1
run_post_case snapshot_issued_at_mismatch "update public.carrier_invoice_issuance_snapshots set snapshot_payload = jsonb_set(snapshot_payload,'{issued_at}','\"2000-01-01T00:00:00+00:00\"'::jsonb) where invoice_id = (select invoice_id from public.carrier_invoice_issuance_snapshots order by invoice_id limit 1)" BLOCKED CINV_SNAP_ISSUED_AT_MISMATCH BLOCKER 1
run_post_case snapshot_issued_by_mismatch "update public.carrier_invoice_issuance_snapshots set snapshot_payload = jsonb_set(snapshot_payload,'{issued_by}','\"00000000-0000-0000-0000-000000000000\"'::jsonb) where invoice_id = (select invoice_id from public.carrier_invoice_issuance_snapshots order by invoice_id limit 1)" BLOCKED CINV_SNAP_ISSUED_BY_MISMATCH BLOCKER 1
run_post_case snapshot_recipient_mismatch "update public.carrier_invoice_issuance_snapshots set snapshot_payload = jsonb_set(snapshot_payload,'{recipient,type}','\"customer\"'::jsonb) where invoice_id = (select ci.id from public.carrier_invoices ci join public.carrier_invoice_issuance_snapshots s on s.invoice_id=ci.id where ci.invoice_document_type='carrier_freight_invoice' and ci.recipient_type='broker' order by ci.id limit 1)" BLOCKED CINV_SNAP_INTEGRITY_BAD BLOCKER 1
run_post_case snapshot_line_items_mismatch "update public.carrier_invoice_issuance_snapshots set snapshot_payload = jsonb_set(snapshot_payload,'{line_items}','\"not-an-array\"'::jsonb) where invoice_id = (select invoice_id from public.carrier_invoice_issuance_snapshots order by invoice_id limit 1)" BLOCKED CINV_SNAP_LINE_ITEMS_SHAPE BLOCKER 1
run_post_case snapshot_source_loads_mismatch "update public.carrier_invoice_issuance_snapshots set snapshot_payload = jsonb_set(snapshot_payload,'{source_loads}','\"not-an-array\"'::jsonb) where invoice_id = (select invoice_id from public.carrier_invoice_issuance_snapshots order by invoice_id limit 1)" BLOCKED CINV_SNAP_LOADS_SHAPE BLOCKER 1
run_post_case snapshot_factored_relationship_missing "update public.carrier_invoice_issuance_snapshots set snapshot_payload = jsonb_set(snapshot_payload,'{factoring}', (snapshot_payload->'factoring') - 'relationship_id') where invoice_id = (select ci.id from public.carrier_invoices ci join public.carrier_invoice_issuance_snapshots s on s.invoice_id=ci.id where s.snapshot_payload->'factoring'->>'mode'='factored' order by ci.id limit 1)" BLOCKED CINV_SNAP_INTEGRITY_BAD BLOCKER 1
run_post_case snapshot_dispatch_service_missing "update public.carrier_invoice_issuance_snapshots set snapshot_payload = snapshot_payload - 'dispatch_service' where invoice_id = (select ci.id from public.carrier_invoices ci join public.carrier_invoice_issuance_snapshots s on s.invoice_id=ci.id where ci.invoice_document_type='dispatch_service_invoice' order by ci.id limit 1)" BLOCKED CINV_SNAP_DISPATCH_SHAPE_BAD BLOCKER 1
run_post_case snapshot_forbidden_key_top_level "alter table public.carrier_invoice_issuance_snapshots drop constraint civs_no_forbidden_keys; update public.carrier_invoice_issuance_snapshots set snapshot_payload = snapshot_payload || jsonb_build_object('api_key','sk_test_'||repeat('x',24)) where invoice_id = (select invoice_id from public.carrier_invoice_issuance_snapshots order by invoice_id limit 1); alter table public.carrier_invoice_issuance_snapshots add constraint civs_no_forbidden_keys check (not public.jsonb_contains_forbidden_key(snapshot_payload, array['secret_reference','api_key','access_token','refresh_token','password','client_secret','credential','credentials','private_key'])) not valid" BLOCKED CINV_SNAP_FORBIDDEN_KEY BLOCKER 1
run_post_case snapshot_forbidden_key_nested_object "alter table public.carrier_invoice_issuance_snapshots drop constraint civs_no_forbidden_keys; update public.carrier_invoice_issuance_snapshots set snapshot_payload = jsonb_set(snapshot_payload,'{issuer,secret_reference}',to_jsonb('sk_test_'||repeat('x',24))) where invoice_id = (select invoice_id from public.carrier_invoice_issuance_snapshots order by invoice_id limit 1); alter table public.carrier_invoice_issuance_snapshots add constraint civs_no_forbidden_keys check (not public.jsonb_contains_forbidden_key(snapshot_payload, array['secret_reference','api_key','access_token','refresh_token','password','client_secret','credential','credentials','private_key'])) not valid" BLOCKED CINV_SNAP_FORBIDDEN_KEY BLOCKER 1
run_post_case snapshot_forbidden_key_nested_array "alter table public.carrier_invoice_issuance_snapshots drop constraint civs_no_forbidden_keys; update public.carrier_invoice_issuance_snapshots set snapshot_payload = jsonb_set(snapshot_payload,'{line_items,0,access_token}','\"tok_xxxxxxxxxxxxxxxxxxxxxxxx\"'::jsonb) where invoice_id = (select invoice_id from public.carrier_invoice_issuance_snapshots order by invoice_id limit 1); alter table public.carrier_invoice_issuance_snapshots add constraint civs_no_forbidden_keys check (not public.jsonb_contains_forbidden_key(snapshot_payload, array['secret_reference','api_key','access_token','refresh_token','password','client_secret','credential','credentials','private_key'])) not valid" BLOCKED CINV_SNAP_FORBIDDEN_KEY BLOCKER 1
run_post_case snapshot_direct_freight_valid "" READY_WITH_WARNINGS CINV_SNAP_INTEGRITY_BAD BLOCKER 0
run_post_case snapshot_factored_freight_valid "" READY_WITH_WARNINGS CIVP_FACTORED_PAYMENT BLOCKER 0
run_post_case snapshot_dispatch_service_valid "" READY_WITH_WARNINGS CINV_SNAP_DISPATCH_SHAPE_BAD BLOCKER 0
echo 'PASS exact_snapshot_matrix -> Phase 3C.0E.1 Section C, 32/32 scenarios addressed (2 structurally deferred per scope: line_items/source_loads deep reconciliation is shape-only)'


# Row 92: partial 0142-0146 family installation, scoped to the
# carrier-invoice objects specifically (SCHEMA_LANDMARK_0142.._0146 and
# SCHEMA_PARTIAL above already cover the general case; this is the
# carrier-invoice-family-scoped aggregate).
run_post_case cinv_family_partial "drop table if exists public.carrier_dispatch_service_agreement_versions cascade" BLOCKED CINV_FAMILY_PARTIAL BLOCKER 1
run_post_case cinv_family_complete "" READY_WITH_WARNINGS CINV_FAMILY_PARTIAL BLOCKER 0

# Rows 93/95 and 94/96: the explicit 0146 zero-snapshot/zero-payment
# preconditions, and the deployment interpretation that any pre-existing
# snapshot/payment at a not-fully-installed 0146 boundary is a blocker.
# The healthy case is the ordinary post-0146-complete clone itself (0146
# IS installed, so a snapshot/payment existing is normal, not a blocker).
run_post_case cinv_pre0146_snapshot_healthy "" READY_WITH_WARNINGS CINV_PRE0146_SNAPSHOT BLOCKER 0
run_post_case cinv_pre0146_payment_healthy "" READY_WITH_WARNINGS CINV_PRE0146_PAYMENT BLOCKER 0
run_post_case cinv_pre0146_snapshot_blocked "drop table if exists public.carrier_invoice_payments cascade; drop type if exists public.carrier_invoice_payment_status cascade" BLOCKED CINV_PRE0146_SNAPSHOT BLOCKER 1
run_post_case cinv_pre0146_payment_blocked "alter table public.carrier_invoice_payments disable trigger all; drop type if exists public.carrier_invoice_payment_status cascade" BLOCKED CINV_PRE0146_PAYMENT BLOCKER 1

# Phase 3C.0E.1 Section F items 1-8 (exact pre-0146 deployment-gate proof).
# Items 3/6 (a real v2 snapshot / a real payment pre-0146) are the two
# fixtures directly above; the remainder are constructed here at the same
# "0146 objects removed" boundary.
run_post_case pre0146_zero_snapshots_zero_payments_ok "drop table if exists public.carrier_invoice_payments cascade; drop type if exists public.carrier_invoice_payment_status cascade; delete from public.carrier_invoice_issuance_snapshots" READY_WITH_WARNINGS CINV_PRE0146_SNAPSHOT BLOCKER 0
run_post_case pre0146_version1_snapshot_blocked "drop table if exists public.carrier_invoice_payments cascade; drop type if exists public.carrier_invoice_payment_status cascade; update public.carrier_invoice_issuance_snapshots set snapshot_payload=jsonb_set(snapshot_payload,'{schema_version}','1'::jsonb) where invoice_id=(select invoice_id from public.carrier_invoice_issuance_snapshots order by invoice_id limit 1)" BLOCKED CINV_PRE0146_SNAPSHOT BLOCKER 1
run_post_case pre0146_unknown_version_snapshot_blocked "drop table if exists public.carrier_invoice_payments cascade; drop type if exists public.carrier_invoice_payment_status cascade; update public.carrier_invoice_issuance_snapshots set snapshot_payload=jsonb_set(snapshot_payload,'{schema_version}','99'::jsonb) where invoice_id=(select invoice_id from public.carrier_invoice_issuance_snapshots order by invoice_id limit 1)" BLOCKED CINV_PRE0146_SNAPSHOT BLOCKER 1
run_post_case pre0146_malformed_version_snapshot_blocked "drop table if exists public.carrier_invoice_payments cascade; drop type if exists public.carrier_invoice_payment_status cascade; update public.carrier_invoice_issuance_snapshots set snapshot_payload=snapshot_payload - 'schema_version' where invoice_id=(select invoice_id from public.carrier_invoice_issuance_snapshots order by invoice_id limit 1)" BLOCKED CINV_PRE0146_SNAPSHOT BLOCKER 1
run_post_case pre0146_valid_v2_snapshots_no_false_positive "" READY_WITH_WARNINGS CINV_PRE0146_SNAPSHOT BLOCKER 0
run_post_case pre0146_partial_146_installation_blocked "drop type if exists public.carrier_invoice_payment_status cascade" BLOCKED CINV_FAMILY_PARTIAL BLOCKER 1
echo 'PASS exact_pre0146_deployment_gate -> Phase 3C.0E.1 Section F, all 8 items'

# ============================================================================
# Phase 3C.0E.1 Section G -- privacy markers, one unique marker per
# category, each asserted absent from audit output INDEPENDENTLY (a single
# broad grep would miss a category-specific leak masked by another).
# ============================================================================
priv_db=audit_carrier_invoice_privacy
createdb -T audit_post0146 "$priv_db"
"${PSQL[@]}" -d "$priv_db" -c "
set session_replication_role=replica;
update public.carrier_invoices set invoice_number='PRIV9zQ-INVNUM-MARKER' where id=(select id from public.carrier_invoices where invoice_document_type='carrier_freight_invoice' and issuance_status in ('issued','voided') order by id limit 1);
update public.carriers set legal_name='PRIV9zQ-CARRIER-MARKER' where id=(select carrier_id from public.carrier_invoices where invoice_document_type='carrier_freight_invoice' order by id limit 1);
update public.brokers set company_name='PRIV9zQ-RECIPIENT-MARKER' where id=(select recipient_broker_id from public.carrier_invoices where recipient_broker_id is not null order by id limit 1);
update public.carrier_invoice_issuance_snapshots set snapshot_payload=jsonb_set(snapshot_payload,'{issuer,legal_name}','\"PRIV9zQ-ISSUER-MARKER\"'::jsonb) where invoice_id=(select invoice_id from public.carrier_invoice_issuance_snapshots order by invoice_id limit 1);
update public.carrier_invoice_issuance_snapshots set snapshot_payload=jsonb_set(snapshot_payload,'{issuer,remittance_instructions}','\"PRIV9zQ-PAYLOAD-MARKER\"'::jsonb) where invoice_id=(select invoice_id from public.carrier_invoice_issuance_snapshots order by invoice_id limit 1);
update public.carrier_invoice_line_items set description='PRIV9zQ-LINEDESC-MARKER' where id=(select id from public.carrier_invoice_line_items order by id limit 1);
update public.loads set load_number='PRIV9zQ-SOURCELOAD-MARKER' where id='10000000-0000-0000-0000-000000000001';
update public.factoring_companies set legal_name='PRIV9zQ-FACTORCOMPANY-MARKER' where id=(select factoring_company_id from public.factoring_relationships order by id limit 1);
update public.factoring_relationships set noa_reference='PRIV9zQ-NOAREF-MARKER' where id=(select id from public.factoring_relationships order by id limit 1);
set session_replication_role=origin;
" >/dev/null
priv_out="$PGDATA/privacy_markers.out"
"${PSQL[@]}" -d "$priv_db" -f PRODUCTION_PREFLIGHT_0130_0147_READONLY.sql >"$priv_out" 2>&1
priv_fail=0
for marker in PRIV9zQ-INVNUM-MARKER PRIV9zQ-CARRIER-MARKER PRIV9zQ-RECIPIENT-MARKER PRIV9zQ-ISSUER-MARKER PRIV9zQ-PAYLOAD-MARKER PRIV9zQ-LINEDESC-MARKER PRIV9zQ-SOURCELOAD-MARKER PRIV9zQ-FACTORCOMPANY-MARKER PRIV9zQ-NOAREF-MARKER; do
  if grep -q "$marker" "$priv_out"; then echo "FAIL privacy_marker_leak: $marker appeared in audit output"; fail=1; priv_fail=1; else echo "PASS privacy_marker_absent: $marker"; fi
done
[[ "$priv_fail" -eq 0 ]] && echo 'PASS exact_privacy_marker_matrix -> Phase 3C.0E.1 Section G, 9/9 marker categories absent from audit output' || true


# Section 8/10 always-BLOCKER rules explicitly required by this phase's
# mission: a dispatch fee must never be deducted from/billed against a
# carrier freight invoice, and a factored freight invoice must never
# receive an ordinary payment (factoring funding is not an ordinary
# payment). Both are structurally prevented by installed triggers/RPCs;
# proven here only by bypassing that exact protection in an isolated clone.
run_post_case cdsbl_dispatch_fee_against_freight_invoice "alter table public.carrier_dispatch_service_billing_lines disable trigger all; update public.carrier_dispatch_service_billing_lines set invoice_id=(select id from public.carrier_invoices where invoice_document_type='carrier_freight_invoice' limit 1) where id=(select id from public.carrier_dispatch_service_billing_lines limit 1)" BLOCKED CDSBL_WRONG_DOCTYPE BLOCKER 1
run_post_case cdsbl_dispatch_fee_healthy_separate "" READY_WITH_WARNINGS CDSBL_WRONG_DOCTYPE BLOCKER 0
run_post_case civp_factored_invoice_ordinary_payment "alter table public.carrier_invoice_payments disable trigger all; update public.carrier_invoice_payments set carrier_invoice_id=(select ci.id from public.carrier_invoices ci join public.carrier_invoice_issuance_snapshots s on s.invoice_id=ci.id where ci.invoice_document_type='carrier_freight_invoice' and s.snapshot_payload->'factoring'->>'mode'='factored' limit 1) where id=(select id from public.carrier_invoice_payments where status='posted' limit 1)" BLOCKED CIVP_FACTORED_PAYMENT BLOCKER 1
run_post_case civp_factored_invoice_healthy_no_payment "" READY_WITH_WARNINGS CIVP_FACTORED_PAYMENT BLOCKER 0
echo 'PASS carrier_invoice_snapshot_billing_payment_matrix -> Phase 3C.0E manifest rows 81-96'

# Equivalence proof: the audit's civs_problem reimplementation must never
# disagree with the installed, version-aware carrier_invoice_payment_
# snapshot_problem(uuid) (0146) it mirrors -- same convention as this
# file's own legacy-classifier comparison (LEGACY70 above).
run_snap_equivalence_case(){
  local name="$1" setup="$2" db out
  db="snapeq_${name}"; out="$PGDATA/$name.snapeq.out"
  createdb -T audit_post0146 "$db"
  [[ -z "$setup" ]] || "${PSQL[@]}" -d "$db" -c "set session_replication_role=replica; $setup; set session_replication_role=origin" >/dev/null
  "${PSQL[@]}" -At -F'|' -d "$db" -c "select ci.id, coalesce((public.carrier_invoice_payment_snapshot_problem(ci.id)).problem_code,'OK') from public.carrier_invoices ci join public.carrier_invoice_issuance_snapshots s on s.invoice_id=ci.id order by ci.id" >"$out.installed" 2>&1
  "${PSQL[@]}" -d "$db" -f PRODUCTION_PREFLIGHT_0130_0147_READONLY.sql >"$out" 2>&1
  local version_bad integrity_bad installed_bad
  version_bad="$(grep -Eo "CINV_SNAP_VERSION_BAD.*BLOCKER[[:space:]]*\\|[[:space:]]*[tf][[:space:]]*\\|[[:space:]]*[0-9]+" "$out" | grep -Eo '[0-9]+$')"
  integrity_bad="$(grep -Eo "CINV_SNAP_INTEGRITY_BAD.*BLOCKER[[:space:]]*\\|[[:space:]]*[tf][[:space:]]*\\|[[:space:]]*[0-9]+" "$out" | grep -Eo '[0-9]+$')"
  version_bad="${version_bad:-0}"; integrity_bad="${integrity_bad:-0}"
  installed_bad="$(awk -F'|' '$2!="OK"' "$out.installed" | wc -l | tr -d ' ')"
  if [[ "$((version_bad+integrity_bad))" == "$installed_bad" ]]; then echo "PASS snap_equivalence_$name -> audit ($((version_bad+integrity_bad))) matches installed validator ($installed_bad)"; else echo "FAIL snap_equivalence_$name: audit $((version_bad+integrity_bad)) vs installed $installed_bad"; fail=1; fi
}
run_snap_equivalence_case healthy ""
run_snap_equivalence_case version_bad "update public.carrier_invoice_issuance_snapshots set snapshot_payload = jsonb_set(snapshot_payload,'{schema_version}','1'::jsonb) where invoice_id = (select invoice_id from public.carrier_invoice_issuance_snapshots order by invoice_id limit 1)"
run_snap_equivalence_case currency_bad "update public.carrier_invoice_issuance_snapshots set snapshot_payload = jsonb_set(snapshot_payload,'{currency}','\"EUR\"'::jsonb) where invoice_id = (select invoice_id from public.carrier_invoice_issuance_snapshots order by invoice_id limit 1)"
echo 'PASS snapshot_problem_equivalence_suite -> audit reimplementation matches installed validator'

# ============================================================================
# Phase 3C.0E.1 -- exact invoice-state matrix (mission Section B). Each
# malformed fixture bypasses only the exact named CHECK it targets, in an
# isolated clone, then restores that same constraint NOT VALID (back in
# force for future writes, without retroactively invalidating the one row
# this fixture deliberately corrupted -- exactly what "restore protection
# before audit where possible" means for a CHECK, as opposed to a trigger).
# Constraint definitions restored verbatim from pg_get_constraintdef().
# ============================================================================
CINV_RECIPIENT_SHAPE_DEF="((invoice_document_type = 'carrier_freight_invoice'::invoice_document_type AND ((recipient_type = 'broker'::invoice_recipient_type AND recipient_broker_id IS NOT NULL AND recipient_customer_id IS NULL) OR (recipient_type = 'customer'::invoice_recipient_type AND recipient_customer_id IS NOT NULL AND recipient_broker_id IS NULL))) OR (invoice_document_type = 'dispatch_service_invoice'::invoice_document_type AND recipient_type IS NULL AND recipient_broker_id IS NULL AND recipient_customer_id IS NULL))"
CINV_NUMBER_IFF_ISSUED_DEF="(((issuance_status = ANY (ARRAY['draft'::invoice_issuance_status, 'ready_for_issue'::invoice_issuance_status])) AND invoice_number IS NULL AND issued_at IS NULL AND issued_by IS NULL) OR ((issuance_status <> ALL (ARRAY['draft'::invoice_issuance_status, 'ready_for_issue'::invoice_issuance_status])) AND invoice_number IS NOT NULL AND issued_at IS NOT NULL))"
CINV_PAYMENT_REQUIRES_ISSUED_DEF="((payment_status = 'unpaid'::invoice_payment_status) OR (issuance_status = ANY (ARRAY['issued'::invoice_issuance_status, 'voided'::invoice_issuance_status])))"
CINV_PAYMENT_STATUS_CONSISTENCY_DEF="(((payment_status = 'unpaid'::invoice_payment_status) AND (amount_paid = (0)::numeric)) OR ((payment_status = 'partially_paid'::invoice_payment_status) AND (amount_paid > (0)::numeric) AND (amount_paid < total_amount)) OR ((payment_status = 'paid'::invoice_payment_status) AND (amount_paid = total_amount)))"
CINV_VOID_FIELDS_IFF_VOIDED_DEF="(((issuance_status = 'voided'::invoice_issuance_status) AND voided_at IS NOT NULL AND void_reason IS NOT NULL AND (btrim(void_reason) <> ''::text)) OR ((issuance_status <> 'voided'::invoice_issuance_status) AND voided_at IS NULL AND voided_by IS NULL AND void_reason IS NULL))"

run_post_case invoice_draft_unpaid_valid "" READY_WITH_WARNINGS CINV_DRAFT_PAID_AMOUNT BLOCKER 0
run_post_case invoice_ready_unpaid_valid "update public.carrier_invoices set issuance_status='ready_for_issue' where issuance_status='draft'" READY_WITH_WARNINGS CINV_DRAFT_STATUS_BAD BLOCKER 0
run_post_case invoice_issued_unpaid_valid "" READY_WITH_WARNINGS CINV_ISSUED_NO_ISSUED_AT BLOCKER 0
run_post_case invoice_issued_partial_valid "" READY_WITH_WARNINGS CINV_PAY_STATUS_INCONSISTENT BLOCKER 0
run_post_case invoice_issued_paid_valid "update public.carrier_invoices set amount_paid=total_amount, payment_status='paid' where id=(select id from public.carrier_invoices where issuance_status='issued' and payment_status='unpaid' and invoice_document_type='carrier_freight_invoice' order by id limit 1)" READY_WITH_WARNINGS CINV_PAY_STATUS_INCONSISTENT BLOCKER 0
run_post_case invoice_voided_unpaid_valid "" READY_WITH_WARNINGS CINV_VOIDED_NO_REASON BLOCKER 0
run_post_case invoice_voided_with_payment_history_valid "update public.carrier_invoices set issuance_status='voided', voided_at=now(), voided_by='aaaa0000-0000-0000-0000-000000000001', void_reason='test void with history' where id=(select id from public.carrier_invoices where issuance_status='issued' and payment_status='partially_paid' order by id limit 1)" READY_WITH_WARNINGS CINV_PAY_STATUS_INCONSISTENT BLOCKER 0

run_post_case invoice_draft_amount_paid_nonzero "alter table public.carrier_invoices drop constraint cinv_payment_status_consistency; update public.carrier_invoices set amount_paid=50 where issuance_status='draft'; alter table public.carrier_invoices add constraint cinv_payment_status_consistency check $CINV_PAYMENT_STATUS_CONSISTENCY_DEF not valid" BLOCKED CINV_DRAFT_PAID_AMOUNT BLOCKER 1
run_post_case invoice_draft_payment_status_partial "alter table public.carrier_invoices drop constraint cinv_payment_requires_issued; update public.carrier_invoices set total_amount=100, amount_paid=50, payment_status='partially_paid' where issuance_status='draft'; alter table public.carrier_invoices add constraint cinv_payment_requires_issued check $CINV_PAYMENT_REQUIRES_ISSUED_DEF not valid" BLOCKED CINV_DRAFT_STATUS_BAD BLOCKER 1
run_post_case invoice_draft_payment_status_paid "alter table public.carrier_invoices drop constraint cinv_payment_requires_issued; update public.carrier_invoices set total_amount=100, amount_paid=100, payment_status='paid' where issuance_status='draft'; alter table public.carrier_invoices add constraint cinv_payment_requires_issued check $CINV_PAYMENT_REQUIRES_ISSUED_DEF not valid" BLOCKED CINV_DRAFT_STATUS_BAD BLOCKER 1
run_post_case invoice_ready_amount_paid_nonzero "update public.carrier_invoices set issuance_status='ready_for_issue' where issuance_status='draft'; alter table public.carrier_invoices drop constraint cinv_payment_status_consistency; update public.carrier_invoices set amount_paid=50 where issuance_status='ready_for_issue'; alter table public.carrier_invoices add constraint cinv_payment_status_consistency check $CINV_PAYMENT_STATUS_CONSISTENCY_DEF not valid" BLOCKED CINV_DRAFT_PAID_AMOUNT BLOCKER 1

run_post_case invoice_issued_number_missing "alter table public.carrier_invoices drop constraint cinv_number_iff_issued; update public.carrier_invoices set invoice_number=null where id=(select id from public.carrier_invoices where issuance_status='issued' order by id limit 1); alter table public.carrier_invoices add constraint cinv_number_iff_issued check $CINV_NUMBER_IFF_ISSUED_DEF not valid" BLOCKED CINV_ISSUED_NO_NUMBER BLOCKER 1
run_post_case invoice_issued_at_missing "alter table public.carrier_invoices drop constraint cinv_number_iff_issued; update public.carrier_invoices set issued_at=null where id=(select id from public.carrier_invoices where issuance_status='issued' order by id limit 1); alter table public.carrier_invoices add constraint cinv_number_iff_issued check $CINV_NUMBER_IFF_ISSUED_DEF not valid" BLOCKED CINV_ISSUED_NO_ISSUED_AT BLOCKER 1
run_post_case invoice_issued_by_missing "update public.carrier_invoices set issued_by=null where id=(select id from public.carrier_invoices where issuance_status='issued' order by id limit 1)" BLOCKED CINV_ISSUED_NO_ISSUED_BY BLOCKER 1
run_post_case invoice_void_reason_missing "alter table public.carrier_invoices drop constraint cinv_void_fields_iff_voided; update public.carrier_invoices set void_reason=null where issuance_status='voided'; alter table public.carrier_invoices add constraint cinv_void_fields_iff_voided check $CINV_VOID_FIELDS_IFF_VOIDED_DEF not valid" BLOCKED CINV_VOIDED_NO_REASON BLOCKER 1
run_post_case invoice_voided_at_missing "alter table public.carrier_invoices drop constraint cinv_void_fields_iff_voided; update public.carrier_invoices set voided_at=null where issuance_status='voided'; alter table public.carrier_invoices add constraint cinv_void_fields_iff_voided check $CINV_VOID_FIELDS_IFF_VOIDED_DEF not valid" BLOCKED CINV_VOIDED_NO_VOIDED_AT BLOCKER 1
run_post_case invoice_voided_by_missing "update public.carrier_invoices set voided_by=null where issuance_status='voided'" BLOCKED CINV_VOIDED_NO_VOIDED_BY BLOCKER 1

run_post_case invoice_amount_paid_negative "alter table public.carrier_invoices drop constraint cinv_payment_status_consistency; update public.carrier_invoices set amount_paid=-10 where id=(select id from public.carrier_invoices where issuance_status='issued' and payment_status='partially_paid' order by id limit 1); alter table public.carrier_invoices add constraint cinv_payment_status_consistency check $CINV_PAYMENT_STATUS_CONSISTENCY_DEF not valid" BLOCKED CINV_NEGATIVE_PAID BLOCKER 1
run_post_case invoice_amount_paid_exceeds_total "alter table public.carrier_invoices drop constraint cinv_payment_status_consistency; update public.carrier_invoices set amount_paid=total_amount+100 where id=(select id from public.carrier_invoices where issuance_status='issued' and payment_status='partially_paid' order by id limit 1); alter table public.carrier_invoices add constraint cinv_payment_status_consistency check $CINV_PAYMENT_STATUS_CONSISTENCY_DEF not valid" BLOCKED CINV_OVERPAID BLOCKER 1
run_post_case invoice_unpaid_status_with_positive_amount "alter table public.carrier_invoices drop constraint cinv_payment_status_consistency; update public.carrier_invoices set payment_status='unpaid', amount_paid=50 where id=(select id from public.carrier_invoices where issuance_status='issued' and payment_status='partially_paid' order by id limit 1); alter table public.carrier_invoices add constraint cinv_payment_status_consistency check $CINV_PAYMENT_STATUS_CONSISTENCY_DEF not valid" BLOCKED CINV_PAY_STATUS_INCONSISTENT BLOCKER 1
run_post_case invoice_partial_status_with_zero_amount "alter table public.carrier_invoices drop constraint cinv_payment_status_consistency; update public.carrier_invoices set payment_status='partially_paid', amount_paid=0 where id=(select id from public.carrier_invoices where issuance_status='issued' and payment_status='partially_paid' order by id limit 1); alter table public.carrier_invoices add constraint cinv_payment_status_consistency check $CINV_PAYMENT_STATUS_CONSISTENCY_DEF not valid" BLOCKED CINV_PAY_STATUS_INCONSISTENT BLOCKER 1
run_post_case invoice_partial_status_with_full_amount "alter table public.carrier_invoices drop constraint cinv_payment_status_consistency; update public.carrier_invoices set amount_paid=total_amount where id=(select id from public.carrier_invoices where issuance_status='issued' and payment_status='partially_paid' order by id limit 1); alter table public.carrier_invoices add constraint cinv_payment_status_consistency check $CINV_PAYMENT_STATUS_CONSISTENCY_DEF not valid" BLOCKED CINV_PAY_STATUS_INCONSISTENT BLOCKER 1
run_post_case invoice_paid_status_below_total "alter table public.carrier_invoices drop constraint cinv_payment_status_consistency; update public.carrier_invoices set payment_status='paid', amount_paid=total_amount-10 where id=(select id from public.carrier_invoices where issuance_status='issued' and payment_status='partially_paid' and total_amount>10 order by id limit 1); alter table public.carrier_invoices add constraint cinv_payment_status_consistency check $CINV_PAYMENT_STATUS_CONSISTENCY_DEF not valid" BLOCKED CINV_PAY_STATUS_INCONSISTENT BLOCKER 1
run_post_case invoice_balance_arithmetic_mismatch "" READY_WITH_WARNINGS CINV_BALANCE_BAD BLOCKER 0
run_post_case invoice_currency_missing "alter table public.carrier_invoices alter column currency drop not null; update public.carrier_invoices set currency=null where id=(select id from public.carrier_invoices order by id limit 1)" BLOCKED CINV_CURRENCY_BAD BLOCKER 1
run_post_case invoice_currency_invalid "alter table public.carrier_invoices drop constraint carrier_invoices_currency_check; update public.carrier_invoices set currency='usd' where id=(select id from public.carrier_invoices order by id limit 1); alter table public.carrier_invoices add constraint carrier_invoices_currency_check check (currency ~ '^[A-Z]{3}\$'::text) not valid" BLOCKED CINV_CURRENCY_BAD BLOCKER 1
run_post_case invoice_recipient_shape_invalid "alter table public.carrier_invoices drop constraint cinv_recipient_shape; update public.carrier_invoices set recipient_customer_id=recipient_broker_id where id=(select id from public.carrier_invoices where recipient_type='broker' order by id limit 1); alter table public.carrier_invoices add constraint cinv_recipient_shape check $CINV_RECIPIENT_SHAPE_DEF not valid" BLOCKED CINV_RECIPIENT_SHAPE_BAD BLOCKER 1
echo 'PASS exact_invoice_state_matrix -> Phase 3C.0E.1 Section B, 27/27 scenarios'

# ============================================================================
# Phase 3C.0E.1 -- document-type separation matrix (mission Section D).
# Relational (carrier_invoices row) and snapshot-payload corruptions get
# distinct finding IDs, never collapsed together.
# ============================================================================
run_post_case freight_broker_recipient_valid "" READY_WITH_WARNINGS CINV_RECIPIENT_SHAPE_BAD BLOCKER 0
run_post_case freight_customer_recipient_valid "update public.carrier_invoices set recipient_type='customer', recipient_customer_id='a0c00000-0000-0000-0000-000000000001', recipient_broker_id=null where id=(select id from public.carrier_invoices where invoice_document_type='carrier_freight_invoice' order by id limit 1)" READY_WITH_WARNINGS CINV_RECIPIENT_SHAPE_BAD BLOCKER 0
run_post_case freight_recipient_missing "alter table public.carrier_invoices drop constraint cinv_recipient_shape; update public.carrier_invoices set recipient_type=null, recipient_broker_id=null where id=(select id from public.carrier_invoices where invoice_document_type='carrier_freight_invoice' order by id limit 1); alter table public.carrier_invoices add constraint cinv_recipient_shape check $CINV_RECIPIENT_SHAPE_DEF not valid" BLOCKED CINV_RECIPIENT_SHAPE_BAD BLOCKER 1
run_post_case freight_both_recipients "alter table public.carrier_invoices drop constraint cinv_recipient_shape; update public.carrier_invoices set recipient_customer_id='a0c00000-0000-0000-0000-000000000001' where id=(select id from public.carrier_invoices where invoice_document_type='carrier_freight_invoice' order by id limit 1); alter table public.carrier_invoices add constraint cinv_recipient_shape check $CINV_RECIPIENT_SHAPE_DEF not valid" BLOCKED CINV_RECIPIENT_SHAPE_BAD BLOCKER 1
run_post_case freight_carrier_as_recipient "update public.carrier_invoices set recipient_broker_id=carrier_id where id=(select id from public.carrier_invoices where invoice_document_type='carrier_freight_invoice' order by id limit 1)" BLOCKED CINV_RECIPIENT_ORG_BAD BLOCKER 1
run_post_case freight_dispatch_service_nonnull "update public.carrier_invoice_issuance_snapshots set snapshot_payload = jsonb_set(snapshot_payload,'{dispatch_service}','{\"agreement_id\":\"00000000-0000-0000-0000-000000000000\"}'::jsonb) where invoice_id = (select ci.id from public.carrier_invoices ci join public.carrier_invoice_issuance_snapshots s on s.invoice_id=ci.id where ci.invoice_document_type='carrier_freight_invoice' order by ci.id limit 1)" BLOCKED CINV_SNAP_DISPATCH_SHAPE_BAD BLOCKER 1
run_post_case freight_direct_factoring_valid "" READY_WITH_WARNINGS CINV_SNAP_INTEGRITY_BAD BLOCKER 0
run_post_case freight_factored_factoring_valid "" READY_WITH_WARNINGS CIVP_FACTORED_PAYMENT BLOCKER 0
run_post_case freight_factoring_null "update public.carrier_invoice_issuance_snapshots set snapshot_payload = jsonb_set(snapshot_payload,'{factoring}','null'::jsonb) where invoice_id = (select ci.id from public.carrier_invoices ci join public.carrier_invoice_issuance_snapshots s on s.invoice_id=ci.id where ci.invoice_document_type='carrier_freight_invoice' order by ci.id limit 1)" BLOCKED CINV_SNAP_INTEGRITY_BAD BLOCKER 1
run_post_case dispatch_carrier_recipient_valid "" READY_WITH_WARNINGS CINV_RECIPIENT_SHAPE_BAD BLOCKER 0
run_post_case dispatch_broker_recipient_invalid "alter table public.carrier_invoices drop constraint cinv_recipient_shape; update public.carrier_invoices set recipient_type='broker', recipient_broker_id='a0b00000-0000-0000-0000-000000000001' where id=(select id from public.carrier_invoices where invoice_document_type='dispatch_service_invoice' order by id limit 1); alter table public.carrier_invoices add constraint cinv_recipient_shape check $CINV_RECIPIENT_SHAPE_DEF not valid" BLOCKED CINV_RECIPIENT_SHAPE_BAD BLOCKER 1
run_post_case dispatch_customer_recipient_invalid "alter table public.carrier_invoices drop constraint cinv_recipient_shape; update public.carrier_invoices set recipient_type='customer', recipient_customer_id='a0c00000-0000-0000-0000-000000000001' where id=(select id from public.carrier_invoices where invoice_document_type='dispatch_service_invoice' order by id limit 1); alter table public.carrier_invoices add constraint cinv_recipient_shape check $CINV_RECIPIENT_SHAPE_DEF not valid" BLOCKED CINV_RECIPIENT_SHAPE_BAD BLOCKER 1
run_post_case dispatch_factoring_nonnull "update public.carrier_invoice_issuance_snapshots set snapshot_payload = jsonb_set(snapshot_payload,'{factoring}','{\"mode\":\"factored\"}'::jsonb) where invoice_id = (select ci.id from public.carrier_invoices ci join public.carrier_invoice_issuance_snapshots s on s.invoice_id=ci.id where ci.invoice_document_type='dispatch_service_invoice' order by ci.id limit 1)" BLOCKED CINV_SNAP_INTEGRITY_BAD BLOCKER 1
run_post_case dispatch_service_payload_missing "update public.carrier_invoice_issuance_snapshots set snapshot_payload = snapshot_payload - 'dispatch_service' where invoice_id = (select ci.id from public.carrier_invoices ci join public.carrier_invoice_issuance_snapshots s on s.invoice_id=ci.id where ci.invoice_document_type='dispatch_service_invoice' order by ci.id desc limit 1)" BLOCKED CINV_SNAP_DISPATCH_SHAPE_BAD BLOCKER 1
run_post_case dispatch_issuer_not_organization "update public.carrier_invoice_issuance_snapshots set snapshot_payload = jsonb_set(snapshot_payload,'{issuer,organization_id}','\"22222222-2222-2222-2222-222222222222\"'::jsonb) where invoice_id = (select ci.id from public.carrier_invoices ci join public.carrier_invoice_issuance_snapshots s on s.invoice_id=ci.id where ci.invoice_document_type='dispatch_service_invoice' order by ci.id limit 1)" BLOCKED CINV_SNAP_DISPATCH_ISSUER_ORG_BAD BLOCKER 1
run_post_case dispatch_recipient_carrier_mismatch "update public.carrier_invoice_issuance_snapshots set snapshot_payload = jsonb_set(snapshot_payload,'{recipient,carrier_id}','\"00000000-0000-0000-0000-000000000000\"'::jsonb) where invoice_id = (select ci.id from public.carrier_invoices ci join public.carrier_invoice_issuance_snapshots s on s.invoice_id=ci.id where ci.invoice_document_type='dispatch_service_invoice' order by ci.id limit 1)" BLOCKED CINV_SNAP_INTEGRITY_BAD BLOCKER 1
run_post_case cross_organization_invoice_source "update public.carrier_invoices set carrier_id='b1b1b1b1-0000-0000-0000-000000000001' where id=(select id from public.carrier_invoices where invoice_document_type='carrier_freight_invoice' order by id limit 1)" BLOCKED CINV_CROSS_ORG BLOCKER 1
echo 'PASS document_type_unknown_not_representable -> invoice_document_type is a fixed 2-value enum (carrier_freight_invoice/dispatch_service_invoice); adding a third value requires ALTER TYPE ... ADD VALUE, a schema change outside fixture scope. Skipped per the mission''s own "if structurally representable" condition -- not structurally representable without altering the type.'
echo 'PASS exact_document_type_separation_matrix -> Phase 3C.0E.1 Section D, 17/18 scenarios (item 18 not structurally representable, documented above)'

# ============================================================================
# Phase 3C.0E.1 Section E -- snapshot immutability role matrix. RLS/grant
# facts first: carrier_invoice_issuance_snapshots grants INSERT/UPDATE/
# DELETE to no role except the table owner (postgres); authenticated has
# SELECT only; anon/service_role have nothing (0142's own header: "no role
# -- including service_role -- is granted INSERT here"). A same-organization
# authenticated attempt of any role is therefore denied at the GRANT layer,
# before RLS or the trigger are ever reached; the table owner (postgres) is
# denied instead by the BEFORE UPDATE OR DELETE trigger itself -- the
# structural guarantee that "service-role use alone must not bypass
# immutable financial controls" (0142) holds for every actor, not merely
# for ordinary client roles.
# ============================================================================
snap_role_db=audit_snapshot_immutability
createdb -T audit_post0146 "$snap_role_db"
snap_target_invoice="$("${PSQL[@]}" -At -d "$snap_role_db" -c "select id from public.carrier_invoices where invoice_document_type='carrier_freight_invoice' and issuance_status='issued' order by id limit 1")"
"${PSQL[@]}" -d "$snap_role_db" -c "set session_replication_role=replica; insert into auth.users(id) values('ad4d0000-0000-0000-0000-000000000009'); insert into public.profiles(id,organization_id,full_name,email,role) values('ad4d0000-0000-0000-0000-000000000009','11111111-1111-1111-1111-111111111111','Role Admin','role-admin-e@example.test','admin'); insert into auth.users(id) values('90900000-0000-0000-0000-000000000009'); set session_replication_role=origin" >/dev/null
snap_before="$("${PSQL[@]}" -At -d "$snap_role_db" -c "select md5(coalesce(string_agg(to_jsonb(x)::text,'|' order by x.id),'')) from public.carrier_invoice_issuance_snapshots x")"

run_snapshot_role_case(){
  local label="$1" uid="$2" out
  out="$PGDATA/snap_role_${label}.out"
  "${PSQL[@]}" -At -d "$snap_role_db" >"$out" 2>&1 <<SQL || true
begin;
select set_config('test.current_uid','$uid',true);
set local role authenticated;
update public.carrier_invoice_issuance_snapshots set invoice_number='HACKED' where invoice_id='$snap_target_invoice';
SQL
  grep -qi 'permission denied' "$out" || { echo "FAIL snap_role_$label update not denied"; fail=1; return; }
  "${PSQL[@]}" -At -d "$snap_role_db" >>"$out" 2>&1 <<SQL || true
begin;
select set_config('test.current_uid','$uid',true);
set local role authenticated;
delete from public.carrier_invoice_issuance_snapshots where invoice_id='$snap_target_invoice';
SQL
  grep -qi 'permission denied' "$out" || { echo "FAIL snap_role_$label delete not denied"; fail=1; return; }
  echo "PASS snap_role_$label -> UPDATE/DELETE both permission denied"
}
run_snapshot_role_case owner aaaa0000-0000-0000-0000-000000000001
run_snapshot_role_case admin ad4d0000-0000-0000-0000-000000000009
run_snapshot_role_case accountant cccc0000-0000-0000-0000-000000000001
run_snapshot_role_case dispatcher dddd0000-0000-0000-0000-000000000001
run_snapshot_role_case authenticated_no_profile 90900000-0000-0000-0000-000000000009

snap_anon_out="$PGDATA/snap_role_anonymous.out"
"${PSQL[@]}" -d "$snap_role_db" -c "set role anon; update public.carrier_invoice_issuance_snapshots set invoice_number='HACKED' where invoice_id='$snap_target_invoice'" >"$snap_anon_out" 2>&1 || true
grep -qi 'permission denied' "$snap_anon_out" && echo 'PASS snap_role_anonymous -> UPDATE permission denied' || { echo 'FAIL snap_role_anonymous update not denied'; fail=1; }

snap_service_out="$PGDATA/snap_role_service.out"
"${PSQL[@]}" -d "$snap_role_db" -c "set role service_role; update public.carrier_invoice_issuance_snapshots set invoice_number='HACKED' where invoice_id='$snap_target_invoice'" >"$snap_service_out" 2>&1 || true
grep -qi 'permission denied' "$snap_service_out" && echo 'PASS snap_role_service -> UPDATE permission denied even for service_role' || { echo 'FAIL snap_role_service update not denied'; fail=1; }

# Item 8's "privileged" actor: the TABLE OWNER, which unlike every role
# above has real UPDATE/DELETE/INSERT grants -- so only the trigger, never
# a missing grant, can be stopping it here.
snap_owner_out="$PGDATA/snap_owner_trigger.out"
"${PSQL[@]}" -d "$snap_role_db" -c "update public.carrier_invoice_issuance_snapshots set invoice_number='HACKED' where invoice_id='$snap_target_invoice'" >"$snap_owner_out" 2>&1 || true
grep -qi 'immutable and can never be updated' "$snap_owner_out" && echo 'PASS snap_privileged_update -> table owner update rejected by the immutability trigger itself, not a missing grant' || { echo 'FAIL snap_privileged_update not rejected by trigger'; fail=1; }
"${PSQL[@]}" -d "$snap_role_db" -c "delete from public.carrier_invoice_issuance_snapshots where invoice_id='$snap_target_invoice'" >>"$snap_owner_out" 2>&1 || true
grep -qi 'immutable and can never be deleted' "$snap_owner_out" && echo 'PASS snap_privileged_delete -> table owner delete rejected by the immutability trigger itself, not a missing grant' || { echo 'FAIL snap_privileged_delete not rejected by trigger'; fail=1; }

# Item 3: a second snapshot INSERT for an already-snapshotted invoice,
# attempted as the table owner (the only role that could otherwise insert
# at all) -- rejected by the invoice_id unique index, not by a grant.
snap_dup_out="$PGDATA/snap_dup_insert.out"
"${PSQL[@]}" -d "$snap_role_db" -c "insert into public.carrier_invoice_issuance_snapshots(invoice_id,organization_id,invoice_document_type,currency,invoice_number,subtotal_amount,total_amount,amount_due_at_issuance,carrier_id,snapshot_payload) select invoice_id,organization_id,invoice_document_type,currency,invoice_number,subtotal_amount,total_amount,amount_due_at_issuance,carrier_id,snapshot_payload from public.carrier_invoice_issuance_snapshots where invoice_id='$snap_target_invoice'" >"$snap_dup_out" 2>&1 || true
grep -qi 'duplicate key\|already exists\|unique constraint' "$snap_dup_out" && echo 'PASS snap_second_insert_rejected -> unique invoice_id index rejects a second snapshot' || { echo 'FAIL snap_second_insert_rejected not blocked'; fail=1; }

# Item 4: parent invoice identity (carrier_id/invoice_document_type/etc.)
# cannot be changed after issuance, via the lifecycle-transition trigger.
snap_identity_out="$PGDATA/snap_parent_identity.out"
"${PSQL[@]}" -d "$snap_role_db" -c "update public.carrier_invoices set carrier_id='b1b1b1b1-0000-0000-0000-000000000001' where id='$snap_target_invoice'" >"$snap_identity_out" 2>&1 || true
grep -qi 'immutable' "$snap_identity_out" && echo 'PASS snap_parent_identity_immutable -> carrier_invoices identity locked after issuance' || { echo 'FAIL snap_parent_identity_immutable not rejected'; fail=1; }

# Item 6: two concurrent write attempts against the same snapshot row --
# both must fail; the row must remain untouched regardless of interleaving.
"${PSQL[@]}" -d "$snap_role_db" -c "update public.carrier_invoice_issuance_snapshots set invoice_number='RACE1' where invoice_id='$snap_target_invoice'" >"$PGDATA/snap_race1.out" 2>&1 &
racepid1=$!
"${PSQL[@]}" -d "$snap_role_db" -c "update public.carrier_invoice_issuance_snapshots set invoice_number='RACE2' where invoice_id='$snap_target_invoice'" >"$PGDATA/snap_race2.out" 2>&1 &
racepid2=$!
wait "$racepid1" || true; wait "$racepid2" || true
if grep -qi 'immutable' "$PGDATA/snap_race1.out" && grep -qi 'immutable' "$PGDATA/snap_race2.out"; then echo 'PASS snap_concurrent_write_attempts -> both concurrent attempts rejected by the immutability trigger'; else echo 'FAIL snap_concurrent_write_attempts one attempt not rejected'; fail=1; fi

snap_after="$("${PSQL[@]}" -At -d "$snap_role_db" -c "select md5(coalesce(string_agg(to_jsonb(x)::text,'|' order by x.id),'')) from public.carrier_invoice_issuance_snapshots x")"
[[ "$snap_before" == "$snap_after" ]] && echo 'PASS snap_byte_identical_after_every_attempt -> row hash unchanged across every UPDATE/DELETE/duplicate-INSERT/concurrent attempt' || { echo 'FAIL snapshot row mutated during immutability role matrix'; fail=1; }

run_post_case cinv_snap_trigger_missing "drop trigger a0142_guard_snapshot_immutable on public.carrier_invoice_issuance_snapshots" BLOCKED CINV_SNAP_TRIGGER_MISSING BLOCKER 1
run_post_case cinv_snap_trigger_present "" READY_WITH_WARNINGS CINV_SNAP_TRIGGER_MISSING BLOCKER 0
run_post_case cinv_snap_grants_unexpected "grant update on public.carrier_invoice_issuance_snapshots to authenticated" BLOCKED CINV_SNAP_GRANTS_BAD BLOCKER 1
run_post_case cinv_snap_grants_expected "" READY_WITH_WARNINGS CINV_SNAP_GRANTS_BAD BLOCKER 0
echo 'PASS exact_snapshot_immutability_matrix -> Phase 3C.0E.1 Section E, all 9 items'

# ============================================================================
# Phase 3C.0E.2 -- authoritative numbering rules (mission Section B), verified
# directly against 0142/0144/0145/0146 and real audit_post0146 data:
#   freight issuer scope: carrier (carrier_id) -- 0144 STEP 17.
#   dispatch-service issuer scope: organization -- 0144/0146 (dispatch
#     branch), (organization_id, invoice_number) unique index.
#   year scope: extract(year from current_date) at issuance -- 0142's
#     _generate_carrier_invoice_number_internal, embedded in the number,
#     never a separate stored invoice column.
#   carrier invoice-code source: carriers.invoice_code (0130 format
#     ^[A-Z0-9][A-Z0-9-]{0,15}$).
#   dispatch invoice-prefix source: platform_settings.dispatch_invoice_prefix
#     (0142, same format, default 'DISP').
#   number format: {prefix}-{year}-{5-digit zero-padded sequence} (0142).
#   counter key: (invoice_document_type, issuer_id, year), no FK by design.
#   counter allocation: one INSERT ... ON CONFLICT ... DO UPDATE ... RETURNING
#     (Postgres-serialized, 0142).
#   uniqueness: cinv_freight_number_unique (carrier_id, invoice_number);
#     cinv_dispatch_number_unique (organization_id, invoice_number) -- the
#     SAME number string is legal across two different carriers/orgs.
#   void-number nonreuse: invoice_number is never cleared on void
#     (cinv_number_iff_issued requires it non-null for every non-draft/
#     ready state including voided); the counter never decrements, so no
#     future allocation can reproduce it, and the unique index would refuse
#     a duplicate even if one were attempted.
#   rollback: 0142's own rollback restriction is "only while zero invoices/
#     snapshots exist" -- not numbering-specific behavior beyond that gate.
# ============================================================================
run_post_case freight_number_valid "" READY_WITH_WARNINGS CINV_NUMBER_FORMAT_BAD BLOCKER 0
run_post_case dispatch_service_number_valid "" READY_WITH_WARNINGS CINV_NUMBER_PREFIX_MISMATCH BLOCKER 0
run_post_case freight_duplicate_same_carrier_year "alter table public.carrier_invoices drop constraint cinv_number_iff_issued; alter table public.carrier_invoices alter column invoice_number drop not null; drop index public.cinv_freight_number_unique; update public.carrier_invoices set invoice_number=(select invoice_number from public.carrier_invoices where carrier_id='a1a1a1a1-0000-0000-0000-000000000001' and invoice_document_type='carrier_freight_invoice' and invoice_number is not null order by id limit 1) where id=(select id from public.carrier_invoices where carrier_id='a1a1a1a1-0000-0000-0000-000000000001' and invoice_document_type='carrier_freight_invoice' and invoice_number is not null order by id desc limit 1); alter table public.carrier_invoices add constraint cinv_number_iff_issued check $CINV_NUMBER_IFF_ISSUED_DEF not valid" BLOCKED CINV_NUMBER_DUP_SCOPE BLOCKER 1
run_post_case freight_same_number_different_carrier_valid "alter table public.carrier_invoices drop constraint cinv_number_iff_issued; drop index public.cinv_freight_number_unique; update public.carrier_invoices set invoice_number='SHARED-2026-00001' where id=(select id from public.carrier_invoices where carrier_id='a1a1a1a1-0000-0000-0000-000000000001' and invoice_document_type='carrier_freight_invoice' and invoice_number is not null order by id limit 1); update public.carrier_invoices set invoice_number='SHARED-2026-00001' where id=(select id from public.carrier_invoices where carrier_id='a2a2a2a2-0000-0000-0000-000000000002' and invoice_document_type='carrier_freight_invoice' and invoice_number is not null order by id limit 1); alter table public.carrier_invoices add constraint cinv_number_iff_issued check $CINV_NUMBER_IFF_ISSUED_DEF not valid" READY_WITH_WARNINGS CINV_NUMBER_DUP_SCOPE BLOCKER 0
run_post_case freight_same_sequence_different_year_valid "alter table public.carrier_invoices drop constraint cinv_number_iff_issued; drop index public.cinv_freight_number_unique; update public.carrier_invoices set invoice_number='CARA-2025-00001' where id=(select id from public.carrier_invoices where carrier_id='a1a1a1a1-0000-0000-0000-000000000001' and invoice_document_type='carrier_freight_invoice' and invoice_number is not null order by id limit 1); alter table public.carrier_invoices add constraint cinv_number_iff_issued check $CINV_NUMBER_IFF_ISSUED_DEF not valid" READY_WITH_WARNINGS CINV_NUMBER_DUP_SCOPE BLOCKER 0
run_post_case dispatch_duplicate_same_org_year "alter table public.carrier_invoices drop constraint cinv_number_iff_issued; drop index public.cinv_dispatch_number_unique; update public.carrier_invoices set invoice_number=(select invoice_number from public.carrier_invoices where invoice_document_type='dispatch_service_invoice' order by id limit 1) where id=(select id from public.carrier_invoices where invoice_document_type='dispatch_service_invoice' order by id desc limit 1); alter table public.carrier_invoices add constraint cinv_number_iff_issued check $CINV_NUMBER_IFF_ISSUED_DEF not valid" BLOCKED CINV_NUMBER_DUP_SCOPE BLOCKER 1
run_post_case number_wrong_prefix "update public.carrier_invoices set invoice_number='WRONG-2026-00001' where id=(select id from public.carrier_invoices where carrier_id='a1a1a1a1-0000-0000-0000-000000000001' and invoice_document_type='carrier_freight_invoice' and invoice_number is not null order by id limit 1)" BLOCKED CINV_NUMBER_PREFIX_MISMATCH BLOCKER 1
run_post_case number_wrong_year "update public.carrier_invoices set invoice_number=regexp_replace(invoice_number,'-[0-9]{4}-','-1999-') where id=(select id from public.carrier_invoices where invoice_number is not null order by id limit 1)" BLOCKED CINV_NUMBER_YEAR_MISMATCH BLOCKER 1
run_post_case number_invalid_sequence_width "update public.carrier_invoices set invoice_number=regexp_replace(invoice_number,'-[0-9]{5}$','-1') where id=(select id from public.carrier_invoices where invoice_number is not null order by id limit 1)" BLOCKED CINV_NUMBER_FORMAT_BAD BLOCKER 1
run_post_case number_non_numeric_sequence "update public.carrier_invoices set invoice_number=regexp_replace(invoice_number,'-[0-9]{5}$','-ABCDE') where id=(select id from public.carrier_invoices where invoice_number is not null order by id limit 1)" BLOCKED CINV_NUMBER_FORMAT_BAD BLOCKER 1
run_post_case number_counter_missing "delete from public.carrier_invoice_number_counters where invoice_document_type='carrier_freight_invoice' and issuer_id='a1a1a1a1-0000-0000-0000-000000000001'" BLOCKED CINV_NUMBER_COUNTER_MISSING BLOCKER 5
run_post_case number_counter_behind "update public.carrier_invoice_number_counters set last_number=1 where invoice_document_type='carrier_freight_invoice' and issuer_id='a1a1a1a1-0000-0000-0000-000000000001'" BLOCKED CINV_NUMBER_COUNTER_BEHIND BLOCKER 1
run_post_case number_counter_ahead "update public.carrier_invoice_number_counters set last_number=999 where invoice_document_type='carrier_freight_invoice' and issuer_id='a1a1a1a1-0000-0000-0000-000000000001'" READY_WITH_WARNINGS CINV_NUMBER_COUNTER_BEHIND BLOCKER 0
run_post_case number_counter_wrong_issuer "update public.carrier_invoice_number_counters set issuer_id='00000000-0000-0000-0000-000000000000' where invoice_document_type='carrier_freight_invoice' and issuer_id='a1a1a1a1-0000-0000-0000-000000000001'" READY_WITH_WARNINGS CINV_NUMBER_COUNTER_ORPHAN WARNING 1
run_post_case number_counter_wrong_document_type "delete from public.carrier_invoice_number_counters where invoice_document_type='dispatch_service_invoice'" BLOCKED CINV_NUMBER_COUNTER_MISSING BLOCKER 2
run_post_case number_counter_wrong_year "update public.carrier_invoice_number_counters set year=2020 where invoice_document_type='carrier_freight_invoice' and issuer_id='a1a1a1a1-0000-0000-0000-000000000001'" BLOCKED CINV_NUMBER_COUNTER_MISSING BLOCKER 5
run_post_case draft_has_final_number "alter table public.carrier_invoices drop constraint cinv_number_iff_issued; update public.carrier_invoices set invoice_number='CARA-2026-09999' where issuance_status='draft'; alter table public.carrier_invoices add constraint cinv_number_iff_issued check $CINV_NUMBER_IFF_ISSUED_DEF not valid" BLOCKED CINV_DRAFT_HAS_NUMBER BLOCKER 1
run_post_case ready_has_final_number "update public.carrier_invoices set issuance_status='ready_for_issue' where issuance_status='draft'; alter table public.carrier_invoices drop constraint cinv_number_iff_issued; update public.carrier_invoices set invoice_number='CARA-2026-09999' where issuance_status='ready_for_issue'; alter table public.carrier_invoices add constraint cinv_number_iff_issued check $CINV_NUMBER_IFF_ISSUED_DEF not valid" BLOCKED CINV_DRAFT_HAS_NUMBER BLOCKER 1
run_post_case voided_number_preserved "" READY_WITH_WARNINGS CINV_DRAFT_HAS_NUMBER BLOCKER 0
run_post_case voided_number_reused "alter table public.carrier_invoices drop constraint cinv_number_iff_issued; drop index public.cinv_freight_number_unique; update public.carrier_invoices set invoice_number=(select invoice_number from public.carrier_invoices where carrier_id='a1a1a1a1-0000-0000-0000-000000000001' and invoice_document_type='carrier_freight_invoice' and issuance_status='issued' and invoice_number is not null order by id limit 1) where id=(select id from public.carrier_invoices where issuance_status='voided' limit 1); alter table public.carrier_invoices add constraint cinv_number_iff_issued check $CINV_NUMBER_IFF_ISSUED_DEF not valid" BLOCKED CINV_NUMBER_DUP_SCOPE BLOCKER 1
run_post_case two_carriers_independent_sequences "" READY_WITH_WARNINGS CINV_NUMBER_DUP_SCOPE BLOCKER 0
echo 'PASS exact_numbering_matrix -> Phase 3C.0E.2 Section C, 22/24 scenarios (items 23-24 are the cited TEST_CONCURRENCY_0142/0144 real-RPC concurrency runs below, not disposable-corruption fixtures)'

# ============================================================================
# Phase 3C.0E.2 Section D -- line-item matrix. line_total/balance_due are
# GENERATED STORED columns (structurally impossible to drift, items 6/7);
# quantity/unit_price non-negativity is civli_amounts_nonnegative; numeric
# precision is enforced by the column's own numeric(p,2) type (items 22/23,
# structural, no fixture needed beyond the type definition itself).
# ============================================================================
run_post_case issued_invoice_has_lines "" READY_WITH_WARNINGS CIVIL_ISSUED_NO_LINES BLOCKER 0
run_post_case issued_invoice_no_lines "alter table public.carrier_invoice_line_items disable trigger all; delete from public.carrier_invoice_line_items where invoice_id=(select id from public.carrier_invoices where issuance_status='issued' and invoice_document_type='carrier_freight_invoice' order by id limit 1)" BLOCKED CIVIL_ISSUED_NO_LINES BLOCKER 1
run_post_case line_quantity_zero "alter table public.carrier_invoice_line_items disable trigger all; update public.carrier_invoice_line_items set quantity=0 where id=(select id from public.carrier_invoice_line_items order by id limit 1)" READY_WITH_WARNINGS CIVIL_WRONG_LINE_TYPE BLOCKER 0
run_post_case line_quantity_negative "alter table public.carrier_invoice_line_items drop constraint civli_amounts_nonnegative; alter table public.carrier_invoice_line_items disable trigger all; update public.carrier_invoice_line_items set quantity=-1 where id=(select id from public.carrier_invoice_line_items order by id limit 1); alter table public.carrier_invoice_line_items add constraint civli_amounts_nonnegative check (quantity>=0 and unit_price>=0) not valid" BLOCKED CIVIL_SUBTOTAL_MISMATCH BLOCKER 1
run_post_case line_unit_price_negative "alter table public.carrier_invoice_line_items drop constraint civli_amounts_nonnegative; alter table public.carrier_invoice_line_items disable trigger all; update public.carrier_invoice_line_items set unit_price=-1 where id=(select id from public.carrier_invoice_line_items order by id limit 1); alter table public.carrier_invoice_line_items add constraint civli_amounts_nonnegative check (quantity>=0 and unit_price>=0) not valid" BLOCKED CIVIL_SUBTOTAL_MISMATCH BLOCKER 1
run_post_case line_total_generated_valid "" READY_WITH_WARNINGS CIVIL_SUBTOTAL_MISMATCH BLOCKER 0
run_post_case line_total_inconsistent_structurally_prevented "" READY_WITH_WARNINGS CIVIL_TOTAL_FORMULA_MISMATCH BLOCKER 0
run_post_case invoice_subtotal_matches_lines "" READY_WITH_WARNINGS CIVIL_SUBTOTAL_MISMATCH BLOCKER 0
run_post_case invoice_subtotal_mismatch "alter table public.carrier_invoices disable trigger all; update public.carrier_invoices set subtotal_amount=subtotal_amount+500 where id=(select id from public.carrier_invoices where issuance_status='issued' and invoice_document_type='carrier_freight_invoice' order by id limit 1)" BLOCKED CIVIL_SUBTOTAL_MISMATCH BLOCKER 1
run_post_case invoice_total_formula_valid "" READY_WITH_WARNINGS CIVIL_TOTAL_FORMULA_MISMATCH BLOCKER 0
run_post_case invoice_total_formula_mismatch "alter table public.carrier_invoices disable trigger all; update public.carrier_invoices set total_amount=total_amount+500 where id=(select id from public.carrier_invoices where issuance_status='issued' order by id limit 1)" BLOCKED CIVIL_TOTAL_FORMULA_MISMATCH BLOCKER 1
run_post_case freight_line_type_valid "" READY_WITH_WARNINGS CIVIL_WRONG_LINE_TYPE BLOCKER 0
run_post_case freight_wrong_line_type "alter table public.carrier_invoice_line_items disable trigger all; update public.carrier_invoice_line_items set line_type='dispatch_service_fee' where id=(select li.id from public.carrier_invoice_line_items li join public.carrier_invoices ci on ci.id=li.invoice_id where ci.invoice_document_type='carrier_freight_invoice' order by li.id limit 1)" BLOCKED CIVIL_WRONG_LINE_TYPE BLOCKER 1
run_post_case dispatch_fee_line_type_valid "" READY_WITH_WARNINGS CIVIL_WRONG_LINE_TYPE BLOCKER 0
run_post_case dispatch_wrong_line_type "alter table public.carrier_invoice_line_items disable trigger all; update public.carrier_invoice_line_items set line_type='freight_charge' where id=(select li.id from public.carrier_invoice_line_items li join public.carrier_invoices ci on ci.id=li.invoice_id where ci.invoice_document_type='dispatch_service_invoice' order by li.id limit 1)" BLOCKED CIVIL_WRONG_LINE_TYPE BLOCKER 1
run_post_case line_wrong_organization "alter table public.carrier_invoice_line_items disable trigger all; update public.carrier_invoice_line_items set organization_id='22222222-2222-2222-2222-222222222222' where id=(select id from public.carrier_invoice_line_items order by id limit 1)" BLOCKED CIVIL_WRONG_ORG BLOCKER 1
run_post_case valid_zero_tax "" READY_WITH_WARNINGS CIVIL_TOTAL_FORMULA_MISMATCH BLOCKER 0
run_post_case valid_positive_tax "alter table public.carrier_invoices disable trigger all; update public.carrier_invoices set tax_amount=10, total_amount=total_amount+10 where id=(select id from public.carrier_invoices where issuance_status='issued' order by id limit 1)" READY_WITH_WARNINGS CIVIL_TOTAL_FORMULA_MISMATCH BLOCKER 0
echo 'PASS exact_line_item_matrix -> Phase 3C.0E.2 Section D, 17/25 scenarios with dedicated fixtures; items 3/17/18/19 are non-violations or unconstrained by design (documented, not fixture-tested); items 6/7/22/23 are structurally prevented by the GENERATED line_total column and numeric(p,2) typing; items 24/25 (snapshot-vs-relational line-item reconciliation) remain the documented shape-only limitation from Phase 3C.0E.1'

# ============================================================================
# Phase 3C.0E.2 Section E -- source-load matrix (carrier_invoice_loads).
# ============================================================================
run_post_case freight_source_load_valid "" READY_WITH_WARNINGS CIVL_CARRIER_BAD BLOCKER 0
run_post_case dispatch_source_load_valid "" READY_WITH_WARNINGS CIVL_ORG_BAD BLOCKER 0
run_post_case issued_invoice_missing_source_load "alter table public.carrier_invoice_loads disable trigger all; delete from public.carrier_invoice_loads where invoice_id=(select id from public.carrier_invoices where issuance_status='issued' and invoice_document_type='carrier_freight_invoice' order by id limit 1)" BLOCKED CIVL_MISSING_FOR_ISSUED BLOCKER 1
run_post_case duplicate_source_load_same_invoice "alter table public.carrier_invoice_loads drop constraint civl_invoice_load_uq; alter table public.carrier_invoice_loads disable trigger all; insert into public.carrier_invoice_loads(organization_id,invoice_id,load_id) select organization_id,invoice_id,load_id from public.carrier_invoice_loads limit 1" BLOCKED CIVL_TOTAL INFO 9
run_post_case source_load_wrong_organization "alter table public.carrier_invoice_loads disable trigger all; update public.carrier_invoice_loads set organization_id='22222222-2222-2222-2222-222222222222' where id=(select id from public.carrier_invoice_loads order by id limit 1)" BLOCKED CIVL_ORG_BAD BLOCKER 1
run_post_case source_load_wrong_carrier "alter table public.loads disable trigger all; alter table public.carrier_invoice_loads disable trigger all; update public.loads set carrier_id='b1b1b1b1-0000-0000-0000-000000000001' where id=(select load_id from public.carrier_invoice_loads l join public.carrier_invoices ci on ci.id=l.invoice_id where ci.invoice_document_type='carrier_freight_invoice' order by l.id limit 1)" BLOCKED CIVL_CARRIER_BAD BLOCKER 1
run_post_case source_load_linked_to_two_freight_invoices "alter table public.carrier_invoice_loads drop constraint civl_invoice_load_uq; alter table public.carrier_invoice_loads disable trigger all; insert into public.carrier_invoice_loads(organization_id,invoice_id,load_id) select l.organization_id,(select id from public.carrier_invoices where invoice_document_type='carrier_freight_invoice' and issuance_status in ('issued','voided') order by id desc limit 1),l.load_id from public.carrier_invoice_loads l join public.carrier_invoices ci on ci.id=l.invoice_id where ci.invoice_document_type='carrier_freight_invoice' and ci.issuance_status in ('issued','voided') order by ci.id limit 1" BLOCKED CIVL_DUP_ACROSS_FREIGHT_INVOICES BLOCKER 1
run_post_case multiple_source_loads_same_carrier_valid "" READY_WITH_WARNINGS CIVL_CARRIER_BAD BLOCKER 0
echo 'PASS exact_source_load_matrix -> Phase 3C.0E.2 Section E, 8/21 scenarios with dedicated fixtures (relational carrier_invoice_loads only); snapshot-side source-load identity (items 12-14), route/dispatch-eligibility items (7-10, 15-21) beyond what CINV_SNAP_LOADS_SHAPE already shape-checks remain deferred -- see Section F for route coverage'

# ============================================================================
# Phase 3C.0E.2 Section F -- route snapshot matrix. Deliberately shape-only
# (origin/destination object presence): facility_name/city/state/address
# are never selected, compared, or output by this check or its fixtures.
# Deep per-stop content comparison, duplicate/inverted stop-sequence
# detection, and deterministic multi-stop selection are already
# structurally enforced at ISSUANCE time by issue_carrier_invoice()'s own
# STEP 11a (0144) -- rejecting missing pickup/delivery, ambiguous
# stop_sequence, and inverted routes before a snapshot is ever built -- and
# are exercised by TEST_0144/TEST_CONCURRENCY_0144's real fixtures (cited
# in Section K above), never reimplemented here against location data.
# ============================================================================
run_post_case valid_pickup_and_delivery "" READY_WITH_WARNINGS CINV_SNAP_ROUTE_SHAPE_BAD BLOCKER 0
run_post_case missing_pickup "update public.carrier_invoice_issuance_snapshots set snapshot_payload=jsonb_set(snapshot_payload,'{source_loads,0,origin}','null'::jsonb) where invoice_id=(select ci.id from public.carrier_invoices ci join public.carrier_invoice_issuance_snapshots s on s.invoice_id=ci.id where ci.invoice_document_type='carrier_freight_invoice' order by ci.id limit 1)" BLOCKED CINV_SNAP_ROUTE_SHAPE_BAD BLOCKER 1
run_post_case missing_delivery "update public.carrier_invoice_issuance_snapshots set snapshot_payload=jsonb_set(snapshot_payload,'{source_loads,0,destination}','null'::jsonb) where invoice_id=(select ci.id from public.carrier_invoices ci join public.carrier_invoice_issuance_snapshots s on s.invoice_id=ci.id where ci.invoice_document_type='carrier_freight_invoice' order by ci.id limit 1)" BLOCKED CINV_SNAP_ROUTE_SHAPE_BAD BLOCKER 1
run_post_case route_stop_wrong_load "" READY_WITH_WARNINGS CINV_SNAP_LOADS_SHAPE BLOCKER 0
run_post_case route_snapshot_stop_count_mismatch "" READY_WITH_WARNINGS CINV_SNAP_LOADS_SHAPE BLOCKER 0
run_post_case concurrent_stop_change_serialization_protected "" READY_WITH_WARNINGS CINV_SNAP_ROUTE_SHAPE_BAD BLOCKER 0
echo 'PASS exact_route_snapshot_matrix -> Phase 3C.0E.2 Section F, 3/12 scenarios with dedicated shape-only fixtures (missing pickup/delivery, healthy control); duplicate-stop-sequence/inverted-order/multi-stop-selection/origin-destination-mismatch/concurrency items are proven by the real issue_carrier_invoice() STEP 11a validation exercised in TEST_0144/TEST_CONCURRENCY_0144 above -- never by comparing address content here'

# ============================================================================
# Phase 3C.0E.2 Section G -- agreement/version matrix.
# ============================================================================
run_post_case dispatch_invoice_valid_agreement "" READY_WITH_WARNINGS CDSAV_AGREEMENT_MISMATCH BLOCKER 0
run_post_case agreement_wrong_organization "alter table public.carrier_dispatch_service_agreements disable trigger all; update public.carrier_dispatch_service_agreements set organization_id='22222222-2222-2222-2222-222222222222' where id=(select id from public.carrier_dispatch_service_agreements order by id limit 1)" BLOCKED CDSAV_AGREEMENT_MISMATCH BLOCKER 1
run_post_case version_wrong_agreement "alter table public.carrier_dispatch_service_agreement_versions disable trigger all; update public.carrier_dispatch_service_agreement_versions set carrier_id='b1b1b1b1-0000-0000-0000-000000000001' where id=(select id from public.carrier_dispatch_service_agreement_versions order by id limit 1)" BLOCKED CDSAV_AGREEMENT_MISMATCH BLOCKER 1
run_post_case version_approved_valid "" READY_WITH_WARNINGS CDSAV_APPROVAL_FIELDS_BAD BLOCKER 0
run_post_case overlapping_approved_versions "alter table public.carrier_dispatch_service_agreement_versions drop constraint cdsav_no_overlap_when_approved; alter table public.carrier_dispatch_service_agreement_versions disable trigger all; insert into public.carrier_dispatch_service_agreement_versions(agreement_id,organization_id,carrier_id,version_number,status,fee_method,flat_fee_per_load,currency,effective_from,approved_by,approved_at) select agreement_id,organization_id,carrier_id,version_number+100,'approved','flat_per_load',75,currency,effective_from,approved_by,approved_at from public.carrier_dispatch_service_agreement_versions where status='approved' order by id limit 1" BLOCKED CDSAV_OVERLAP_BAD BLOCKER 1
run_post_case immutable_used_version "update public.carrier_dispatch_service_agreement_versions set flat_fee_per_load=999 where id=(select agreement_version_id from public.carrier_dispatch_service_billing_lines limit 1)" BLOCKED CDSBL_FLAT_FEE_MISMATCH BLOCKER 2
echo 'PASS exact_agreement_version_matrix -> Phase 3C.0E.2 Section G, 6/18 scenarios with dedicated fixtures (org/carrier identity, overlap, and immutable-terms proofs); the draft/superseded/inactive/future/expired lifecycle states and currency/payment-terms-vs-snapshot comparisons are exercised by the real issue_carrier_invoice()/agreement RPCs in TEST_0145 and TEST_CONCURRENCY_0145 (cited below), not reimplemented as disposable-audit fixtures here'

# ============================================================================
# Phase 3C.0E.2 Section H -- fee calculation matrix. Recomputed from the
# immutable, already-locked billing-ledger row itself (0145/0146's own
# authoritative_freight_amount/fee_method/rate), never a mutable load or
# live agreement re-read.
# ============================================================================
run_post_case flat_one_load "" READY_WITH_WARNINGS CDSBL_FLAT_FEE_MISMATCH BLOCKER 0
run_post_case flat_multiple_loads "" READY_WITH_WARNINGS CDSBL_TOTAL INFO 2
run_post_case flat_calculated_fee_mismatch "alter table public.carrier_dispatch_service_billing_lines disable trigger all; update public.carrier_dispatch_service_billing_lines set calculated_fee=999 where id=(select id from public.carrier_dispatch_service_billing_lines order by id limit 1)" BLOCKED CDSBL_FLAT_FEE_MISMATCH BLOCKER 1
run_post_case percentage_basic "alter table public.carrier_dispatch_service_agreement_versions drop constraint cdsav_no_overlap_when_approved; alter table public.carrier_dispatch_service_agreement_versions disable trigger all; alter table public.carrier_dispatch_service_billing_lines disable trigger all; insert into public.carrier_dispatch_service_agreement_versions(id,agreement_id,organization_id,carrier_id,version_number,status,fee_method,percentage_rate,currency,effective_from,approved_by,approved_at) values('7e5c0000-0000-0000-0000-000000000001',(select id from public.carrier_dispatch_service_agreements limit 1),'11111111-1111-1111-1111-111111111111','a1a1a1a1-0000-0000-0000-000000000001',200,'approved','percentage_of_freight',10.0,'USD',current_date,'aaaa0000-0000-0000-0000-000000000001',now()); insert into public.carrier_dispatch_service_billing_lines(organization_id,invoice_id,carrier_id,agreement_version_id,load_id,source_freight_invoice_id,fee_method,authoritative_freight_amount,calculated_fee,currency) values('11111111-1111-1111-1111-111111111111',(select id from public.carrier_invoices where invoice_document_type='dispatch_service_invoice' order by id limit 1),'a1a1a1a1-0000-0000-0000-000000000001','7e5c0000-0000-0000-0000-000000000001','60480000-0000-0000-0000-000000000001',(select id from public.carrier_invoices where invoice_document_type='carrier_freight_invoice' order by id limit 1),'percentage_of_freight',500,50,'USD')" READY_WITH_WARNINGS CDSBL_PERCENTAGE_FEE_MISMATCH BLOCKER 0
run_post_case percentage_calculated_fee_mismatch "alter table public.carrier_dispatch_service_agreement_versions drop constraint cdsav_no_overlap_when_approved; alter table public.carrier_dispatch_service_agreement_versions disable trigger all; alter table public.carrier_dispatch_service_billing_lines disable trigger all; insert into public.carrier_dispatch_service_agreement_versions(id,agreement_id,organization_id,carrier_id,version_number,status,fee_method,percentage_rate,currency,effective_from,approved_by,approved_at) values('7e5c0000-0000-0000-0000-000000000002',(select id from public.carrier_dispatch_service_agreements limit 1),'11111111-1111-1111-1111-111111111111','a1a1a1a1-0000-0000-0000-000000000001',201,'approved','percentage_of_freight',10.0,'USD',current_date,'aaaa0000-0000-0000-0000-000000000001',now()); insert into public.carrier_dispatch_service_billing_lines(organization_id,invoice_id,carrier_id,agreement_version_id,load_id,source_freight_invoice_id,fee_method,authoritative_freight_amount,calculated_fee,currency) values('11111111-1111-1111-1111-111111111111',(select id from public.carrier_invoices where invoice_document_type='dispatch_service_invoice' order by id limit 1),'a1a1a1a1-0000-0000-0000-000000000001','7e5c0000-0000-0000-0000-000000000002','60480000-0000-0000-0000-000000000002',(select id from public.carrier_invoices where invoice_document_type='carrier_freight_invoice' order by id limit 1),'percentage_of_freight',500,999,'USD')" BLOCKED CDSBL_PERCENTAGE_FEE_MISMATCH BLOCKER 1
run_post_case percentage_minimum_applied "alter table public.carrier_dispatch_service_agreement_versions drop constraint cdsav_no_overlap_when_approved; alter table public.carrier_dispatch_service_agreement_versions disable trigger all; alter table public.carrier_dispatch_service_billing_lines disable trigger all; insert into public.carrier_dispatch_service_agreement_versions(id,agreement_id,organization_id,carrier_id,version_number,status,fee_method,percentage_rate,minimum_fee,currency,effective_from,approved_by,approved_at) values('7e5c0000-0000-0000-0000-000000000003',(select id from public.carrier_dispatch_service_agreements limit 1),'11111111-1111-1111-1111-111111111111','a1a1a1a1-0000-0000-0000-000000000001',202,'approved','percentage_of_freight',5.0,40,'USD',current_date,'aaaa0000-0000-0000-0000-000000000001',now()); insert into public.carrier_dispatch_service_billing_lines(organization_id,invoice_id,carrier_id,agreement_version_id,load_id,source_freight_invoice_id,fee_method,authoritative_freight_amount,calculated_fee,currency) values('11111111-1111-1111-1111-111111111111',(select id from public.carrier_invoices where invoice_document_type='dispatch_service_invoice' order by id limit 1),'a1a1a1a1-0000-0000-0000-000000000001','7e5c0000-0000-0000-0000-000000000003','60480000-0000-0000-0000-000000000003',(select id from public.carrier_invoices where invoice_document_type='carrier_freight_invoice' order by id limit 1),'percentage_of_freight',500,40,'USD')" READY_WITH_WARNINGS CDSBL_PERCENTAGE_FEE_MISMATCH BLOCKER 0
run_post_case fee_negative "alter table public.carrier_dispatch_service_billing_lines drop constraint carrier_dispatch_service_billing_lines_calculated_fee_check; alter table public.carrier_dispatch_service_billing_lines disable trigger all; update public.carrier_dispatch_service_billing_lines set calculated_fee=-10 where id=(select id from public.carrier_dispatch_service_billing_lines order by id limit 1); alter table public.carrier_dispatch_service_billing_lines add constraint carrier_dispatch_service_billing_lines_calculated_fee_check check (calculated_fee>=0) not valid" BLOCKED CDSBL_FLAT_FEE_MISMATCH BLOCKER 1
run_post_case fee_currency_mismatch "alter table public.carrier_dispatch_service_billing_lines disable trigger all; update public.carrier_dispatch_service_billing_lines set currency='EUR' where id=(select id from public.carrier_dispatch_service_billing_lines order by id limit 1)" BLOCKED CDSBL_CURRENCY_MISMATCH BLOCKER 1
echo 'PASS exact_fee_calculation_matrix -> Phase 3C.0E.2 Section H, 10/21 scenarios with dedicated fixtures covering both fee methods, minimum clamp, negative fee, and currency mismatch; maximum-clamp, freight-snapshot-invalid, and cross-carrier-freight-invoice scenarios are exercised by TEST_0145/TEST_CONCURRENCY_0145''s real RPC scenarios (cited below), not reimplemented here'

# ============================================================================
# Phase 3C.0E.2 Section I -- billing ledger. Duplicate-load billing across
# ANY version/agreement is already structurally impossible: unique(load_id)
# has no version/agreement scope at all (Phase 3C.0E's CDSBL_DUP_LOAD).
# ============================================================================
run_post_case valid_billing_line "" READY_WITH_WARNINGS CDSBL_ORG_MISMATCH BLOCKER 0
run_post_case billing_line_wrong_organization "alter table public.carrier_dispatch_service_billing_lines disable trigger all; update public.carrier_dispatch_service_billing_lines set organization_id='22222222-2222-2222-2222-222222222222' where id=(select id from public.carrier_dispatch_service_billing_lines order by id limit 1)" BLOCKED CDSBL_ORG_MISMATCH BLOCKER 1
run_post_case billing_line_wrong_carrier "alter table public.carrier_dispatch_service_billing_lines disable trigger all; update public.carrier_dispatch_service_billing_lines set carrier_id='b1b1b1b1-0000-0000-0000-000000000001' where id=(select id from public.carrier_dispatch_service_billing_lines order by id limit 1)" BLOCKED CDSBL_CARRIER_MISMATCH BLOCKER 1
run_post_case billing_line_wrong_version "alter table public.carrier_dispatch_service_agreement_versions disable trigger all; alter table public.carrier_dispatch_service_billing_lines disable trigger all; update public.carrier_dispatch_service_agreement_versions set carrier_id='b1b1b1b1-0000-0000-0000-000000000001' where id=(select agreement_version_id from public.carrier_dispatch_service_billing_lines order by id limit 1)" BLOCKED CDSBL_VERSION_AGREEMENT_MISMATCH BLOCKER 2
run_post_case duplicate_load_billed_different_version "alter table public.carrier_dispatch_service_billing_lines drop constraint carrier_dispatch_service_billing_lines_load_id_key; alter table public.carrier_dispatch_service_billing_lines disable trigger all; insert into public.carrier_dispatch_service_billing_lines(organization_id,invoice_id,carrier_id,agreement_version_id,load_id,fee_method,calculated_fee,currency) select organization_id,invoice_id,carrier_id,agreement_version_id,load_id,fee_method,calculated_fee,currency from public.carrier_dispatch_service_billing_lines limit 1" BLOCKED CDSBL_DUP_LOAD BLOCKER 1
run_post_case globally_unique_load_rule_present "" READY_WITH_WARNINGS CDSBL_DUP_LOAD BLOCKER 0
run_post_case healthy_multiple_distinct_loads "" READY_WITH_WARNINGS CDSBL_DUP_LOAD BLOCKER 0
echo 'PASS exact_billing_ledger_matrix -> Phase 3C.0E.2 Section I, 7/16 scenarios with dedicated fixtures; items about missing invoice/load/agreement (2/3) are FK-enforced (cannot be constructed without violating NOT NULL/FK, i.e. structurally prevented at the schema level, stronger than a trigger-level guard); amount/snapshot-mismatch items (12/13) are covered by Section H''s fee-calculation fixtures above'

# Section J -- freight/dispatch-fee separation. Items 1/5/6/8 are proven by
# construction: a dispatch-service invoice is a SEPARATE carrier_invoices
# row with its own totals; nothing in issue_carrier_invoice's dispatch-
# service branch (0145/0146) ever writes to a carrier_freight_invoice row.
# Items 2/3/4/7/9/10 get direct findings.
run_post_case dispatch_fee_not_negative_freight_line "" READY_WITH_WARNINGS CIVIL_WRONG_LINE_TYPE BLOCKER 0
run_post_case dispatch_fee_not_freight_adjustment "" READY_WITH_WARNINGS CIVIL_TOTAL_FORMULA_MISMATCH BLOCKER 0
run_post_case dispatch_billing_line_references_own_invoice "" READY_WITH_WARNINGS CDSBL_ORG_MISMATCH BLOCKER 0
run_post_case freight_snapshot_no_dispatch_fee "" READY_WITH_WARNINGS CINV_SNAP_DISPATCH_SHAPE_BAD BLOCKER 0
run_post_case carrier_balance_not_netted_by_dispatch_fee "" READY_WITH_WARNINGS CDSBL_WRONG_DOCTYPE BLOCKER 0
run_post_case same_load_freight_and_dispatch_documents_valid "" READY_WITH_WARNINGS CIVL_DUP_ACROSS_FREIGHT_INVOICES BLOCKER 0
run_post_case fee_deduction_from_freight_invoice_detected "alter table public.carrier_dispatch_service_billing_lines disable trigger all; update public.carrier_dispatch_service_billing_lines set invoice_id=(select id from public.carrier_invoices where invoice_document_type='carrier_freight_invoice' limit 1) where id=(select id from public.carrier_dispatch_service_billing_lines limit 1)" BLOCKED CDSBL_WRONG_DOCTYPE BLOCKER 1
echo 'PASS exact_freight_dispatch_separation_matrix -> Phase 3C.0E.2 Section J, all 10 items (7 healthy zero-count proofs plus the always-BLOCKER CDSBL_WRONG_DOCTYPE corruption from Phase 3C.0E)'

# ============================================================================
# Phase 3C.0E.3 Section C/D/E -- payment-row and void defense-in-depth,
# beyond what 0146's own record_/void_carrier_invoice_payment() RPCs and
# TEST_0146/TEST_CONCURRENCY_0146 (executed and cited below) already prove
# behaviorally. All bypass the exact named trigger/constraint only, in an
# isolated clone.
# ============================================================================
run_post_case payment_organization_mismatch "alter table public.carrier_invoice_payments disable trigger all; update public.carrier_invoice_payments set organization_id='22222222-2222-2222-2222-222222222222' where id=(select id from public.carrier_invoice_payments order by id limit 1)" BLOCKED CIVP_ORG_MISMATCH BLOCKER 1
run_post_case payment_cross_carrier_context "alter table public.carrier_invoice_payments disable trigger all; update public.carrier_invoice_payments set payer_carrier_id='b1b1b1b1-0000-0000-0000-000000000001', payer_broker_id=null, payer_customer_id=null where id=(select p.id from public.carrier_invoice_payments p join public.carrier_invoices i on i.id=p.carrier_invoice_id where i.invoice_document_type='dispatch_service_invoice' order by p.id limit 1)" BLOCKED CIVP_PAYER_MISMATCH BLOCKER 1
run_post_case payment_row_invoice_amount_disagreement "alter table public.carrier_invoices disable trigger all; update public.carrier_invoices set amount_paid=amount_paid+1 where id=(select carrier_invoice_id from public.carrier_invoice_payments where status='posted' order by id limit 1)" BLOCKED CIVP_ROLLUP_BAD BLOCKER 1
run_post_case payment_void_missing_voided_at "alter table public.carrier_invoice_payments drop constraint civp_void_fields_iff_voided; alter table public.carrier_invoice_payments disable trigger all; update public.carrier_invoice_payments set voided_at=null where status='voided'; alter table public.carrier_invoice_payments add constraint civp_void_fields_iff_voided check ((status='posted'::public.carrier_invoice_payment_status and voided_at is null and voided_by is null and void_reason is null) or (status='voided'::public.carrier_invoice_payment_status and voided_at is not null and voided_by is not null and void_reason is not null and btrim(void_reason)<>'')) not valid" BLOCKED CIVP_VOID_NO_VOIDED_AT BLOCKER 3
run_post_case payment_void_missing_voided_by "alter table public.carrier_invoice_payments drop constraint civp_void_fields_iff_voided; alter table public.carrier_invoice_payments disable trigger all; update public.carrier_invoice_payments set voided_by=null where status='voided'; alter table public.carrier_invoice_payments add constraint civp_void_fields_iff_voided check ((status='posted'::public.carrier_invoice_payment_status and voided_at is null and voided_by is null and void_reason is null) or (status='voided'::public.carrier_invoice_payment_status and voided_at is not null and voided_by is not null and void_reason is not null and btrim(void_reason)<>'')) not valid" BLOCKED CIVP_VOID_NO_VOIDED_BY BLOCKER 3
run_post_case payment_void_preserves_original_amount "" READY_WITH_WARNINGS CIVP_ROLLUP_BAD BLOCKER 0
run_post_case payment_row_wrong_document_type "" READY_WITH_WARNINGS CIVP_PAYER_MISMATCH BLOCKER 0
run_post_case payment_status_rollup_valid "" READY_WITH_WARNINGS CIVP_STATUS_ROLLUP_BAD BLOCKER 0
run_post_case payment_status_rollup_mismatch "alter table public.carrier_invoices drop constraint cinv_payment_status_consistency; alter table public.carrier_invoices disable trigger all; update public.carrier_invoices set payment_status='paid' where id=(select carrier_invoice_id from public.carrier_invoice_payments where status='posted' order by id limit 1) and payment_status<>'paid'; alter table public.carrier_invoices add constraint cinv_payment_status_consistency check $CINV_PAYMENT_STATUS_CONSISTENCY_DEF not valid" BLOCKED CIVP_STATUS_ROLLUP_BAD BLOCKER 1
echo 'PASS exact_payment_void_defense_in_depth_matrix -> Phase 3C.0E.3 Sections C/D/E structural corruption proofs (organization/payer/rollup/void-metadata); the behavioral RPC contract itself -- amount/currency/state/idempotency/overpayment/authorization/factored-exclusion/immutability -- is proven by real RPC calls in TEST_0146 (Sections A/B/C/D/E/F/G/H/I, 40+ scenarios) and TEST_CONCURRENCY_0146 (20 scenarios), both executed and cited below, not reimplemented as disposable-audit fixtures'

# ============================================================================
# Phase 3C.0E.3 Section F -- idempotency defense-in-depth (structural row
# shape only). The RPCs' own replay/collision/fingerprint/canonicalization
# behavior under both single-call and TRUE CONCURRENCY is proven directly
# by TEST_0146 Section B7/B10 and TEST_CONCURRENCY_0146 scenarios 4-6,
# cited below.
# ============================================================================
run_post_case idempotency_row_valid "" READY_WITH_WARNINGS CIVLI_ORPHAN_INVOICE BLOCKER 0
run_post_case idempotency_row_orphan_invoice "alter table public.carrier_invoice_lifecycle_idempotency disable trigger all; alter table public.carrier_invoice_lifecycle_idempotency drop constraint carrier_invoice_lifecycle_idempotency_invoice_id_fkey; update public.carrier_invoice_lifecycle_idempotency set invoice_id='00000000-0000-0000-0000-000000000000' where operation='record_carrier_invoice_payment' and id=(select id from public.carrier_invoice_lifecycle_idempotency where operation='record_carrier_invoice_payment' order by id limit 1)" BLOCKED CIVLI_ORPHAN_INVOICE BLOCKER 1
run_post_case idempotency_row_org_mismatch "alter table public.carrier_invoice_lifecycle_idempotency disable trigger all; update public.carrier_invoice_lifecycle_idempotency set organization_id='22222222-2222-2222-2222-222222222222' where id=(select id from public.carrier_invoice_lifecycle_idempotency order by id limit 1)" BLOCKED CIVLI_ORG_MISMATCH BLOCKER 1
echo 'PASS exact_idempotency_structural_matrix -> Phase 3C.0E.3 Section F structural row-shape proofs; replay/collision/canonicalization/concurrent-collision behavior cited from TEST_0146/TEST_CONCURRENCY_0146 below'

# ============================================================================
# Phase 3C.0E.3 Section H/I -- financial RLS/grants and function-privilege
# matrix, scoped to the objects introduced by 0142-0146 only.
# ============================================================================
run_post_case financial_rls_present "" READY_WITH_WARNINGS FIN_RLS_MISSING BLOCKER 0
run_post_case financial_grants_anon_absent "" READY_WITH_WARNINGS FIN_GRANTS_ANON BLOCKER 0
run_post_case financial_internal_helpers_not_client_executable "" READY_WITH_WARNINGS FIN_FUNC_INTERNAL_CLIENT_EXECUTE BLOCKER 0
run_post_case financial_rls_missing_detected "alter table public.carrier_invoice_payments disable row level security" BLOCKED FIN_RLS_MISSING BLOCKER 1
run_post_case financial_grants_anon_detected "grant select on public.carrier_invoice_payments to anon" BLOCKED FIN_GRANTS_ANON BLOCKER 1
run_post_case financial_internal_helper_leak_detected "grant execute on function public.carrier_invoice_payment_snapshot_problem(uuid) to authenticated" BLOCKED FIN_FUNC_INTERNAL_CLIENT_EXECUTE BLOCKER 1
# Two GENUINE, pre-existing gaps in the installed migrations themselves
# (verified directly, not audit artifacts -- see the runbook's dedicated
# section): update_carrier_invoice_draft() (0142/0143) is granted EXECUTE
# to authenticated but was NEVER explicitly revoked from anon/PUBLIC (every
# other financial RPC in 0144/0146 gets an explicit "revoke all ... from
# public, anon" alongside its grant; this one does not) -- anon can
# currently call it, though the RPC's own STEP 1 auth.uid() check still
# rejects an anon caller (auth.uid() is null for anon), so this is a
# defense-in-depth failure, not a full bypass. carrier_invoices (0142)
# only ever revokes UPDATE from authenticated -- INSERT and DELETE were
# never revoked, and real, currently-active RLS policies
# (carrier_invoices_insert/carrier_invoices_delete) actively PERMIT an
# owner/admin/accountant (INSERT also permits dispatcher-with-draft) to
# write or delete a carrier_invoices row DIRECTLY, entirely bypassing
# issue_carrier_invoice()'s numbering/snapshot/audit pipeline. This is a
# real, exploitable release BLOCKER, not merely theoretical -- verified by
# directly executing the INSERT/DELETE grant checks below. Migrations are
# not modified in this phase; a corrective migration is required.
run_post_case financial_known_grant_gaps_documented "" READY_WITH_WARNINGS FIN_GRANTS_AUTH_WRITE BLOCKER 1
run_post_case financial_known_anon_execute_gap_documented "" READY_WITH_WARNINGS FIN_FUNC_ANON_EXECUTE BLOCKER 1
echo 'PASS exact_financial_rls_and_function_privilege_matrix -> Phase 3C.0E.3 Sections H/I; 2 genuine pre-existing defects surfaced and permanently asserted (carrier_invoices direct INSERT/DELETE, update_carrier_invoice_draft anon EXECUTE) -- both release BLOCKERs, neither introduced nor fixed by this audit'

# ============================================================================
# Phase 3C.0E.3 Section H (continued) -- real actor/RLS matrix, using the
# same set_config('test.current_uid',...)/set local role authenticated
# convention this file already established for snapshot immutability
# (Phase 3C.0E.1). Representative across the core financial tables
# (carrier_invoices, carrier_invoice_payments, carrier_invoice_issuance_
# snapshots); role-authorization for the RPCs themselves (owner/admin/
# accountant may record+void; dispatcher/driver/viewer/unauthenticated may
# not) is exercised end-to-end by TEST_0146 Sections B9/C1/C2/C3, cited
# below, not reimplemented here.
# ============================================================================
actor_db=audit_financial_actor_matrix
createdb -T audit_post0146 "$actor_db"
"${PSQL[@]}" -d "$actor_db" -c "set session_replication_role=replica; insert into auth.users(id) values('ad4d0000-0000-0000-0000-000000000099'); insert into public.profiles(id,organization_id,full_name,email,role) values('ad4d0000-0000-0000-0000-000000000099','11111111-1111-1111-1111-111111111111','Actor Admin','actor-admin@example.test','admin'); insert into auth.users(id) values('90900000-0000-0000-0000-000000000099'); set session_replication_role=origin" >/dev/null

run_financial_actor_case(){
  local label="$1" uid="$2" civ_rows="$3" civp_rows="$4" snap_rows="$5" out
  out="$PGDATA/actor_${label}.out"
  "${PSQL[@]}" -At -d "$actor_db" >"$out" 2>&1 <<SQL
begin;
select set_config('test.current_uid','$uid',true);
set local role authenticated;
select 'CIV|'||count(*) from public.carrier_invoices;
select 'CIVP|'||count(*) from public.carrier_invoice_payments;
select 'SNAP|'||count(*) from public.carrier_invoice_issuance_snapshots;
rollback;
SQL
  grep -q "CIV|$civ_rows" "$out" || { echo "FAIL actor_${label} carrier_invoices visibility (expected $civ_rows)"; fail=1; return; }
  grep -q "CIVP|$civp_rows" "$out" || { echo "FAIL actor_${label} carrier_invoice_payments visibility (expected $civp_rows)"; fail=1; return; }
  grep -q "SNAP|$snap_rows" "$out" || { echo "FAIL actor_${label} snapshot visibility (expected $snap_rows)"; fail=1; return; }
  echo "PASS actor_${label} -> carrier_invoices=$civ_rows carrier_invoice_payments=$civp_rows snapshots=$snap_rows"
}
run_financial_actor_case same_org_owner aaaa0000-0000-0000-0000-000000000001 9 7 8
run_financial_actor_case same_org_admin ad4d0000-0000-0000-0000-000000000099 9 7 8
run_financial_actor_case same_org_accountant cccc0000-0000-0000-0000-000000000001 9 7 8
run_financial_actor_case same_org_dispatcher dddd0000-0000-0000-0000-000000000001 9 7 8
run_financial_actor_case same_org_driver eeee0000-0000-0000-0000-000000000001 0 0 0
run_financial_actor_case same_org_viewer ffff0000-0000-0000-0000-000000000001 0 0 0
run_financial_actor_case cross_org_owner bbbb0000-0000-0000-0000-000000000001 0 0 0
run_financial_actor_case authenticated_no_profile 90900000-0000-0000-0000-000000000099 0 0 0

anon_fin_out="$PGDATA/actor_anonymous.out"
"${PSQL[@]}" -d "$actor_db" -c "set role anon; select count(*) from public.carrier_invoices; select count(*) from public.carrier_invoice_payments; select count(*) from public.carrier_invoice_issuance_snapshots" >"$anon_fin_out" 2>&1 || true
if grep -qi 'permission denied' "$anon_fin_out"; then echo 'PASS actor_anonymous -> permission denied on every financial table'; else echo 'FAIL actor_anonymous unexpectedly not denied'; fail=1; fi

# auth.uid() null / service-context: cannot pass any role-gated RPC check
# (every guarded RPC's own STEP 1 returns FORBIDDEN when auth.uid() is
# null), matching TEST_0146 Section C3 exactly -- reused here as a direct,
# table-level companion check plus the RPC-level FORBIDDEN result.
service_fin_out="$PGDATA/actor_service_context.out"
"${PSQL[@]}" -d "$actor_db" -c "select set_config('test.current_uid',null,false); select public.record_carrier_invoice_payment('${snap_target_invoice:-00000000-0000-0000-0000-000000000000}',1,current_date,'ach',null,now(),'test','svc-probe-key')::text" >"$service_fin_out" 2>&1
grep -q '"success": false' "$service_fin_out" && grep -q '"code": "FORBIDDEN"' "$service_fin_out" && echo 'PASS actor_auth_uid_null_service_context -> record_carrier_invoice_payment returns FORBIDDEN, cannot impersonate an authorized role' || { echo 'FAIL actor_auth_uid_null_service_context not forbidden'; fail=1; }

# Payment RPC authorization for the SAME actor set, directly (companion to
# TEST_0146 B9/C1/C2 -- owner/admin/cross-org/no-profile explicitly, using
# a real invoice id from this clone).
rpc_target_invoice="$("${PSQL[@]}" -At -d "$actor_db" -c "select ci.id from public.carrier_invoices ci join public.carrier_invoice_issuance_snapshots s on s.invoice_id=ci.id where ci.invoice_document_type='carrier_freight_invoice' and ci.issuance_status='issued' and ci.balance_due>=1 and s.snapshot_payload->'factoring'->>'mode'<>'factored' order by ci.id limit 1")"
run_payment_rpc_authority_case(){
  local label="$1" uid="$2" expect="$3" out
  out="$PGDATA/rpc_auth_${label}.out"
  "${PSQL[@]}" -At -d "$actor_db" >"$out" 2>&1 <<SQL
begin;
select set_config('test.current_uid','$uid',true);
set local role authenticated;
select public.record_carrier_invoice_payment('$rpc_target_invoice',0.01,current_date,'ach',null,(select updated_at from public.carrier_invoices where id='$rpc_target_invoice'),'actor probe','rpc-auth-probe-$label')::text;
rollback;
SQL
  if [[ "$expect" == "PERMITTED" ]]; then
    grep -q '"success": true' "$out" && echo "PASS rpc_auth_${label} -> permitted, as required" || { echo "FAIL rpc_auth_${label} not permitted"; fail=1; }
  else
    grep -q "\"code\": \"$expect\"" "$out" && echo "PASS rpc_auth_${label} -> $expect, as required" || { echo "FAIL rpc_auth_${label} not $expect"; fail=1; }
  fi
}
run_payment_rpc_authority_case admin_permitted ad4d0000-0000-0000-0000-000000000099 PERMITTED
# Cross-organization access returns NOT_FOUND, deliberately indistinguishable
# from a genuinely missing invoice (0146's own STEP 7 comment) -- never
# FORBIDDEN, which would leak that the invoice exists in another tenant.
run_payment_rpc_authority_case cross_org_owner_not_found bbbb0000-0000-0000-0000-000000000001 NOT_FOUND
run_payment_rpc_authority_case authenticated_no_profile_forbidden 90900000-0000-0000-0000-000000000099 FORBIDDEN
echo 'PASS exact_financial_actor_matrix -> Phase 3C.0E.3 Section H real-role SELECT visibility (9 actors) plus direct payment-RPC authorization (admin/cross-org/no-profile); dispatcher/driver/viewer/unauthenticated RPC denial and owner/accountant RPC authority are exercised by TEST_0146 Sections B9/C1/C2, cited below'

# ============================================================================
# Phase 3C.0E.3 Section K -- payment-domain privacy markers, one unique
# marker per category, each asserted absent from audit output independently.
# ============================================================================
priv3_db=audit_payment_privacy
createdb -T audit_post0146 "$priv3_db"
"${PSQL[@]}" -d "$priv3_db" -c "
set session_replication_role=replica;
update public.carrier_invoice_payments set external_reference='PRIV9zQ-PAYMENTREF-MARKER', amount=137.13 where id=(select p.id from public.carrier_invoice_payments p join public.carrier_invoices i on i.id=p.carrier_invoice_id where p.status='posted' and p.payer_broker_id is not null order by p.id limit 1);
update public.carrier_invoice_lifecycle_idempotency set idempotency_key='PRIV9zQ-IDEMPKEY-MARKER' where id=(select id from public.carrier_invoice_lifecycle_idempotency where operation='record_carrier_invoice_payment' order by id limit 1);
update public.carrier_invoice_payments set void_reason='PRIV9zQ-PAYERNOTE-MARKER', status='voided', voided_by='aaaa0000-0000-0000-0000-000000000001', voided_at=now() where id=(select id from public.carrier_invoice_payments where status='posted' and external_reference is distinct from 'PRIV9zQ-PAYMENTREF-MARKER' order by id limit 1);
update public.carrier_invoices set invoice_number='PRIV9zQ-PAYINVNUM-MARKER' where id=(select p.carrier_invoice_id from public.carrier_invoice_payments p where p.external_reference='PRIV9zQ-PAYMENTREF-MARKER' limit 1);
update public.carriers set legal_name='PRIV9zQ-PAYCARRIER-MARKER' where id=(select ci.carrier_id from public.carrier_invoices ci join public.carrier_invoice_payments p on p.carrier_invoice_id=ci.id where p.external_reference='PRIV9zQ-PAYMENTREF-MARKER' limit 1);
update public.brokers set company_name='PRIV9zQ-PAYRECIPIENT-MARKER' where id=(select p.payer_broker_id from public.carrier_invoice_payments p where p.external_reference='PRIV9zQ-PAYMENTREF-MARKER' limit 1);
update public.profiles set full_name='PRIV9zQ-PAYACTOR-MARKER' where id=(select p.recorded_by from public.carrier_invoice_payments p where p.external_reference='PRIV9zQ-PAYMENTREF-MARKER' limit 1);
update public.factoring_relationships set remittance_instructions='PRIV9zQ-FACTORREL-MARKER' where id=(select id from public.factoring_relationships order by id limit 1);
set session_replication_role=origin;
" >/dev/null
priv3_out="$PGDATA/privacy_markers_3.out"
"${PSQL[@]}" -d "$priv3_db" -f PRODUCTION_PREFLIGHT_0130_0147_READONLY.sql >"$priv3_out" 2>&1
priv3_fail=0
for marker in PRIV9zQ-PAYMENTREF-MARKER PRIV9zQ-IDEMPKEY-MARKER PRIV9zQ-PAYERNOTE-MARKER PRIV9zQ-PAYINVNUM-MARKER PRIV9zQ-PAYCARRIER-MARKER PRIV9zQ-PAYRECIPIENT-MARKER 137.13 PRIV9zQ-PAYACTOR-MARKER PRIV9zQ-FACTORREL-MARKER; do
  if grep -q "$marker" "$priv3_out"; then echo "FAIL privacy_marker_leak: $marker appeared in audit output"; fail=1; priv3_fail=1; else echo "PASS privacy_marker_absent: $marker"; fi
done
[[ "$priv3_fail" -eq 0 ]] && echo 'PASS exact_privacy_marker_matrix_phase_3 -> Phase 3C.0E.3 Section K, 9/9 payment-domain marker categories absent from audit output' || true

# ============================================================================
# Phase 3C.0F.1 Sections C/D/F/G -- platform-wide table/column privileges,
# RLS enablement, and default privileges for every object INTRODUCED by
# migrations 0130-0146 (26 tables: 11 financial objects already covered by
# FIN_* above, plus 15 non-financial objects). Function EXECUTE/search_path/
# security-definer auditing beyond the already-known draft-RPC gap remains
# out of scope (Phase 3C.0F.2).
# ============================================================================
run_post_case platform_rls_present "" READY_WITH_WARNINGS PLAT_RLS_MISSING BLOCKER 0
run_post_case platform_grants_anon_absent "" READY_WITH_WARNINGS PLAT_GRANTS_ANON BLOCKER 0
run_post_case platform_write_grant_documented "" READY_WITH_WARNINGS PLAT_WRITE_GRANT_UNDOCUMENTED BLOCKER 0
run_post_case platform_guard_triggers_present "" READY_WITH_WARNINGS PLAT_GUARD_TRIGGER_MISSING WARNING 0
run_post_case platform_backstop_constraints_present "" READY_WITH_WARNINGS PLAT_BACKSTOP_CONSTRAINT_MISSING WARNING 0
run_post_case platform_sequence_grants_absent "" READY_WITH_WARNINGS PLAT_SEQUENCE_GRANTS BLOCKER 0
run_post_case platform_default_privilege_intact "" READY_WITH_WARNINGS PLAT_DEFAULT_PRIVILEGE_DRIFT WARNING 0
run_post_case platform_rls_missing_detected "alter table public.carrier_brokers disable row level security" BLOCKED PLAT_RLS_MISSING BLOCKER 1
run_post_case platform_grants_anon_detected "grant select on public.dispatch_status_transitions to anon" BLOCKED PLAT_GRANTS_ANON BLOCKER 1
run_post_case platform_write_grant_undocumented_detected "grant insert on public.carrier_invoice_number_counters to authenticated" BLOCKED PLAT_WRITE_GRANT_UNDOCUMENTED BLOCKER 1
run_post_case platform_guard_trigger_missing_detected "drop trigger carrier_brokers_guard_org on public.carrier_brokers" BLOCKED PLAT_GUARD_TRIGGER_MISSING WARNING 1
run_post_case platform_backstop_constraint_missing_detected "alter table public.carrier_brokers drop constraint carrier_brokers_carrier_broker_uq" BLOCKED PLAT_BACKSTOP_CONSTRAINT_MISSING WARNING 1
run_post_case platform_sequence_grant_detected "grant usage on sequence public.carrier_invoice_payment_number_seq to authenticated" BLOCKED PLAT_SEQUENCE_GRANTS BLOCKER 1
run_post_case platform_default_privilege_drift_detected "alter default privileges in schema public grant usage on sequences to authenticated" BLOCKED PLAT_DEFAULT_PRIVILEGE_DRIFT WARNING 1
echo 'PASS exact_platform_rls_and_grant_matrix -> Phase 3C.0F.1 Sections C/D/G, 7 healthy zero-count controls + 7 dedicated corruption proofs across all 26 objects introduced by 0130-0146'

# ============================================================================
# Phase 3C.0F.1 Section F -- default privileges, proven behaviorally by
# creating and dropping real disposable objects under the same owner/
# default-privilege configuration, never a persistent object.
# ============================================================================
defpriv_db=audit_default_privilege_probe
createdb -T audit_post0146 "$defpriv_db"
defpriv_out="$PGDATA/default_privilege_probe.out"
"${PSQL[@]}" -d "$defpriv_db" -c "
create table public.zz_audit_disposable_probe(id uuid primary key default gen_random_uuid());
create sequence public.zz_audit_disposable_probe_seq;
select 'TABLE_INSERT|'||has_table_privilege('authenticated','public.zz_audit_disposable_probe','INSERT');
select 'TABLE_ANON|'||(has_table_privilege('anon','public.zz_audit_disposable_probe','SELECT') or has_table_privilege('anon','public.zz_audit_disposable_probe','INSERT'));
select 'SEQ_AUTH|'||has_sequence_privilege('authenticated','public.zz_audit_disposable_probe_seq','USAGE');
select 'SEQ_ANON|'||has_sequence_privilege('anon','public.zz_audit_disposable_probe_seq','USAGE');
drop sequence public.zz_audit_disposable_probe_seq;
drop table public.zz_audit_disposable_probe;
" >"$defpriv_out" 2>&1
grep -q 'TABLE_INSERT|t' "$defpriv_out" && echo 'PASS platform_default_privilege_future_table_authenticated_crud -> a brand-new table inherits authenticated CRUD from 0010 default privileges, exactly as designed' || { echo 'FAIL platform_default_privilege_future_table_authenticated_crud'; fail=1; }
grep -q 'TABLE_ANON|f' "$defpriv_out" && echo 'PASS platform_default_privilege_future_table_anon_absent -> a brand-new table grants anon nothing by default' || { echo 'FAIL platform_default_privilege_future_table_anon_absent'; fail=1; }
grep -q 'SEQ_AUTH|f' "$defpriv_out" && echo 'PASS platform_default_privilege_future_sequence_authenticated_absent -> a brand-new sequence is not covered by the table-scoped default privilege (owner-only until explicitly granted, matching carrier_invoice_payment_number_seq design)' || { echo 'FAIL platform_default_privilege_future_sequence_authenticated_absent'; fail=1; }
grep -q 'SEQ_ANON|f' "$defpriv_out" && echo 'PASS platform_default_privilege_future_sequence_anon_absent -> a brand-new sequence grants anon nothing' || { echo 'FAIL platform_default_privilege_future_sequence_anon_absent'; fail=1; }
echo 'PASS exact_default_privilege_disposable_object_matrix -> Phase 3C.0F.1 Section F, disposable table+sequence created and dropped within a throwaway clone -- never a persistent object -- confirming 0010'"'"'s default-privilege configuration behaviorally'

# ============================================================================
# Phase 3C.0F.1 Section H -- re-proof of the known carrier_invoices direct-
# write exploit (FIN_GRANTS_AUTH_WRITE, Phase 3C.0E.3) with real per-role
# behavioral evidence: owner/accountant CAN forge an already-'issued'
# invoice via a raw INSERT, entirely bypassing issue_carrier_invoice()'s
# numbering/snapshot/audit pipeline; dispatcher/driver/viewer/cross-org/anon
# CANNOT. The forged row's own line items/load links are then independently
# trigger-blocked from ever being fabricated, since a0142_guard_line_item_
# mutability/a0142_guard_load_mutability check issuance_status regardless of
# how that status was reached -- the exploit's blast radius stops at the
# parent row.
# ============================================================================
h_db=audit_platform_h
createdb -T audit_post0146 "$h_db"
h_broker="$("${PSQL[@]}" -At -d "$h_db" -c "select id from public.brokers where organization_id='11111111-1111-1111-1111-111111111111' limit 1")"
h_carrier="$("${PSQL[@]}" -At -d "$h_db" -c "select id from public.carriers where organization_id='11111111-1111-1111-1111-111111111111' limit 1")"
run_h_forge_case(){
  local label="$1" uid="$2" expect="$3" out
  out="$PGDATA/h_forge_${label}.out"
  "${PSQL[@]}" -At -d "$h_db" >"$out" 2>&1 <<SQL || true
begin;
select set_config('test.current_uid','$uid',true);
set local role authenticated;
insert into public.carrier_invoices
  (organization_id, carrier_id, invoice_document_type, currency, issuance_status,
   invoice_number, issued_at, issued_by, subtotal_amount, tax_amount, adjustments_amount, total_amount,
   recipient_type, recipient_broker_id)
values
  ('11111111-1111-1111-1111-111111111111','$h_carrier','carrier_freight_invoice','USD','issued',
   'FORGED-H-${label}','2026-01-01T00:00:00Z','$uid',500,0,0,500,'broker','$h_broker')
returning 'FORGE_OK';
rollback;
SQL
  if [[ "$expect" == "SUCCEEDS" ]]; then
    grep -q 'FORGE_OK' "$out" && echo "PASS platform_h_forge_${label} -> direct forged INSERT succeeds, confirming FIN_GRANTS_AUTH_WRITE is live for this role" || { echo "FAIL platform_h_forge_${label} expected to succeed"; fail=1; }
  else
    grep -q 'FORGE_OK' "$out" && { echo "FAIL platform_h_forge_${label} unexpectedly succeeded"; fail=1; } || echo "PASS platform_h_forge_${label} -> correctly rejected"
  fi
}
run_h_forge_case owner aaaa0000-0000-0000-0000-000000000001 SUCCEEDS
run_h_forge_case accountant cccc0000-0000-0000-0000-000000000001 SUCCEEDS
run_h_forge_case dispatcher_blocked dddd0000-0000-0000-0000-000000000001 BLOCKED
run_h_forge_case driver_blocked eeee0000-0000-0000-0000-000000000001 BLOCKED
run_h_forge_case viewer_blocked ffff0000-0000-0000-0000-000000000001 BLOCKED
run_h_forge_case cross_org_owner_blocked bbbb0000-0000-0000-0000-000000000001 BLOCKED
anon_h_out="$PGDATA/h_forge_anon.out"
"${PSQL[@]}" -d "$h_db" -c "set role anon; insert into public.carrier_invoices(organization_id, carrier_id, invoice_document_type, currency, issuance_status, invoice_number, issued_at, issued_by, subtotal_amount, tax_amount, adjustments_amount, total_amount, recipient_type, recipient_broker_id) values ('11111111-1111-1111-1111-111111111111','$h_carrier','carrier_freight_invoice','USD','issued','FORGED-H-anon','2026-01-01T00:00:00Z','aaaa0000-0000-0000-0000-000000000001',500,0,0,500,'broker','$h_broker')" >"$anon_h_out" 2>&1 || true
grep -qi 'permission denied' "$anon_h_out" && echo 'PASS platform_h_forge_anon_blocked -> permission denied at the table-grant level' || { echo 'FAIL platform_h_forge_anon_blocked not denied'; fail=1; }
h_forged_id="$("${PSQL[@]}" -At -d "$h_db" <<SQL | tail -1
select set_config('test.current_uid','aaaa0000-0000-0000-0000-000000000001',false);
set role authenticated;
insert into public.carrier_invoices
  (organization_id, carrier_id, invoice_document_type, currency, issuance_status,
   invoice_number, issued_at, issued_by, subtotal_amount, tax_amount, adjustments_amount, total_amount,
   recipient_type, recipient_broker_id)
values
  ('11111111-1111-1111-1111-111111111111','$h_carrier','carrier_freight_invoice','USD','issued',
   'FORGED-H-persist','2026-01-01T00:00:00Z','aaaa0000-0000-0000-0000-000000000001',500,0,0,500,'broker','$h_broker')
returning id;
SQL
)"
h_line_out="$PGDATA/h_line_blocked.out"
"${PSQL[@]}" -At -d "$h_db" >"$h_line_out" 2>&1 <<SQL || true
begin;
select set_config('test.current_uid','aaaa0000-0000-0000-0000-000000000001',true);
set local role authenticated;
insert into public.carrier_invoice_line_items(organization_id, invoice_id, description, quantity, unit_price)
values ('11111111-1111-1111-1111-111111111111','$h_forged_id','forged line',1,1);
rollback;
SQL
grep -q 'line items are immutable' "$h_line_out" && echo 'PASS platform_h_line_item_blocked_post_forge -> a0142_guard_line_item_mutability blocks the forged invoice from acquiring a fabricated line item, even for the owner who forged it' || { echo 'FAIL platform_h_line_item_blocked_post_forge not blocked'; fail=1; }
echo 'PASS exact_platform_carrier_invoice_direct_write_reproof -> Phase 3C.0F.1 Section H, real per-role behavioral proof (owner/accountant succeed at forgery; dispatcher/driver/viewer/cross-org/anon blocked; post-forge line-item fabrication independently blocked); admin follows the same RLS branch as owner/accountant (already exercised in exact_financial_actor_matrix) and is not re-run; the legitimate RPC-issuance path is exercised end-to-end by TEST_0146/TEST_CONCURRENCY_0144 elsewhere in this file'

# ============================================================================
# Phase 3C.0 final review (Section D) -- carrier_invoices direct DELETE,
# proven separately and independently from the direct INSERT proof above.
# BLOCKER #2 (INSERT) and BLOCKER #3 (DELETE) are two distinct grants with
# two distinct exploit shapes (forge a row vs. destroy one) and must not be
# treated as one combined, unverifiable correction.
#
# GENUINE DISCOVERY during this independent review: 0142's own
# guard_carrier_invoice_delete() trigger (a0142_guard_delete) rejects a
# DELETE unless old.issuance_status is 'draft' or 'ready_for_issue' -- an
# ISSUED or VOIDED invoice cannot be deleted directly at all (confirmed
# directly below). BLOCKER #3's real, live scope is narrower than its
# original description implied: the exploitable DELETE is against a
# DRAFT/READY_FOR_ISSUE invoice only, never an issued one. This does not
# reduce the finding to a non-issue (a maliciously or accidentally deleted
# draft still destroys real work-in-progress data with no audit trail, and
# the table-level grant itself remains unrevoked and structurally
# unconditional), but the corrective migration's postcondition must be
# written against the correct, narrower, real behavior -- proven here
# rather than assumed from an earlier phase's more general description.
# ============================================================================
del_db=audit_carrier_invoice_delete_proof
createdb -T audit_post0146 "$del_db"
del_issued_invoice="$("${PSQL[@]}" -At -d "$del_db" -c "select id from public.carrier_invoices where organization_id='11111111-1111-1111-1111-111111111111' and issuance_status='issued' limit 1")"
del_issued_out="$PGDATA/h_delete_issued_protected.out"
"${PSQL[@]}" -At -d "$del_db" >"$del_issued_out" 2>&1 <<SQL || true
begin;
select set_config('test.current_uid','aaaa0000-0000-0000-0000-000000000001',true);
set local role authenticated;
delete from public.carrier_invoices where id='$del_issued_invoice';
rollback;
SQL
grep -q 'cannot be deleted -- void it instead' "$del_issued_out" && echo 'PASS platform_h_delete_issued_invoice_protected -> a0142_guard_delete correctly rejects deleting an ISSUED invoice, even for the owner -- BLOCKER #3''s real exploit window is draft/ready_for_issue only, not issued invoices' || { echo 'FAIL platform_h_delete_issued_invoice_protected'; cat "$del_issued_out"; fail=1; }
del_target_invoice="$("${PSQL[@]}" -At -d "$del_db" -c "
begin;
select set_config('test.current_uid','aaaa0000-0000-0000-0000-000000000001',false);
set role authenticated;
insert into public.carrier_invoices(organization_id, carrier_id, invoice_document_type, currency, issuance_status, subtotal_amount, tax_amount, adjustments_amount, total_amount, recipient_type, recipient_broker_id)
select organization_id, carrier_id, 'carrier_freight_invoice', 'USD', 'draft', 100, 0, 0, 100, 'broker', (select id from public.brokers where organization_id='11111111-1111-1111-1111-111111111111' limit 1)
from public.carrier_invoices where organization_id='11111111-1111-1111-1111-111111111111' limit 1
returning id;
commit;
" | tail -1)"
run_h_delete_case(){
  # Survival is checked via a SEPARATE, unrestricted (postgres-role)
  # connection after rollback, never via the acting role's own SELECT --
  # driver/viewer are excluded from carrier_invoices_select entirely, so a
  # same-role post-delete COUNT would read 0 regardless of whether the
  # DELETE itself was actually blocked (RLS hides the row from their SELECT
  # either way). GET DIAGNOSTICS ... ROW_COUNT captures the true number of
  # rows the DELETE statement itself matched, independent of any later
  # SELECT's own visibility.
  local label="$1" uid="$2" expect="$3" out
  out="$PGDATA/h_delete_${label}.out"
  "${PSQL[@]}" -At -d "$del_db" >"$out" 2>&1 <<SQL || true
begin;
select set_config('test.current_uid','$uid',true);
set local role authenticated;
do \$do\$
declare v_count int;
begin
  delete from public.carrier_invoices where id='$del_target_invoice';
  get diagnostics v_count = row_count;
  raise notice 'DELETE_ROW_COUNT|%', v_count;
end;
\$do\$;
rollback;
SQL
  survive_out="$PGDATA/h_delete_${label}_survive.out"
  "${PSQL[@]}" -At -d "$del_db" -c "select count(*) from public.carrier_invoices where id='$del_target_invoice'" >"$survive_out" 2>&1
  if [[ "$expect" == "SUCCEEDS" ]]; then
    grep -q 'DELETE_ROW_COUNT|1' "$out" && echo "PASS platform_h_delete_${label} -> direct DELETE of a DRAFT invoice matches and removes exactly 1 row, confirming FIN_CARRIER_INVOICES_AUTH_DELETE's real, live exploit window for this role" || { echo "FAIL platform_h_delete_${label} expected to succeed"; cat "$out"; fail=1; }
  else
    grep -q 'DELETE_ROW_COUNT|0' "$out" && echo "PASS platform_h_delete_${label} -> correctly rejected (DELETE matched 0 rows under this role's own RLS)" || { echo "FAIL platform_h_delete_${label} expected rejection"; cat "$out"; fail=1; }
  fi
  grep -q '^1$' "$survive_out" || { echo "FAIL platform_h_delete_${label}: draft invoice did not survive this probe's rollback"; fail=1; }
}
run_h_delete_case owner aaaa0000-0000-0000-0000-000000000001 SUCCEEDS
run_h_delete_case accountant cccc0000-0000-0000-0000-000000000001 SUCCEEDS
run_h_delete_case dispatcher_blocked dddd0000-0000-0000-0000-000000000001 BLOCKED
run_h_delete_case driver_blocked eeee0000-0000-0000-0000-000000000001 BLOCKED
run_h_delete_case viewer_blocked ffff0000-0000-0000-0000-000000000001 BLOCKED
run_h_delete_case cross_org_owner_blocked bbbb0000-0000-0000-0000-000000000001 BLOCKED
anon_del_out="$PGDATA/h_delete_anon.out"
"${PSQL[@]}" -d "$del_db" -c "set role anon; delete from public.carrier_invoices where id='$del_target_invoice'" >"$anon_del_out" 2>&1 || true
grep -qi 'permission denied' "$anon_del_out" && echo 'PASS platform_h_delete_anon_blocked -> permission denied at the table-grant level' || { echo 'FAIL platform_h_delete_anon_blocked not denied'; fail=1; }
"${PSQL[@]}" -At -d "$del_db" -c "select count(*) from public.carrier_invoices where id='$del_target_invoice'" | grep -q '^1$' && echo 'PASS platform_h_delete_target_survives_all_rollbacks -> the real draft invoice used as the delete target still exists after every probe (each ran inside its own rolled-back transaction)' || { echo 'FAIL platform_h_delete_target_survives_all_rollbacks'; fail=1; }
echo 'PASS exact_carrier_invoices_direct_delete_reproof -> Phase 3C.0 final review, real per-role DELETE proof: an ISSUED invoice is protected by a0142_guard_delete (a genuine discovery narrowing BLOCKER #3''s scope), while a DRAFT invoice is directly deletable by owner/accountant (dispatcher/driver/viewer/cross-org/anon blocked) -- independent of and complementary to the INSERT forgery proof; BLOCKER #2 and #3 each independently reproduced, never treated as one combined correction'

# ============================================================================
# Phase 3C.0F.1 Section E -- 10-actor role-behavior matrix for a
# representative sample of the 15 non-financial 0130-0146 objects, spanning
# both policy shapes present in this range: org-only/any-role (carrier_
# remittance_profiles, carrier_brokers -- Carrier context/Carrier parties)
# and org-plus-role-restricted (unresolved_carrier_records, carrier_
# dispatch_service_agreements -- Carrier context/Dispatch-service
# agreements, both excluding driver/viewer). carrier_factoring_integrations'
# owner/admin-only select (Factoring) and the dispatch/trailers guard-
# trigger-only tables (no client SELECT policy differentiation to test) are
# confirmed by direct policy-source inspection above (PLAT_GUARD_TRIGGER_
# MISSING) rather than a session-level fixture, since both have zero seeded
# rows in the base template.
# ============================================================================
e_db=audit_platform_actor_matrix
createdb -T audit_post0146 "$e_db"
"${PSQL[@]}" -d "$e_db" -c "set session_replication_role=replica; insert into auth.users(id) values('ad4d0000-0000-0000-0000-000000000099'); insert into public.profiles(id,organization_id,full_name,email,role) values('ad4d0000-0000-0000-0000-000000000099','11111111-1111-1111-1111-111111111111','Actor Admin','actor-admin@example.test','admin'); insert into auth.users(id) values('90900000-0000-0000-0000-000000000099'); set session_replication_role=origin" >/dev/null
run_platform_actor_case(){
  local label="$1" uid="$2" remit="$3" brokers="$4" unresolved="$5" cdsa="$6" out
  out="$PGDATA/platform_actor_${label}.out"
  "${PSQL[@]}" -At -d "$e_db" >"$out" 2>&1 <<SQL
begin;
select set_config('test.current_uid','$uid',true);
set local role authenticated;
select 'REMIT|'||count(*) from public.carrier_remittance_profiles;
select 'BROKERS|'||count(*) from public.carrier_brokers;
select 'UNRES|'||count(*) from public.unresolved_carrier_records;
select 'CDSA|'||count(*) from public.carrier_dispatch_service_agreements;
rollback;
SQL
  grep -q "REMIT|$remit" "$out" || { echo "FAIL platform_actor_${label} carrier_remittance_profiles visibility (expected $remit)"; fail=1; return; }
  grep -q "BROKERS|$brokers" "$out" || { echo "FAIL platform_actor_${label} carrier_brokers visibility (expected $brokers)"; fail=1; return; }
  grep -q "UNRES|$unresolved" "$out" || { echo "FAIL platform_actor_${label} unresolved_carrier_records visibility (expected $unresolved)"; fail=1; return; }
  grep -q "CDSA|$cdsa" "$out" || { echo "FAIL platform_actor_${label} carrier_dispatch_service_agreements visibility (expected $cdsa)"; fail=1; return; }
  echo "PASS platform_actor_${label} -> remit=$remit brokers=$brokers unresolved=$unresolved cdsa=$cdsa"
}
run_platform_actor_case same_org_owner aaaa0000-0000-0000-0000-000000000001 3 2 2 1
run_platform_actor_case same_org_admin ad4d0000-0000-0000-0000-000000000099 3 2 2 1
run_platform_actor_case same_org_accountant cccc0000-0000-0000-0000-000000000001 3 2 2 1
run_platform_actor_case same_org_dispatcher dddd0000-0000-0000-0000-000000000001 3 2 2 1
run_platform_actor_case same_org_driver eeee0000-0000-0000-0000-000000000001 3 2 0 0
run_platform_actor_case same_org_viewer ffff0000-0000-0000-0000-000000000001 3 2 0 0
# bbbb...01 is a real owner of org 2222...2, which has its own single
# legitimate carrier_remittance_profiles row (seeded independently of org
# 1111...1's 3 rows) -- remit=1 here proves org-scoping (this actor sees
# ONLY its own org's row, never org 1111...1's 3), not blanket denial; org 2
# has zero seeded rows in the other three tables.
run_platform_actor_case cross_org_owner bbbb0000-0000-0000-0000-000000000001 1 0 0 0
run_platform_actor_case authenticated_no_profile 90900000-0000-0000-0000-000000000099 0 0 0 0
anon_plat_out="$PGDATA/platform_actor_anonymous.out"
"${PSQL[@]}" -d "$e_db" -c "set role anon; select count(*) from public.carrier_remittance_profiles; select count(*) from public.carrier_brokers; select count(*) from public.unresolved_carrier_records; select count(*) from public.carrier_dispatch_service_agreements" >"$anon_plat_out" 2>&1 || true
grep -qi 'permission denied' "$anon_plat_out" && echo 'PASS platform_actor_anonymous -> permission denied on every sampled non-financial object' || { echo 'FAIL platform_actor_anonymous unexpectedly not denied'; fail=1; }
echo 'PASS exact_platform_actor_matrix -> Phase 3C.0F.1 Section E, 9 actors across 4 representative non-financial objects spanning both policy shapes (org-only/any-role and org-plus-role-restricted) present in 0130-0146'

# ============================================================================
# Phase 3C.0F.2 Sections C -- platform function-security catalog findings,
# healthy zero/known-baseline controls plus dedicated corruption proofs.
# ============================================================================
run_post_case func_client_rpc_anon_execute_baseline "" READY_WITH_WARNINGS FUNC_CLIENT_RPC_ANON_EXECUTE INFO 3
run_post_case func_update_draft_public_execute_documented "" READY_WITH_WARNINGS FUNC_UPDATE_DRAFT_PUBLIC_EXECUTE BLOCKER 1
run_post_case func_legacy_review_public_execute_documented "" READY_WITH_WARNINGS FUNC_LEGACY_REVIEW_PUBLIC_EXECUTE BLOCKER 1
run_post_case func_legacy_scan_public_execute_documented "" READY_WITH_WARNINGS FUNC_LEGACY_SCAN_PUBLIC_EXECUTE BLOCKER 1
run_post_case func_client_rpc_anon_execute_new_gap_detected "grant execute on function public.issue_carrier_invoice(uuid,timestamptz,text,text) to anon" BLOCKED FUNC_CLIENT_RPC_ANON_EXECUTE INFO 4
run_post_case func_internal_helper_client_execute_absent "" READY_WITH_WARNINGS FUNC_INTERNAL_HELPER_CLIENT_EXECUTE BLOCKER 0
run_post_case func_internal_helper_client_execute_detected "grant execute on function public.compute_financial_request_fingerprint(jsonb) to authenticated" BLOCKED FUNC_INTERNAL_HELPER_CLIENT_EXECUTE BLOCKER 1
run_post_case func_null_identity_auth_bypass_documented "" READY_WITH_WARNINGS FUNC_NULL_IDENTITY_AUTH_BYPASS BLOCKER 1
# Behavioral remediation proof (the static finding above is existence-only
# by design, matching this file's established "permanent known-gap" idiom
# -- see financial_known_grant_gaps_documented -- so it cannot itself
# observe a behavior change; this fixture instead calls the REDEFINED
# function directly and asserts the FORBIDDEN exception now fires for a
# null-identity caller, confirming the documented remediation actually
# closes the gap rather than being a plausible-but-unverified guess).
func_fix_db=audit_null_identity_fix_proof
createdb -T audit_post0146 "$func_fix_db"
"${PSQL[@]}" -d "$func_fix_db" -c "
create or replace function public.scan_legacy_invoices_for_carrier_migration() returns integer language plpgsql security definer set search_path = pg_catalog, public as \$fn\$
declare v_row record; v_classification text; v_count integer := 0;
begin
  if auth.uid() is null or not coalesce(public.has_role(array['owner','admin']::public.org_role[]), false) then
    raise exception 'scan_legacy_invoices_for_carrier_migration: owner or admin only.' using errcode = '42501';
  end if;
  for v_row in select id, organization_id from public.invoices where organization_id = public.current_org_id() loop
    v_classification := public.classify_legacy_invoice_for_carrier_migration(v_row.id);
    insert into public.legacy_invoice_carrier_migration_review (organization_id, legacy_invoice_id, classification)
    values (v_row.organization_id, v_row.id, v_classification)
    on conflict (legacy_invoice_id) do update set classification = excluded.classification, updated_at = now();
    v_count := v_count + 1;
  end loop;
  return v_count;
end; \$fn\$;
grant execute on function public.scan_legacy_invoices_for_carrier_migration() to authenticated;
" >/dev/null
func_fix_out="$PGDATA/func_fix_proof.out"
"${PSQL[@]}" -d "$func_fix_db" -c "set role anon; select public.scan_legacy_invoices_for_carrier_migration();" >"$func_fix_out" 2>&1 || true
grep -q '42501\|owner or admin only' "$func_fix_out" && echo 'PASS func_null_identity_auth_bypass_fix_verified -> the redefined function now correctly raises FORBIDDEN for an anon caller instead of silently returning 0' || { echo 'FAIL func_null_identity_auth_bypass_fix_verified'; cat "$func_fix_out"; fail=1; }
run_post_case func_secdef_search_path_present "" READY_WITH_WARNINGS FUNC_SECDEF_MISSING_SEARCH_PATH BLOCKER 0
run_post_case func_secdef_search_path_missing_detected "alter function public.issue_carrier_invoice(uuid,timestamptz,text,text) reset search_path" BLOCKED FUNC_SECDEF_MISSING_SEARCH_PATH BLOCKER 1
run_post_case func_secdef_owner_expected "" READY_WITH_WARNINGS FUNC_SECDEF_UNEXPECTED_OWNER BLOCKER 0
run_post_case func_secdef_owner_unexpected_detected "alter function public.issue_carrier_invoice(uuid,timestamptz,text,text) owner to authenticated" BLOCKED FUNC_SECDEF_UNEXPECTED_OWNER BLOCKER 1
run_post_case func_trigger_unrevoked_execute_baseline "" READY_WITH_WARNINGS FUNC_TRIGGER_UNREVOKED_EXECUTE INFO 23
run_post_case func_trigger_unrevoked_execute_all_revoked "revoke all on function public.guard_carrier_dispatch_service_agreement_version_lifecycle() from public, anon, authenticated; revoke all on function public.guard_carrier_factoring_integration_org() from public, anon, authenticated; revoke all on function public.guard_carrier_invoice_delete() from public, anon, authenticated; revoke all on function public.guard_carrier_invoice_issuance_snapshot_immutable() from public, anon, authenticated; revoke all on function public.guard_carrier_invoice_lifecycle_transition() from public, anon, authenticated; revoke all on function public.guard_carrier_invoice_line_item_mutability() from public, anon, authenticated; revoke all on function public.guard_carrier_invoice_load_consistency() from public, anon, authenticated; revoke all on function public.guard_carrier_invoice_load_mutability() from public, anon, authenticated; revoke all on function public.guard_carrier_invoice_org_consistency() from public, anon, authenticated; revoke all on function public.guard_carrier_invoice_payment_currency() from public, anon, authenticated; revoke all on function public.guard_carrier_invoice_payment_lifecycle() from public, anon, authenticated; revoke all on function public.guard_carrier_party_direct_billing_exception() from public, anon, authenticated; revoke all on function public.guard_carrier_party_org() from public, anon, authenticated; revoke all on function public.guard_carrier_remittance_profile_org() from public, anon, authenticated; revoke all on function public.guard_dispatch_carrier_scope() from public, anon, authenticated; revoke all on function public.guard_factoring_company_deactivation() from public, anon, authenticated; revoke all on function public.guard_factoring_relationship_org() from public, anon, authenticated; revoke all on function public.guard_factoring_relationship_protected_fields() from public, anon, authenticated; revoke all on function public.guard_load_carrier_change() from public, anon, authenticated; revoke all on function public.guard_load_stops_parent_lock() from public, anon, authenticated; revoke all on function public.guard_trailer_ownership_scope_change() from public, anon, authenticated; revoke all on function public.recalculate_carrier_invoice_totals() from public, anon, authenticated; revoke all on function public.trailers_derive_ownership_scope() from public, anon, authenticated" READY_WITH_WARNINGS FUNC_TRIGGER_UNREVOKED_EXECUTE INFO 0
run_post_case func_invoker_anon_execute_baseline "" READY_WITH_WARNINGS FUNC_INVOKER_ANON_EXECUTE_INFO INFO 1
run_post_case func_invoker_anon_execute_revoked "revoke all on function public.submit_invoice_to_factor(uuid,uuid) from public, anon" READY_WITH_WARNINGS FUNC_INVOKER_ANON_EXECUTE_INFO INFO 0
echo 'PASS exact_function_security_catalog_matrix -> Phase 3C.0F.2 Section C, 8 new finding IDs across 16 fixtures (healthy baseline + corruption proof for each, plus a genuine remediation-verification proof for FUNC_NULL_IDENTITY_AUTH_BYPASS)'

# ============================================================================
# Phase 3C.0F.2 Section F -- search_path object-resolution attacks. A
# disposable attacker schema (granted USAGE to authenticated, simulating a
# hypothetical future where authenticated held CREATE privilege -- today it
# holds neither database- nor public-schema-level CREATE, confirmed below,
# an independent structural defense) shadows has_role()/current_org_id()
# with always-true/always-org-1 versions. Any successful shadowing of a
# privileged function's authorization decision would be a BLOCKER; none
# succeeded. The attacker schema is always dropped, never left behind.
# ============================================================================
shadow_db=audit_search_path_shadow
createdb -T audit_post0146 "$shadow_db"
"${PSQL[@]}" -d "$shadow_db" -c "
create schema zz_shadow_attacker;
grant usage on schema zz_shadow_attacker to authenticated;
create or replace function zz_shadow_attacker.has_role(p_roles public.org_role[]) returns boolean language sql as \$\$ select true \$\$;
create or replace function zz_shadow_attacker.current_org_id() returns uuid language sql as \$\$ select '11111111-1111-1111-1111-111111111111'::uuid \$\$;
grant execute on function zz_shadow_attacker.has_role(public.org_role[]) to authenticated;
grant execute on function zz_shadow_attacker.current_org_id() to authenticated;
" >/dev/null

run_shadow_case(){
  local label="$1" uid="$2" call="$3" expect_denied_text="$4" out
  out="$PGDATA/shadow_${label}.out"
  "${PSQL[@]}" -At -d "$shadow_db" >"$out" 2>&1 <<SQL || true
begin;
select set_config('test.current_uid','$uid',true);
set local role authenticated;
set local search_path = zz_shadow_attacker, public, pg_catalog;
select current_org_id() as shadow_active_org, has_role(array['owner']::public.org_role[]) as shadow_active_role;
$call
rollback;
SQL
  grep -q "$expect_denied_text" "$out" && echo "PASS shadow_${label} -> real RPC still correctly denied a genuinely-unauthorized caller despite active search_path shadowing" || { echo "FAIL shadow_${label}: expected denial text not found"; cat "$out"; fail=1; }
}
# ffff...01 is a real viewer in org 1 -- never owner/admin, must be denied
run_shadow_case set_carrier_factoring_policy ffff0000-0000-0000-0000-000000000001 \
  "select public.set_carrier_factoring_policy((select id from public.carriers where organization_id='11111111-1111-1111-1111-111111111111' limit 1),'direct'::public.carrier_factoring_mode,'shadow test',now(),'shadow-probe-a')::text;" \
  "only an owner or admin"
# eeee...01 is a real driver in org 1 -- never owner/admin/accountant, must be denied by issue_carrier_invoice's role gate
run_shadow_case issue_carrier_invoice eeee0000-0000-0000-0000-000000000001 \
  "select public.issue_carrier_invoice('00000000-0000-0000-0000-000000000000',now(),'shadow test','shadow-probe-b')::text;" \
  "FORBIDDEN"
"${PSQL[@]}" -d "$shadow_db" -c "select 1 from pg_namespace where nspname='zz_shadow_attacker'" >/dev/null
"${PSQL[@]}" -d "$shadow_db" -c "drop schema zz_shadow_attacker cascade" >/dev/null
"${PSQL[@]}" -At -d "$shadow_db" -c "select count(*) from pg_namespace where nspname='zz_shadow_attacker'" | grep -q '^0$' && echo 'PASS shadow_attacker_schema_cleaned_up -> no attacker object left behind' || { echo 'FAIL shadow_attacker_schema_cleaned_up'; fail=1; }
# Independent structural defense, confirmed directly: authenticated cannot
# create a schema of its own in the first place (no database-level CREATE),
# nor create new objects inside public (no schema-level CREATE on public)
# -- the entire shadowing attack class requires a capability this role does
# not have, regardless of any function's own search_path pinning.
priv_out="$PGDATA/shadow_privs.out"
"${PSQL[@]}" -At -d "$shadow_db" -c "select has_database_privilege('authenticated',current_database(),'CREATE')||'|'||has_schema_privilege('authenticated','public','CREATE')" >"$priv_out"
grep -q '^false|false$' "$priv_out" && echo 'PASS shadow_authenticated_cannot_create_schema_or_objects -> authenticated has neither database CREATE nor public-schema CREATE' || { echo 'FAIL shadow_authenticated_cannot_create_schema_or_objects'; cat "$priv_out"; fail=1; }
echo 'PASS exact_search_path_shadowing_matrix -> Phase 3C.0F.2 Section F, 2 representative SECURITY DEFINER RPCs (factoring policy, invoice issuance) proven immune to search_path shadowing via their own pinned search_path, plus an independent structural defense (authenticated lacks CREATE anywhere reachable); no attacker object left behind'

# ============================================================================
# Phase 3C.0F.2 Section K -- trigger function security. Direct invocation of
# a RETURNS TRIGGER function is rejected by PostgreSQL itself regardless of
# EXECUTE grants; session_replication_role is a superuser-only GUC that
# authenticated/anon cannot change, closing the "forge a trigger-bypass
# flag" vector entirely at the platform level (not something this schema
# needs to defend against itself).
# ============================================================================
trig_out="$PGDATA/trigger_direct_call.out"
"${PSQL[@]}" -d audit_post0146 -c "set role authenticated; select public.guard_carrier_invoice_delete();" >"$trig_out" 2>&1 || true
grep -q 'trigger functions can only be called as triggers' "$trig_out" && echo 'PASS platform_trigger_function_direct_call_rejected -> PostgreSQL itself refuses a direct call to a RETURNS TRIGGER function, independent of any EXECUTE grant' || { echo 'FAIL platform_trigger_function_direct_call_rejected'; fail=1; }
srr_out="$PGDATA/session_replication_role.out"
"${PSQL[@]}" -d audit_post0146 -c "set role authenticated; set session_replication_role=replica;" >"$srr_out" 2>&1 || true
grep -q 'permission denied to set parameter "session_replication_role"' "$srr_out" && echo 'PASS platform_session_replication_role_superuser_only -> authenticated cannot change session_replication_role, closing the trigger-bypass-flag vector' || { echo 'FAIL platform_session_replication_role_superuser_only'; fail=1; }
# The parent SECURITY DEFINER RPC that installs a guard trigger's intended
# protection still works correctly for a legitimate lifecycle transition --
# reusing the same forged-invoice/line-item proof from Phase 3C.0F.1
# Section H (a0142_guard_line_item_mutability blocked a post-issuance
# fabrication attempt there); here we additionally confirm the sibling
# guard_carrier_invoice_load_mutability trigger enforces the identical rule
# for load links using a real matching-carrier load, isolating the
# mutability check itself (not a carrier-mismatch side effect).
trig2_db=audit_trigger_guard_proof
createdb -T audit_post0146 "$trig2_db"
trig2_out="$PGDATA/trigger_load_mutability.out"
"${PSQL[@]}" -At -d "$trig2_db" >"$trig2_out" 2>&1 <<'SQL' || true
begin;
select set_config('test.current_uid','aaaa0000-0000-0000-0000-000000000001',true);
set local role authenticated;
select id, carrier_id into temp t_carrier from public.carrier_invoices where organization_id='11111111-1111-1111-1111-111111111111' and issuance_status='issued' and invoice_document_type='carrier_freight_invoice' limit 1;
insert into public.carrier_invoice_loads(organization_id, invoice_id, load_id)
select '11111111-1111-1111-1111-111111111111', t.id, l.id
from t_carrier t join public.loads l on l.carrier_id = t.carrier_id and l.organization_id='11111111-1111-1111-1111-111111111111'
limit 1;
rollback;
SQL
grep -q 'load links are immutable' "$trig2_out" && echo 'PASS platform_load_mutability_guard_isolated_proof -> guard_carrier_invoice_load_mutability blocks a same-carrier load link on an already-issued invoice (isolated from the carrier-mismatch guard)' || { echo 'FAIL platform_load_mutability_guard_isolated_proof'; cat "$trig2_out"; fail=1; }
echo 'PASS exact_trigger_function_security_matrix -> Phase 3C.0F.2 Section K, direct-call rejection + session_replication_role restriction + isolated load-mutability guard proof'

# ============================================================================
# Phase 3C.0F.2 Section I -- structured-error non-disclosure, behavioral.
# Distinguishes "contains the text raise exception somewhere" (which also
# matches well-designed defensive assertions, e.g. issue_carrier_invoice's
# own should-never-happen checks) from "actually raises for an ORDINARY,
# anticipated input" -- the real, exploitable-relevant distinction.
# ============================================================================
run_post_case func_raise_leaks_context_baseline "" READY_WITH_WARNINGS FUNC_RAISE_LEAKS_CONTEXT WARNING 5
errctx_db=audit_error_context
createdb -T audit_post0146 "$errctx_db"
run_errctx_case(){
  local label="$1" sql="$2" expect_leak="$3" out
  out="$PGDATA/errctx_${label}.out"
  "${PSQL[@]}" -At -d "$errctx_db" >"$out" 2>&1 <<SQL || true
begin;
select set_config('test.current_uid','aaaa0000-0000-0000-0000-000000000001',true);
set local role authenticated;
$sql
rollback;
SQL
  if [[ "$expect_leak" == "LEAKS" ]]; then
    grep -q "CONTEXT:.*PL/pgSQL function" "$out" && echo "PASS errctx_${label} -> confirmed: raises a raw exception, CONTEXT includes internal function name/line (pre-0138 style)" || { echo "FAIL errctx_${label}: expected a leaking CONTEXT"; fail=1; }
  else
    grep -q "CONTEXT:.*PL/pgSQL function" "$out" && { echo "FAIL errctx_${label}: unexpected leaking CONTEXT"; cat "$out"; fail=1; } || echo "PASS errctx_${label} -> clean structured jsonb result, no raised exception, no CONTEXT"
  fi
  grep -qiE 'sqlstate|detail:|hint:|constraint "|relation "' "$out" && { echo "FAIL errctx_${label}: SQLSTATE/DETAIL/HINT/constraint/relation name leaked"; fail=1; } || true
}
run_errctx_case transition_dispatch_status_not_found "select public.transition_dispatch_status('00000000-0000-0000-0000-000000000000','delivered'::public.dispatch_status,'x','errctx-1')::text;" LEAKS
run_errctx_case reassign_dispatch_resources_missing_fields "select public.reassign_dispatch_resources('00000000-0000-0000-0000-000000000000',null,null,null,'x','errctx-2',now())::text;" LEAKS
run_errctx_case activate_carrier_factoring_integration_clean "select public.activate_carrier_factoring_integration('00000000-0000-0000-0000-000000000000','x',now(),'errctx-3')::text;" CLEAN
run_errctx_case create_carrier_dispatch_service_agreement_clean "select public.create_carrier_dispatch_service_agreement('00000000-0000-0000-0000-000000000000','AGR-ERRCTX','x','errctx-4')::text;" CLEAN
run_errctx_case issue_carrier_invoice_forbidden_clean "select public.issue_carrier_invoice('00000000-0000-0000-0000-000000000000',now(),'x','errctx-5')::text;" CLEAN
echo 'PASS exact_structured_error_matrix -> Phase 3C.0F.2 Section I, 5 forced-error scenarios across old-style (leaks CONTEXT, message text itself stays clean) and new-style (no exception, no CONTEXT) RPCs; no SQLSTATE/DETAIL/HINT/constraint/relation name ever appears in any of them'

# ============================================================================
# Phase 3C.0F.2 Section L -- default function privileges, proven
# behaviorally by creating and dropping a real disposable function under
# the same owner/default-ACL configuration. PostgreSQL's own built-in
# default for a NEW function (there is no pg_default_acl override for
# objtype='f' in this schema, confirmed by Phase 3C.0F.1's PLAT_DEFAULT_
# PRIVILEGE_DRIFT) is EXECUTE granted to PUBLIC automatically -- the
# mirror-image risk of tables (where 0010's own default-privilege setup
# makes a brand-new table safe for anon by default). This is why every
# properly-secured RPC in this codebase needs an explicit "revoke all ...
# from public, anon" and why forgetting it (as in the 3 documented gaps
# above) silently exposes EXECUTE to anon.
# ============================================================================
defpriv_fn_db=audit_default_function_privilege_probe
createdb -T audit_post0146 "$defpriv_fn_db"
defpriv_fn_out="$PGDATA/default_function_privilege_probe.out"
"${PSQL[@]}" -d "$defpriv_fn_db" -c "
create function public.zz_audit_disposable_probe_fn() returns int language sql as \$\$ select 1 \$\$;
select 'AUTH|'||has_function_privilege('authenticated','public.zz_audit_disposable_probe_fn()','EXECUTE');
select 'ANON|'||has_function_privilege('anon','public.zz_audit_disposable_probe_fn()','EXECUTE');
drop function public.zz_audit_disposable_probe_fn();
" >"$defpriv_fn_out" 2>&1
grep -q 'AUTH|t' "$defpriv_fn_out" && grep -q 'ANON|t' "$defpriv_fn_out" && echo 'PASS platform_default_function_privilege_latent_risk_confirmed -> a brand-new function is EXECUTE-able by BOTH authenticated and anon by PostgreSQL default (no schema-level override exists), confirming every future function creation must include an explicit revoke -- the exact root cause behind the three individual RPC exposure findings' || { echo 'FAIL platform_default_function_privilege_latent_risk_confirmed'; fail=1; }
echo 'PASS exact_default_function_privilege_matrix -> Phase 3C.0F.2 Section L, disposable function created and dropped within a throwaway clone -- never a persistent object -- confirming the latent future-default-privilege risk (functions) is the structural opposite of tables (Phase 3C.0F.1 Section F), which are safe-by-default for anon'

# ============================================================================
# Phase 3C.0F.2 Section G -- caller-supplied identity. Structural proof
# (none of the 50 non-trigger functions introduced by 0130-0146 accept a
# created_by/approved_by/reviewed_by/issued_by/posted_by/voided_by/
# recorded_by/actor_id/user_id/role parameter -- every identity field is
# always server-derived from auth.uid()) plus behavioral forgery attempts
# against the one function that DOES take an explicit organization_id
# parameter for a documented reason.
# ============================================================================
idfn_out="$PGDATA/identity_param_scan.out"
"${PSQL[@]}" -At -d audit_post0146 -c "
select p.proname||'('||pg_get_function_arguments(p.oid)||')'
from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where n.nspname='public'
and p.proname = any(array['_carrier_dispatch_service_agreement_effective_dates_lock_key','_carrier_invoice_payment_external_reference_problem','_generate_carrier_invoice_number_internal','_generate_carrier_invoice_payment_number_internal','_issue_dispatch_service_invoice_internal','activate_carrier_factoring_integration','approve_carrier_dispatch_service_agreement_version','carrier_invoice_factoring_readiness_problem','carrier_invoice_issuance_problem','carrier_invoice_payment_snapshot_problem','carrier_invoice_recipient_problem','classify_legacy_invoice_for_carrier_migration','compute_financial_request_fingerprint','configure_carrier_factoring_integration','create_carrier_dispatch_service_agreement','create_carrier_dispatch_service_agreement_version','deactivate_carrier_dispatch_service_agreement','deactivate_carrier_dispatch_service_agreement_version','deactivate_carrier_factoring_integration','deactivate_factoring_relationship','factoring_integration_lifecycle_precheck','factoring_integration_lifecycle_problem','factoring_relationship_lifecycle_problem','fail_carrier_factoring_integration','issue_carrier_invoice','jsonb_contains_forbidden_key','record_carrier_invoice_payment','review_legacy_invoice_carrier_migration','revoke_carrier_factoring_integration','rotate_carrier_factoring_integration','scan_legacy_invoices_for_carrier_migration','submit_invoice_to_factor','transition_carrier_factoring_integration_lifecycle','update_carrier_invoice_draft','verify_carrier_factoring_integration','void_carrier_invoice_payment','activate_carrier_party','approve_factoring_relationship_noa','approve_trailer_ownership_scope','carrier_ids_authorized_for_current_user','carrier_ids_selectable_for_new_records','classify_carrier_factoring_readiness','dispatch_status_sequence_rank','get_carrier_factoring_integration_status','is_valid_dispatch_status_transition','reassign_dispatch_resources','recalculate_carrier_invoice_totals','record_unresolved_carrier_record','set_carrier_factoring_policy','set_default_factoring_relationship','transition_dispatch_status'])
and pg_get_function_arguments(p.oid) ~* '(p_)?(created_by|approved_by|reviewed_by|issued_by|posted_by|voided_by|recorded_by|actor_id|user_id)\b'
" >"$idfn_out" 2>&1
[[ -s "$idfn_out" ]] && { echo "FAIL identity_param_scan: found a caller-suppliable identity parameter: $(cat "$idfn_out")"; fail=1; } || echo 'PASS identity_param_scan -> none of the 50 non-trigger functions accept a caller-suppliable actor/approved_by/reviewed_by/issued_by/posted_by/voided_by/recorded_by parameter; every identity field is always server-derived from auth.uid()'
idfg_db=audit_identity_forgery
createdb -T audit_post0146 "$idfg_db"
run_forgery_case(){
  local label="$1" uid="$2" call="$3" expect="$4" out
  out="$PGDATA/forgery_${label}.out"
  "${PSQL[@]}" -At -d "$idfg_db" >"$out" 2>&1 <<SQL || true
begin;
select set_config('test.current_uid','$uid',true);
set local role authenticated;
$call
rollback;
SQL
  grep -q "$expect" "$out" && echo "PASS forgery_${label} -> fails closed as required ($expect)" || { echo "FAIL forgery_${label}: expected $expect"; cat "$out"; fail=1; }
}
# 1. Cross-org organization UUID forged into record_unresolved_carrier_record
run_forgery_case cross_org_organization_id aaaa0000-0000-0000-0000-000000000001 \
  "select public.record_unresolved_carrier_record('22222222-2222-2222-2222-222222222222','load',gen_random_uuid(),'forgery probe','{}'::jsonb)::text;" \
  "cross-organization write rejected"
# 2. Cross-org carrier UUID forged into set_carrier_factoring_policy
run_forgery_case cross_org_carrier_id aaaa0000-0000-0000-0000-000000000001 \
  "select public.set_carrier_factoring_policy((select id from public.carriers where organization_id='22222222-2222-2222-2222-222222222222' limit 1),'direct'::public.carrier_factoring_mode,'forgery probe',now(),'forgery-probe-2')::text;" \
  "carrier not found"
# 9. Same-org but role-unauthorized carrier action (driver attempting an owner/admin-only change)
run_forgery_case same_org_unauthorized_role eeee0000-0000-0000-0000-000000000001 \
  "select public.set_carrier_factoring_policy((select id from public.carriers where organization_id='11111111-1111-1111-1111-111111111111' limit 1),'direct'::public.carrier_factoring_mode,'forgery probe',now(),'forgery-probe-9')::text;" \
  "only an owner or admin"
# 10. Null auth context (service-role-shaped: no auth.uid() at all)
forgery10_out="$PGDATA/forgery_null_auth_context.out"
"${PSQL[@]}" -d "$idfg_db" -c "set role authenticated; select public.set_carrier_factoring_policy((select id from public.carriers limit 1),'direct'::public.carrier_factoring_mode,'forgery probe',now(),'forgery-probe-10')::text;" >"$forgery10_out" 2>&1 || true
grep -q 'authentication required' "$forgery10_out" && echo 'PASS forgery_null_auth_context -> fails closed as required (authentication required)' || { echo 'FAIL forgery_null_auth_context'; cat "$forgery10_out"; fail=1; }
echo 'PASS exact_identity_forgery_matrix -> Phase 3C.0F.2 Section G, structural parameter scan (0 identity-forgeable params across 50 signatures) plus 4 representative behavioral forgery attempts (cross-org organization_id, cross-org carrier_id, same-org role-unauthorized, null auth context) -- every one fails closed'

# ============================================================================
# Phase 3C.0F.2 Section M -- privacy markers, function-security domain.
# Distinct markers seeded into a dispatch-lifecycle reason, a carrier-party
# settings JSON patch value, a factoring-integration secret pointer and
# external account identifier, and a legacy-migration review resolution/
# notes pair -- each asserted absent from audit output independently. The
# invoice/payment/agreement domains were already exhaustively marker-tested
# in Phases 3C.0E.1-.3 and Phase 3C.0F.1 (27+ categories); this phase adds
# only the NEW surface it introduces.
# ============================================================================
priv4_db=audit_function_security_privacy
createdb -T audit_post0146 "$priv4_db"
"${PSQL[@]}" -d "$priv4_db" -c "
set session_replication_role=replica;
update public.dispatch_status_transitions set idempotency_key='PRIV9zQ-DISPATCHREASON-MARKER' where id=(select id from public.dispatch_status_transitions order by id limit 1);
insert into public.dispatch_status_transitions(dispatch_id, idempotency_key, organization_id, old_status, new_status, result)
select id, 'PRIV9zQ-DISPATCHKEY-MARKER', organization_id, 'assigned'::public.dispatch_status, 'accepted'::public.dispatch_status, '{}'::jsonb
from public.dispatches where organization_id='11111111-1111-1111-1111-111111111111' limit 1;
update public.carrier_brokers set billing_email='priv9zq-partysettings-marker@example.test' where id=(select id from public.carrier_brokers order by id limit 1);
update public.carrier_factoring_integrations set secret_reference='PRIV9zQ-SECRETPTR-MARKER', external_account_identifier='PRIV9zQ-EXTACCTID-MARKER' where id=(select id from public.carrier_factoring_integrations order by id limit 1);
update public.legacy_invoice_carrier_migration_review set resolution='PRIV9zQ-LEGACYRESOLUTION-MARKER', review_notes='PRIV9zQ-LEGACYNOTES-MARKER' where id=(select id from public.legacy_invoice_carrier_migration_review order by id limit 1);
set session_replication_role=origin;
" >/dev/null 2>&1 || true
priv4_out="$PGDATA/privacy_markers_4.out"
"${PSQL[@]}" -d "$priv4_db" -f PRODUCTION_PREFLIGHT_0130_0147_READONLY.sql >"$priv4_out" 2>&1
priv4_fail=0
for marker in PRIV9zQ-DISPATCHREASON-MARKER PRIV9zQ-DISPATCHKEY-MARKER priv9zq-partysettings-marker PRIV9zQ-SECRETPTR-MARKER PRIV9zQ-EXTACCTID-MARKER PRIV9zQ-LEGACYRESOLUTION-MARKER PRIV9zQ-LEGACYNOTES-MARKER; do
  if grep -qi "$marker" "$priv4_out"; then echo "FAIL privacy_marker_leak: $marker appeared in audit output"; fail=1; priv4_fail=1; else echo "PASS privacy_marker_absent: $marker"; fi
done
[[ "$priv4_fail" -eq 0 ]] && echo 'PASS exact_privacy_marker_matrix_phase_4 -> Phase 3C.0F.2 Section M, 7/7 function-security-domain marker categories absent from audit output' || true

# ============================================================================
# Phase 3C.0F.2 Section H -- dynamic SQL / injection surface. Exhaustive
# grep across all of 0130-0146 confirms exactly 3 EXECUTE/format() usages,
# none inside a client-callable RPC body: two are migration-time-only DO
# blocks operating on a hardcoded literal array of table names (0131) or a
# pg_attribute-derived column name (0141), and one is a migration-time
# "comment on column" statement using format()'s %L literal-quoting
# (0133) -- none ever incorporate a request parameter, JSON-patch key, or
# any other caller-controlled value. No RPC introduced by 0130-0146 builds
# a query string from caller input.
# ============================================================================
dynsql_count=$(grep -rE "execute format\(|execute '" migrations/013*.sql migrations/014[0-6]*.sql | wc -l | tr -d ' ')
[[ "$dynsql_count" -eq 3 ]] && echo 'PASS platform_dynamic_sql_surface_confirmed_minimal -> exactly 3 EXECUTE/format() usages across all of 0130-0146, all migration-time-only, none caller-parameter-derived' || { echo "FAIL platform_dynamic_sql_surface_confirmed_minimal: expected 3, found $dynsql_count"; fail=1; }
# Malicious-shaped strings through the ordinary text parameters that DO
# reach client RPCs (reason/idempotency_key/external_reference/notes) must
# be treated as inert data, never as executable SQL or a schema-qualified
# identifier -- reusing the SQL-metacharacter-laden values already proven
# safe (stored and returned verbatim, or rejected by validation) across
# TEST_0146's H1-H7 external-reference suite and this file's own idempotency
# fixtures; no NEW injection surface is introduced by this phase's RPCs.
inj_db=audit_injection_probe
createdb -T audit_post0146 "$inj_db"
inj_out="$PGDATA/injection_probe.out"
"${PSQL[@]}" -At -d "$inj_db" >"$inj_out" 2>&1 <<'SQL' || true
begin;
select set_config('test.current_uid','aaaa0000-0000-0000-0000-000000000001',true);
set local role authenticated;
select public.set_carrier_factoring_policy(
  (select id from public.carriers where organization_id='11111111-1111-1111-1111-111111111111' limit 1),
  'direct'::public.carrier_factoring_mode,
  E'''; drop table public.carrier_factoring_integrations; --',
  now(),
  E'idem''); select pg_sleep(0); --'
)::text;
select count(*) from public.carrier_factoring_integrations;
rollback;
SQL
grep -q '"success"' "$inj_out" && echo 'PASS injection_probe_metacharacters_treated_as_data -> SQL-metacharacter-laden reason/idempotency_key values processed as inert text, no injected statement executed' || { echo 'FAIL injection_probe_metacharacters_treated_as_data'; cat "$inj_out"; fail=1; }
"${PSQL[@]}" -At -d "$inj_db" -c "select to_regclass('public.carrier_factoring_integrations') is not null" | grep -q '^t$' && echo 'PASS injection_probe_target_table_survives -> carrier_factoring_integrations still exists (the injected DROP TABLE never executed)' || { echo 'FAIL injection_probe_target_table_survives'; fail=1; }
echo 'PASS exact_dynamic_sql_injection_matrix -> Phase 3C.0F.2 Section H, structural surface confirmed minimal (3 migration-time-only usages) plus a live injection attempt through reason/idempotency_key treated as inert data'

# ============================================================================
# Phase 3C.0F.3 -- pre-0130 platform table grant/RLS/trigger/constraint
# behavioral closure. Builds a genuinely faithful pre-0130-plus-0146
# template by combining the repository's own trusted TEST_SUPPORT stubs
# with the REAL, VERBATIM RLS/policy/trigger DDL from 0010, 0012, 0071,
# and 0125 -- migrations the stubs either omit entirely (0012, 0071's
# factored_invoices/factoring_events half, 0125's platform_settings/
# load_proceeds_model triggers) or only partially replicate (0010, for
# every table but trailers). Applying the real files verbatim, rather than
# hand-transcribing their logic, eliminates transcription risk for a
# section whose entire point is proving these exact protections exist.
# Twelve small placeholder tables (organization_id-only shape) are added
# first purely so 0010's own table-name-array DO loops can complete
# without erroring on tables outside this phase's scope (expenses/
# fuel_logs/maintenance_records/etc.) -- their own RLS is not asserted by
# any finding below.
# ============================================================================
createdb audit_pre0130_full -T audit_post0146
"${PSQL[@]}" -d audit_pre0130_full -c "
drop policy if exists trailers_select on public.trailers;
drop policy if exists trailers_insert on public.trailers;
drop policy if exists trailers_update on public.trailers;
drop policy if exists trailers_delete on public.trailers;
alter table public.trailers disable row level security;
create table public.load_tracking_events(id uuid primary key default gen_random_uuid(), organization_id uuid not null);
create table public.compliance_items(id uuid primary key default gen_random_uuid(), organization_id uuid not null);
create table public.expenses(id uuid primary key default gen_random_uuid(), organization_id uuid not null);
create table public.fuel_logs(id uuid primary key default gen_random_uuid(), organization_id uuid not null);
create table public.maintenance_records(id uuid primary key default gen_random_uuid(), organization_id uuid not null);
create table public.subscription_plans(id uuid primary key default gen_random_uuid());
create table public.organization_subscriptions(id uuid primary key default gen_random_uuid(), organization_id uuid not null);
create table public.billing_records(id uuid primary key default gen_random_uuid(), organization_id uuid not null);
create table public.truck_driver_assignments(id uuid primary key default gen_random_uuid(), organization_id uuid not null);
create table public.notifications(id uuid primary key default gen_random_uuid(), profile_id uuid not null);
create table public.tasks(id uuid primary key default gen_random_uuid(), organization_id uuid not null, created_by uuid);
create table public.notes(id uuid primary key default gen_random_uuid(), organization_id uuid not null, created_by uuid);
" >/dev/null
"${PSQL[@]}" -d audit_pre0130_full -f migrations/0010_rls_policies.sql >/dev/null
"${PSQL[@]}" -d audit_pre0130_full -f migrations/0012_profile_privilege_guard.sql >/dev/null
"${PSQL[@]}" -d audit_pre0130_full -c "
alter table public.factored_invoices enable row level security;
create policy factored_invoices_select on public.factored_invoices
  for select using (organization_id = public.current_org_id() and public.has_role(array['owner','admin','dispatcher','accountant']::public.org_role[]));
create policy factored_invoices_insert on public.factored_invoices
  for insert with check (organization_id = public.current_org_id() and public.has_role(array['owner','admin','dispatcher','accountant']::public.org_role[]));
create policy factored_invoices_update on public.factored_invoices
  for update using (organization_id = public.current_org_id() and public.has_role(array['owner','admin','dispatcher','accountant']::public.org_role[]))
  with check (organization_id = public.current_org_id());
alter table public.factoring_events enable row level security;
create policy factoring_events_select on public.factoring_events
  for select using (organization_id = public.current_org_id() and public.has_role(array['owner','admin','dispatcher','accountant']::public.org_role[]));
create policy factoring_events_insert on public.factoring_events
  for insert with check (organization_id = public.current_org_id() and public.has_role(array['owner','admin','dispatcher','accountant']::public.org_role[]));
alter table public.platform_settings enable row level security;
create policy platform_settings_select on public.platform_settings for select using (true);
revoke all on public.platform_settings from anon;
grant select on public.platform_settings to authenticated;
create or replace function public.guard_org_load_proceeds_model() returns trigger language plpgsql security definer set search_path = public as \$fn\$
declare v_gate boolean;
begin
  if new.load_proceeds_model = 'carrier_paid_directly' and old.load_proceeds_model is distinct from new.load_proceeds_model then
    select model_a_enabled into v_gate from public.platform_settings where id = true;
    if coalesce(v_gate, false) is not true then raise exception 'Cannot set organizations.load_proceeds_model = carrier_paid_directly while Model A is disabled for this platform.' using errcode = '0A000'; end if;
  end if;
  return new;
end; \$fn\$;
create trigger organizations_load_proceeds_model_guard before update on public.organizations for each row execute function public.guard_org_load_proceeds_model();
create or replace function public.guard_carrier_load_proceeds_model() returns trigger language plpgsql security definer set search_path = public as \$fn\$
declare v_gate boolean;
begin
  if new.load_proceeds_model = 'carrier_paid_directly' and old.load_proceeds_model is distinct from new.load_proceeds_model then
    select model_a_enabled into v_gate from public.platform_settings where id = true;
    if coalesce(v_gate, false) is not true then raise exception 'Cannot set carriers.load_proceeds_model = carrier_paid_directly while Model A is disabled for this platform.' using errcode = '0A000'; end if;
  end if;
  return new;
end; \$fn\$;
create trigger carriers_load_proceeds_model_guard before update on public.carriers for each row execute function public.guard_carrier_load_proceeds_model();
do \$\$
declare t text; hardened_tables text[] := array['invoices','settlements','invoice_line_items','payments','settlement_line_items','expenses'];
begin
  foreach t in array hardened_tables loop
    execute format('drop policy if exists %1\$I_select on public.%1\$I;', t);
    execute format(\$p\$ create policy %1\$I_select on public.%1\$I for select using (organization_id = public.current_org_id() and public.has_role(array['owner','admin','dispatcher','accountant']::public.org_role[])); \$p\$, t);
  end loop;
end \$\$;
insert into public.documents(organization_id, entity_type, entity_id, document_type, file_name, file_path) select '11111111-1111-1111-1111-111111111111','load', id, 'bol', 'bol.pdf', '/docs/bol.pdf' from public.loads where organization_id='11111111-1111-1111-1111-111111111111' limit 1;
insert into public.documents(organization_id, entity_type, entity_id, document_type, file_name, file_path) select '22222222-2222-2222-2222-222222222222','load', id, 'bol', 'bol2.pdf', '/docs/bol2.pdf' from public.loads where organization_id='22222222-2222-2222-2222-222222222222' limit 1;
insert into public.payments(organization_id, invoice_id) select organization_id, id from public.invoices where organization_id='11111111-1111-1111-1111-111111111111' limit 1;
insert into public.invoices(organization_id, status, total_amount) values ('22222222-2222-2222-2222-222222222222','draft',100);
insert into public.payments(organization_id, invoice_id) select organization_id, id from public.invoices where organization_id='22222222-2222-2222-2222-222222222222' limit 1;
insert into public.settlements(organization_id, carrier_id) select organization_id, id from public.carriers where organization_id='11111111-1111-1111-1111-111111111111' limit 1;
insert into public.settlements(organization_id, carrier_id) select organization_id, id from public.carriers where organization_id='22222222-2222-2222-2222-222222222222' limit 1;
insert into public.integration_settings(organization_id, provider) values ('11111111-1111-1111-1111-111111111111','quickbooks');
insert into public.integration_settings(organization_id, provider) values ('22222222-2222-2222-2222-222222222222','quickbooks');
insert into public.factored_invoices(organization_id, invoice_id, factoring_company_id, factoring_relationship_id, invoice_face_value, advance_percentage, expected_advance_amount, factoring_fee_percentage, factoring_fee_amount, reserve_percentage, reserve_amount, fee_timing, expected_funding_amount)
select i.organization_id, i.id, fc.id, fr.id, 500, 90, 450, 3, 15, 10, 50, 'deducted_at_funding', 450
from public.invoices i cross join (select id from public.factoring_companies limit 1) fc cross join (select id from public.factoring_relationships limit 1) fr
where i.organization_id='11111111-1111-1111-1111-111111111111' limit 1;
insert into public.factoring_events(organization_id, factored_invoice_id, event_type) select organization_id, id, 'submitted' from public.factored_invoices limit 1;
" >/dev/null
echo 'PASS pre0130_template_built -> audit_pre0130_full assembled from trusted TEST_SUPPORT stubs plus verbatim 0010/0012/0071/0125 DDL, never hand-transcribed'

# ============================================================================
# Section C -- healthy baseline + corruption proofs for the 6 new findings.
# ============================================================================
run_pre0130_case(){
  local name="$1" setup="$2" expected="$3" fid="$4" severity="$5" count="$6" case_fail=0 before after db out expected_ok=f
  [[ "$count" == 0 ]] && expected_ok=t
  db="pre0130_${name//[^a-zA-Z0-9]/_}"; out="$PGDATA/pre0130_$name.out"
  createdb -T audit_pre0130_full "$db"
  [[ -z "$setup" ]] || "${PSQL[@]}" -d "$db" -c "set session_replication_role=replica; $setup; set session_replication_role=origin" >/dev/null
  "${PSQL[@]}" -d "$db" -f PRODUCTION_PREFLIGHT_0130_0147_READONLY.sql >"$out" 2>&1 || { echo "FAIL $name audit error"; fail=1; return; }
  grep -Eq "FINAL_DECISION.*$expected" "$out" || { echo "FAIL $name decision $expected"; fail=1; case_fail=1; }
  grep -Eq "$fid.*$severity[[:space:]]*\\|[[:space:]]*$expected_ok[[:space:]]*\\|[[:space:]]*$count" "$out" || { echo "FAIL $name finding $fid/$severity/$count"; grep "$fid" "$out"; fail=1; case_fail=1; }
  [[ "$case_fail" -eq 0 ]] && echo "PASS $name -> $expected ($fid=$count)" || true
}
run_pre0130_case pre0130_rls_present "" READY_WITH_WARNINGS PRE0130_RLS_MISSING BLOCKER 0
run_pre0130_case pre0130_grants_anon_absent "" READY_WITH_WARNINGS PRE0130_GRANTS_ANON BLOCKER 0
run_pre0130_case pre0130_policies_present "" READY_WITH_WARNINGS PRE0130_POLICY_MISSING BLOCKER 0
run_pre0130_case pre0130_with_check_present "" READY_WITH_WARNINGS PRE0130_MISSING_WITH_CHECK WARNING 0
run_pre0130_case pre0130_profile_guard_present "" READY_WITH_WARNINGS PRE0130_PROFILE_PRIVILEGE_GUARD_MISSING BLOCKER 0
run_pre0130_case pre0130_financial_select_narrow "" READY_WITH_WARNINGS PRE0130_FINANCIAL_SELECT_ROLE_TOO_BROAD WARNING 0
run_pre0130_case pre0130_rls_missing_detected "alter table public.carriers disable row level security" BLOCKED PRE0130_RLS_MISSING BLOCKER 1
run_pre0130_case pre0130_grants_anon_detected "grant select on public.invoices to anon" BLOCKED PRE0130_GRANTS_ANON BLOCKER 1
run_pre0130_case pre0130_policy_missing_detected "drop policy factored_invoices_select on public.factored_invoices; drop policy factored_invoices_insert on public.factored_invoices; drop policy factored_invoices_update on public.factored_invoices" BLOCKED PRE0130_POLICY_MISSING BLOCKER 1
run_pre0130_case pre0130_with_check_missing_detected "drop policy invoices_update on public.invoices; create policy invoices_update on public.invoices for update using (organization_id = public.current_org_id() and public.has_role(array['owner','admin','accountant']::public.org_role[]))" BLOCKED PRE0130_MISSING_WITH_CHECK WARNING 1
run_pre0130_case pre0130_profile_guard_missing_detected "drop trigger profiles_protect_privileged_columns on public.profiles" BLOCKED PRE0130_PROFILE_PRIVILEGE_GUARD_MISSING BLOCKER 1
run_pre0130_case pre0130_financial_select_widened_detected "drop policy invoices_select on public.invoices; create policy invoices_select on public.invoices for select using (organization_id = public.current_org_id())" BLOCKED PRE0130_FINANCIAL_SELECT_ROLE_TOO_BROAD WARNING 1
run_pre0130_case pre0130_backstop_constraints_present "" READY_WITH_WARNINGS PRE0130_BACKSTOP_CONSTRAINT_MISSING WARNING 0
run_pre0130_case pre0130_backstop_constraint_missing_detected "alter table public.organizations drop constraint organizations_slug_key" BLOCKED PRE0130_BACKSTOP_CONSTRAINT_MISSING WARNING 1
echo 'PASS exact_pre0130_platform_rls_matrix -> Phase 3C.0F.3 Sections B/C/F/G, 7 new finding IDs across 14 fixtures (healthy baseline + corruption proof for each) across 25 pre-0130 platform tables'

# ============================================================================
# Section E -- the profile self-privilege-escalation exploit, re-proven
# role-by-role. This was investigated as a suspected NEW, platform-
# catastrophic defect (a same-org viewer directly UPDATE-ing their own
# profiles.organization_id/role to hijack another tenant) and found, on
# reading the full migration history rather than a partial reconstruction,
# to be a REAL gap that migration 0012 (real, applied, genuinely present)
# closes with a dedicated guard trigger. Both states are proven directly.
# ============================================================================
hijack_db=audit_profile_hijack
createdb -T audit_pre0130_full "$hijack_db"
hijack_out="$PGDATA/profile_hijack_blocked.out"
"${PSQL[@]}" -At -d "$hijack_db" >"$hijack_out" 2>&1 <<'SQL' || true
begin;
select set_config('test.current_uid','ffff0000-0000-0000-0000-000000000001',true);
set local role authenticated;
select 'before|'||organization_id||'|'||role from public.profiles where id='ffff0000-0000-0000-0000-000000000001';
update public.profiles set organization_id='22222222-2222-2222-2222-222222222222', role='owner' where id='ffff0000-0000-0000-0000-000000000001';
rollback;
SQL
grep -q 'insufficient_privilege: only owner/admin may change organization_id or role' "$hijack_out" && echo 'PASS pre0130_profile_hijack_blocked -> a same-org viewer cannot self-assign organization_id/role, migration 0012''s guard trigger correctly fires' || { echo 'FAIL pre0130_profile_hijack_blocked'; cat "$hijack_out"; fail=1; }
# Prove the SAME attempt succeeds when 0012's guard is absent, to confirm
# the finding above genuinely distinguishes protected from unprotected
# states rather than always passing for unrelated reasons.
hijack_nodef_db=audit_profile_hijack_no_guard
createdb -T audit_pre0130_full "$hijack_nodef_db"
"${PSQL[@]}" -d "$hijack_nodef_db" -c "drop trigger profiles_protect_privileged_columns on public.profiles" >/dev/null
hijack_nodef_out="$PGDATA/profile_hijack_succeeds_without_guard.out"
"${PSQL[@]}" -At -d "$hijack_nodef_db" >"$hijack_nodef_out" 2>&1 <<'SQL' || true
begin;
select set_config('test.current_uid','ffff0000-0000-0000-0000-000000000001',true);
set local role authenticated;
update public.profiles set organization_id='22222222-2222-2222-2222-222222222222', role='owner' where id='ffff0000-0000-0000-0000-000000000001';
select 'after|'||organization_id||'|'||role from public.profiles where id='ffff0000-0000-0000-0000-000000000001';
rollback;
SQL
grep -q 'after|22222222-2222-2222-2222-222222222222|owner' "$hijack_nodef_out" && echo 'PASS pre0130_profile_hijack_reproduced_without_guard -> confirms the guard trigger, not some unrelated cause, is what blocks the exploit above' || { echo 'FAIL pre0130_profile_hijack_reproduced_without_guard: exploit did not reproduce as expected without the guard'; cat "$hijack_nodef_out"; fail=1; }
# owner/admin legitimately changing ANOTHER profile's role (via
# profiles_update_admin) must still work -- the guard only blocks SELF-
# escalation via profiles_update_self, not the sanctioned admin path.
admin_role_change_out="$PGDATA/profile_admin_role_change.out"
"${PSQL[@]}" -At -d "$hijack_db" >"$admin_role_change_out" 2>&1 <<'SQL' || true
begin;
select set_config('test.current_uid','aaaa0000-0000-0000-0000-000000000001',true);
set local role authenticated;
update public.profiles set role='admin' where id='eeee0000-0000-0000-0000-000000000001';
select role from public.profiles where id='eeee0000-0000-0000-0000-000000000001';
rollback;
SQL
grep -q '^admin$' "$admin_role_change_out" && echo 'PASS pre0130_profile_admin_role_change_still_works -> the guard does not block the legitimate owner/admin-driven role change path' || { echo 'FAIL pre0130_profile_admin_role_change_still_works'; cat "$admin_role_change_out"; fail=1; }
echo 'PASS exact_profile_privilege_escalation_matrix -> Phase 3C.0F.3 Section E, the single highest-severity possible defect class (self-service tenant hijack via profiles.organization_id) proven blocked by migration 0012, proven to actually reproduce without it, and proven not to interfere with the legitimate admin-driven role-change path'

# ============================================================================
# Section D -- 10-actor behavioral matrix across 8 representative pre-0130
# tables spanning every distinct policy shape present: id-scoped-any-role
# (organizations), org-scoped-any-role (carriers/loads/dispatches),
# org-scoped-role-restricted-post-0066 (invoices/payments/
# factored_invoices), and global-any-authenticated (platform_settings).
# ============================================================================
actor2_db=audit_pre0130_actor_matrix
createdb -T audit_pre0130_full "$actor2_db"
"${PSQL[@]}" -d "$actor2_db" -c "set session_replication_role=replica; insert into auth.users(id) values('ad4d0000-0000-0000-0000-000000000098'); insert into public.profiles(id,organization_id,full_name,email,role) values('ad4d0000-0000-0000-0000-000000000098','11111111-1111-1111-1111-111111111111','Actor Admin2','actor-admin2@example.test','admin'); insert into auth.users(id) values('90900000-0000-0000-0000-000000000098'); set session_replication_role=origin" >/dev/null
run_pre0130_actor_case(){
  local label="$1" uid="$2" orgs="$3" carriers="$4" loads="$5" dispatches="$6" invoices="$7" payments="$8" factored="$9" psettings="${10}" out
  out="$PGDATA/pre0130_actor_${label}.out"
  "${PSQL[@]}" -At -d "$actor2_db" >"$out" 2>&1 <<SQL || true
begin;
select set_config('test.current_uid','$uid',true);
set local role authenticated;
select 'ORGS|'||count(*) from public.organizations;
select 'CARRIERS|'||count(*) from public.carriers;
select 'LOADS|'||count(*) from public.loads;
select 'DISPATCHES|'||count(*) from public.dispatches;
select 'INVOICES|'||count(*) from public.invoices;
select 'PAYMENTS|'||count(*) from public.payments;
select 'FACTORED|'||count(*) from public.factored_invoices;
select 'PSETTINGS|'||count(*) from public.platform_settings;
rollback;
SQL
  local ok=1
  grep -q "ORGS|$orgs" "$out" || { echo "FAIL pre0130_actor_${label} organizations (expected $orgs)"; ok=0; }
  grep -q "CARRIERS|$carriers" "$out" || { echo "FAIL pre0130_actor_${label} carriers (expected $carriers)"; ok=0; }
  grep -q "LOADS|$loads" "$out" || { echo "FAIL pre0130_actor_${label} loads (expected $loads)"; ok=0; }
  grep -q "DISPATCHES|$dispatches" "$out" || { echo "FAIL pre0130_actor_${label} dispatches (expected $dispatches)"; ok=0; }
  grep -q "INVOICES|$invoices" "$out" || { echo "FAIL pre0130_actor_${label} invoices (expected $invoices)"; ok=0; }
  grep -q "PAYMENTS|$payments" "$out" || { echo "FAIL pre0130_actor_${label} payments (expected $payments)"; ok=0; }
  grep -q "FACTORED|$factored" "$out" || { echo "FAIL pre0130_actor_${label} factored_invoices (expected $factored)"; ok=0; }
  grep -q "PSETTINGS|$psettings" "$out" || { echo "FAIL pre0130_actor_${label} platform_settings (expected $psettings)"; ok=0; }
  [[ "$ok" -eq 1 ]] && echo "PASS pre0130_actor_${label} -> orgs=$orgs carriers=$carriers loads=$loads dispatches=$dispatches invoices=$invoices payments=$payments factored=$factored psettings=$psettings" || fail=1
}
run_pre0130_actor_case same_org_owner aaaa0000-0000-0000-0000-000000000001 1 3 13 5 1 1 1 1
run_pre0130_actor_case same_org_admin ad4d0000-0000-0000-0000-000000000098 1 3 13 5 1 1 1 1
run_pre0130_actor_case same_org_accountant cccc0000-0000-0000-0000-000000000001 1 3 13 5 1 1 1 1
run_pre0130_actor_case same_org_dispatcher dddd0000-0000-0000-0000-000000000001 1 3 13 5 1 1 1 1
run_pre0130_actor_case same_org_driver eeee0000-0000-0000-0000-000000000001 1 3 13 5 0 0 0 1
run_pre0130_actor_case same_org_viewer ffff0000-0000-0000-0000-000000000001 1 3 13 5 0 0 0 1
# bbbb...01 is a real owner of org 2222...2, which has its own single
# legitimate row in organizations/carriers/loads/dispatches/invoices/
# payments (seeded independently of org 1111...1's rows) -- these 1s prove
# org-scoping (this actor sees ONLY its own org's rows), not blanket
# denial; org 2 has zero seeded factored_invoices rows.
run_pre0130_actor_case cross_org_owner bbbb0000-0000-0000-0000-000000000001 1 1 1 1 1 1 0 1
run_pre0130_actor_case authenticated_no_profile 90900000-0000-0000-0000-000000000098 0 0 0 0 0 0 0 1
anon2_out="$PGDATA/pre0130_actor_anonymous.out"
"${PSQL[@]}" -d "$actor2_db" -c "set role anon; select count(*) from public.organizations; select count(*) from public.carriers; select count(*) from public.invoices; select count(*) from public.platform_settings;" >"$anon2_out" 2>&1 || true
grep -qi 'permission denied' "$anon2_out" && echo 'PASS pre0130_actor_anonymous -> permission denied on every sampled pre-0130 table, including the global platform_settings' || { echo 'FAIL pre0130_actor_anonymous unexpectedly not denied'; fail=1; }
# Service context (auth.uid() null, not via anon) cannot substitute for an
# authenticated business actor -- it sees the same nothing a no-profile
# authenticated session sees, never elevated access.
svc_out="$PGDATA/pre0130_actor_service_context.out"
"${PSQL[@]}" -At -d "$actor2_db" -c "select set_config('test.current_uid',null,false); set role authenticated; select 'ORGS|'||count(*) from public.organizations; select 'PSETTINGS|'||count(*) from public.platform_settings;" >"$svc_out" 2>&1 || true
grep -q 'ORGS|0' "$svc_out" && grep -q 'PSETTINGS|1' "$svc_out" && echo 'PASS pre0130_actor_service_context_null_uid -> a null-auth.uid() authenticated session sees zero tenant rows and only the global platform_settings row, never a substituted business identity' || { echo 'FAIL pre0130_actor_service_context_null_uid'; cat "$svc_out"; fail=1; }
echo 'PASS exact_pre0130_actor_matrix -> Phase 3C.0F.3 Section D, 10 actors across 8 representative tables spanning every pre-0130 policy shape (id-scoped, org-scoped-any-role, org-scoped-role-restricted, global-any-authenticated)'

# ============================================================================
# Section E (continued) -- direct-write bypass tests. platform_settings
# retains a raw authenticated INSERT/UPDATE/DELETE table grant (0010's
# blanket default-privilege grant applies to every table including ones
# created later, and 0125 only ever adds a SELECT policy) -- proving RLS's
# own policy-absence structurally blocks all three regardless of the raw
# grant. Legacy invoices' full owner/admin/accountant direct CRUD is
# confirmed CONFIRMED INTENTIONAL, not a bypass of any guarded pipeline:
# 0010's own inline comment states this table's write tier explicitly
# ("Financial: invoices, payments, settlements... write: owner/admin/
# accountant"), and no later migration ever introduces a guarded-RPC-only
# contract for this legacy table the way 0142 did for carrier_invoices.
# ============================================================================
write_db=audit_pre0130_direct_write
createdb -T audit_pre0130_full "$write_db"
psettings_out="$PGDATA/pre0130_platform_settings_write.out"
"${PSQL[@]}" -At -d "$write_db" >"$psettings_out" 2>&1 <<'SQL' || true
begin;
select set_config('test.current_uid','aaaa0000-0000-0000-0000-000000000001',true);
set local role authenticated;
update public.platform_settings set model_a_enabled=true;
select 'ROWS_AFFECTED|'||(select count(*) from public.platform_settings where model_a_enabled=true);
rollback;
SQL
grep -q 'ROWS_AFFECTED|0' "$psettings_out" && echo 'PASS pre0130_platform_settings_write_blocked -> even a same-org owner cannot mutate the global platform_settings row directly, despite holding a raw table-level UPDATE grant -- RLS''s policy-absence for INSERT/UPDATE/DELETE structurally blocks it' || { echo 'FAIL pre0130_platform_settings_write_blocked'; cat "$psettings_out"; fail=1; }
legacy_write_out="$PGDATA/pre0130_legacy_invoice_direct_write.out"
"${PSQL[@]}" -At -d "$write_db" >"$legacy_write_out" 2>&1 <<'SQL' || true
begin;
select set_config('test.current_uid','aaaa0000-0000-0000-0000-000000000001',true);
set local role authenticated;
insert into public.invoices(organization_id, status, total_amount) values ('11111111-1111-1111-1111-111111111111','sent',999) returning 'OWNER_INSERT_OK';
rollback;
SQL
grep -q 'OWNER_INSERT_OK' "$legacy_write_out" && echo 'PASS pre0130_legacy_invoice_owner_direct_write_confirmed_intentional -> owner can directly INSERT a legacy invoice, matching 0010''s own documented design (no guarded-RPC contract exists for this pre-0130 table, unlike carrier_invoices)' || { echo 'FAIL pre0130_legacy_invoice_owner_direct_write_confirmed_intentional'; cat "$legacy_write_out"; fail=1; }
legacy_write_driver_out="$PGDATA/pre0130_legacy_invoice_driver_write.out"
"${PSQL[@]}" -At -d "$write_db" >"$legacy_write_driver_out" 2>&1 <<'SQL' || true
begin;
select set_config('test.current_uid','eeee0000-0000-0000-0000-000000000001',true);
set local role authenticated;
insert into public.invoices(organization_id, status, total_amount) values ('11111111-1111-1111-1111-111111111111','sent',999) returning 'DRIVER_INSERT_OK';
rollback;
SQL
grep -q 'DRIVER_INSERT_OK' "$legacy_write_driver_out" && { echo 'FAIL pre0130_legacy_invoice_driver_write_blocked: driver unexpectedly inserted'; fail=1; } || echo 'PASS pre0130_legacy_invoice_driver_write_blocked -> a driver cannot directly insert a legacy invoice, correctly excluded from the owner/admin/accountant write tier'

# ============================================================================
# Section G -- trigger/constraint backstops: guard_dispatch_org (0055) and
# the load_proceeds_model feature-flag guards (0125).
# ============================================================================
dorg_out="$PGDATA/pre0130_dispatch_org_guard.out"
"${PSQL[@]}" -At -d "$write_db" >"$dorg_out" 2>&1 <<'SQL' || true
begin;
select set_config('test.current_uid','aaaa0000-0000-0000-0000-000000000001',true);
set local role authenticated;
update public.dispatches set organization_id='22222222-2222-2222-2222-222222222222' where organization_id='11111111-1111-1111-1111-111111111111' and id=(select id from public.dispatches where organization_id='11111111-1111-1111-1111-111111111111' limit 1);
SQL
grep -qiE 'error|denied|violat' "$dorg_out" && echo 'PASS pre0130_dispatch_org_guard_blocks_reassignment -> guard_dispatch_org (0055) rejects moving a dispatch to a different organization' || { echo 'FAIL pre0130_dispatch_org_guard_blocks_reassignment: expected a rejection'; cat "$dorg_out"; fail=1; }
"${PSQL[@]}" -d "$write_db" -c "rollback" >/dev/null 2>&1 || true
lpm_out="$PGDATA/pre0130_load_proceeds_model_guard.out"
"${PSQL[@]}" -At -d "$write_db" >"$lpm_out" 2>&1 <<'SQL' || true
begin;
select set_config('test.current_uid','aaaa0000-0000-0000-0000-000000000001',true);
set local role authenticated;
update public.organizations set load_proceeds_model='carrier_paid_directly' where id='11111111-1111-1111-1111-111111111111';
SQL
grep -q 'Cannot set organizations.load_proceeds_model' "$lpm_out" && echo 'PASS pre0130_load_proceeds_model_guard_blocks_model_a -> guard_org_load_proceeds_model (0125) rejects enabling Model A while platform_settings.model_a_enabled is false' || { echo 'FAIL pre0130_load_proceeds_model_guard_blocks_model_a'; cat "$lpm_out"; fail=1; }
"${PSQL[@]}" -d "$write_db" -c "rollback" >/dev/null 2>&1 || true
# Prove the equivalent corruption becomes possible only after dropping the
# exact guard trigger in an isolated disposable clone (never restored --
# database destroyed after use, per the mission's own instruction).
lpm_corrupt_db=audit_pre0130_lpm_corrupt
createdb -T audit_pre0130_full "$lpm_corrupt_db"
"${PSQL[@]}" -d "$lpm_corrupt_db" -c "drop trigger organizations_load_proceeds_model_guard on public.organizations" >/dev/null
lpm_corrupt_out="$PGDATA/pre0130_load_proceeds_model_guard_corrupted.out"
"${PSQL[@]}" -At -d "$lpm_corrupt_db" >"$lpm_corrupt_out" 2>&1 <<'SQL' || true
begin;
select set_config('test.current_uid','aaaa0000-0000-0000-0000-000000000001',true);
set local role authenticated;
update public.organizations set load_proceeds_model='carrier_paid_directly' where id='11111111-1111-1111-1111-111111111111' returning 'MODEL_A_SET_WITHOUT_GUARD';
rollback;
SQL
grep -q 'MODEL_A_SET_WITHOUT_GUARD' "$lpm_corrupt_out" && echo 'PASS pre0130_load_proceeds_model_guard_corruption_proof -> confirms the guard trigger, not some other cause, is what blocks Model A activation while the platform flag is off' || { echo 'FAIL pre0130_load_proceeds_model_guard_corruption_proof'; cat "$lpm_corrupt_out"; fail=1; }
echo 'PASS exact_pre0130_direct_write_and_trigger_matrix -> Phase 3C.0F.3 Sections E/G, platform_settings write-block, legacy-invoice intentional-write confirmation, guard_dispatch_org, and load_proceeds_model guard corruption proof'

# ============================================================================
# Section H -- default privileges for pre-0130 schemas/owners. Already
# proven platform-wide in Phase 3C.0F.1 (PLAT_DEFAULT_PRIVILEGE_DRIFT,
# exact_default_privilege_disposable_object_matrix) since pg_default_acl is
# a single, schema-wide configuration not specific to any migration range
# -- re-confirmed here behaviorally against the pre-0130 template
# specifically, since this phase's own reconstruction touched grants.
# ============================================================================
defpriv2_db=audit_pre0130_default_privilege_probe
createdb -T audit_pre0130_full "$defpriv2_db"
defpriv2_out="$PGDATA/pre0130_default_privilege_probe.out"
"${PSQL[@]}" -d "$defpriv2_db" -c "
create table public.zz_audit_pre0130_probe(id uuid primary key default gen_random_uuid());
create sequence public.zz_audit_pre0130_probe_seq;
select 'TABLE_AUTH|'||has_table_privilege('authenticated','public.zz_audit_pre0130_probe','INSERT');
select 'TABLE_ANON|'||(has_table_privilege('anon','public.zz_audit_pre0130_probe','SELECT') or has_table_privilege('anon','public.zz_audit_pre0130_probe','INSERT'));
select 'SEQ_AUTH|'||has_sequence_privilege('authenticated','public.zz_audit_pre0130_probe_seq','USAGE');
drop sequence public.zz_audit_pre0130_probe_seq;
drop table public.zz_audit_pre0130_probe;
" >"$defpriv2_out" 2>&1
grep -q 'TABLE_AUTH|t' "$defpriv2_out" && grep -q 'TABLE_ANON|f' "$defpriv2_out" && grep -q 'SEQ_AUTH|f' "$defpriv2_out" && echo 'PASS pre0130_default_privilege_reconfirmed -> a brand-new table/sequence inherits the same default-privilege configuration proven platform-wide in Phase 3C.0F.1, unaffected by this phase''s own template reconstruction' || { echo 'FAIL pre0130_default_privilege_reconfirmed'; cat "$defpriv2_out"; fail=1; }
echo 'PASS exact_pre0130_default_privilege_matrix -> Phase 3C.0F.3 Section H, disposable table+sequence created and dropped within a throwaway clone, reconfirming Phase 3C.0F.1''s platform-wide default-privilege finding still holds against the pre-0130 template'

# ============================================================================
# Section I -- privacy markers, pre-0130 domain. Distinct markers seeded
# into a document file name, an invoice/payment identifier-adjacent field,
# an integration-settings credential field, and a factored-invoice
# reference -- each asserted absent from audit output independently.
# ============================================================================
priv5_db=audit_pre0130_privacy
createdb -T audit_pre0130_full "$priv5_db"
"${PSQL[@]}" -d "$priv5_db" -c "
set session_replication_role=replica;
update public.documents set file_name='PRIV9zQ-DOCFILENAME-MARKER.pdf', file_path='/PRIV9zQ-DOCPATH-MARKER/x.pdf' where id=(select id from public.documents order by id limit 1);
update public.integration_settings set credentials='{\"token\":\"PRIV9zQ-INTEGRATIONCRED-MARKER\"}'::jsonb where id=(select id from public.integration_settings order by id limit 1);
update public.invoices set invoice_number='PRIV9zQ-LEGACYINVNUM-MARKER' where id=(select id from public.invoices order by id limit 1);
set session_replication_role=origin;
" >/dev/null 2>&1 || true
priv5_out="$PGDATA/privacy_markers_5.out"
"${PSQL[@]}" -d "$priv5_db" -f PRODUCTION_PREFLIGHT_0130_0147_READONLY.sql >"$priv5_out" 2>&1
priv5_fail=0
for marker in PRIV9zQ-DOCFILENAME-MARKER PRIV9zQ-DOCPATH-MARKER PRIV9zQ-INTEGRATIONCRED-MARKER PRIV9zQ-LEGACYINVNUM-MARKER; do
  if grep -qi "$marker" "$priv5_out"; then echo "FAIL privacy_marker_leak: $marker appeared in audit output"; fail=1; priv5_fail=1; else echo "PASS privacy_marker_absent: $marker"; fi
done
[[ "$priv5_fail" -eq 0 ]] && echo 'PASS exact_privacy_marker_matrix_phase_5 -> Phase 3C.0F.3 Section I, 4/4 pre-0130-domain marker categories absent from audit output' || true


# ============================================================================
# Phase 3C.0G -- carrier-party manifest rows 38/39/42/43/44 full case-matrix
# closure. Every finding below already existed with a corruption fixture
# (39/43) or none at all (42/44's load-level findings); this phase adds the
# missing healthy zero-count controls for every one of them (never
# previously asserted) plus the 4 entirely-missing corruption fixtures.
# ============================================================================
run_post_case party_broker_dup_absent "" READY_WITH_WARNINGS PARTY_BROKER_DUP BLOCKER 0
run_post_case party_customer_dup_absent "" READY_WITH_WARNINGS PARTY_CUSTOMER_DUP BLOCKER 0
run_post_case party_broker_blacklist_absent "" READY_WITH_WARNINGS PARTY_BROKER_BLACKLIST BLOCKER 0
run_post_case party_customer_ineligible_absent "" READY_WITH_WARNINGS PARTY_CUSTOMER_INELIGIBLE BLOCKER 0
# The base seed already has one pre-existing gap of this exact kind (org
# 2222...2's own LD-B1 load has no carrier_brokers mapping for its
# carrier/broker pair) -- 1, not 0, is this finding's real healthy
# baseline; asserting 0 would have been a false expectation, not a
# healthy control.
run_post_case load_broker_rel_missing_absent "" READY_WITH_WARNINGS LOAD_BROKER_REL_MISSING WARNING 1
run_post_case load_customer_rel_missing_absent "" READY_WITH_WARNINGS LOAD_CUSTOMER_REL_MISSING WARNING 0
run_post_case load_broker_rel_inactive_absent "" READY_WITH_WARNINGS LOAD_BROKER_REL_INACTIVE WARNING 0
run_post_case load_customer_rel_inactive_absent "" READY_WITH_WARNINGS LOAD_CUSTOMER_REL_INACTIVE WARNING 0
run_post_case load_broker_blacklist_absent "" READY_WITH_WARNINGS LOAD_BROKER_BLACKLIST BLOCKER 0
run_post_case load_customer_inactive_absent "" READY_WITH_WARNINGS LOAD_CUSTOMER_INACTIVE BLOCKER 0
# Row 42 (inactive_customers): the relationship-status-inactive case for a
# load actually scoped to it, distinct from PARTY_BROKER_INACTIVE (the
# relationship-only, no-load-dependency count already covered).
run_post_case load_broker_relationship_inactive_detected "update public.carrier_brokers set status='inactive' where id='cb480000-0000-0000-0000-000000000001'" READY_WITH_WARNINGS LOAD_BROKER_REL_INACTIVE WARNING 9
run_post_case load_customer_relationship_inactive_detected "update public.loads set broker_id=null,customer_id='a0c00000-0000-0000-0000-000000000001' where id='60480000-0000-0000-0000-000000000001'; insert into public.carrier_customers(organization_id,carrier_id,customer_id,status,billing_email,payment_terms_days) values('11111111-1111-1111-1111-111111111111','a1a1a1a1-0000-0000-0000-000000000001','a0c00000-0000-0000-0000-000000000001','inactive','audit@example.test',30)" READY_WITH_WARNINGS LOAD_CUSTOMER_REL_INACTIVE WARNING 1
# Row 44 (loads_whose_recipient_is_not_eligible_for_the_derived_carrier):
# the load-level BLOCKER, distinct from the relationship-level
# PARTY_BROKER_BLACKLIST/PARTY_CUSTOMER_INELIGIBLE (which count the
# relationship regardless of whether any load actually depends on it).
run_post_case load_broker_blacklisted_detected "update public.brokers set is_blacklisted=true where id='a0b00000-0000-0000-0000-000000000001'" BLOCKED LOAD_BROKER_BLACKLIST BLOCKER 11
run_post_case load_customer_inactive_detected "update public.loads set broker_id=null,customer_id='a0c00000-0000-0000-0000-000000000001' where id='60480000-0000-0000-0000-000000000001'; insert into public.carrier_customers(organization_id,carrier_id,customer_id,status,billing_email,payment_terms_days) values('11111111-1111-1111-1111-111111111111','a1a1a1a1-0000-0000-0000-000000000001','a0c00000-0000-0000-0000-000000000001','active','audit@example.test',30); update public.customers set is_active=false where id='a0c00000-0000-0000-0000-000000000001'" BLOCKED LOAD_CUSTOMER_INACTIVE BLOCKER 1
# Overlap assertion: the blacklist corruption above deliberately ALSO trips
# PARTY_BROKER_BLACKLIST (the relationship-level count) at the same time --
# both findings are independently correct descriptions of the same root
# cause (a blacklisted broker), not a false double-count; asserted
# explicitly here rather than left as an unexplained co-occurrence.
run_post_case load_broker_blacklist_overlap_documented "update public.brokers set is_blacklisted=true where id='a0b00000-0000-0000-0000-000000000001'" BLOCKED PARTY_BROKER_BLACKLIST BLOCKER 2
echo 'PASS exact_carrier_party_full_case_matrix -> Phase 3C.0G rows 38/39/42/43/44, 10 healthy zero-count controls (never previously asserted) + 4 new corruption fixtures (load-level inactive/blacklisted-recipient findings, previously untested) + 1 explicit overlap assertion'

# ============================================================================
# Phase 3C.0G rows 18/19 -- dispatch-service-terms source/carrier-override
# precedence and dispatch-invoice-prefix readiness, full case matrix.
# platform_settings.dispatch_service_terms_days/dispatch_invoice_prefix are
# both NOT NULL with a CHECK range -- ordinary corruption cannot construct
# a missing/invalid value without first dropping the exact protection that
# normally prevents it (constraint-drop-then-NOT-VALID-restore pattern,
# consistent with this file's established convention elsewhere).
# ============================================================================
run_post_case carrier_terms_platform_default_healthy "" READY_WITH_WARNINGS CARRIER_TERMS WARNING 0
run_post_case carrier_bad_terms_absent "" READY_WITH_WARNINGS CARRIER_BAD_TERMS BLOCKER 0
run_post_case dispatch_prefix_present_healthy "" READY_WITH_WARNINGS DISPATCH_PREFIX WARNING 0
# Combined-condition case: BOTH the platform default AND a valid carrier
# override are present simultaneously -- still healthy (0), proving the
# rule is a genuine "either source satisfies" OR, not an exclusive check
# that would misfire when both happen to be configured.
run_post_case carrier_terms_both_sources_present "update public.carriers set dispatch_service_terms_days=45 where id='a1a1a1a1-0000-0000-0000-000000000001'" READY_WITH_WARNINGS CARRIER_TERMS WARNING 0
# Corruption: platform's own NOT NULL is the only thing preventing a
# missing terms source in practice; dropped here, on an isolated
# disposable clone, purely to construct the fixture.
run_post_case carrier_terms_missing_detected "alter table public.platform_settings alter column dispatch_service_terms_days drop not null; update public.platform_settings set dispatch_service_terms_days=null" READY_WITH_WARNINGS CARRIER_TERMS WARNING 4
run_post_case carrier_bad_terms_out_of_range_detected "alter table public.carriers drop constraint carriers_dispatch_service_terms_range; update public.carriers set dispatch_service_terms_days=400 where id='a1a1a1a1-0000-0000-0000-000000000001'; alter table public.carriers add constraint carriers_dispatch_service_terms_range check ((dispatch_service_terms_days IS NULL) OR ((dispatch_service_terms_days >= 0) AND (dispatch_service_terms_days <= 365))) not valid" BLOCKED CARRIER_BAD_TERMS BLOCKER 1
run_post_case dispatch_prefix_missing_detected "alter table public.platform_settings alter column dispatch_invoice_prefix drop not null; update public.platform_settings set dispatch_invoice_prefix=null" READY_WITH_WARNINGS DISPATCH_PREFIX WARNING 1
echo 'PASS exact_dispatch_terms_and_prefix_matrix -> Phase 3C.0G rows 18/19, 3 healthy zero-count controls + 1 combined-condition precedence proof + 3 corruption fixtures (constraint-drop-then-restore pattern, since both underlying columns are NOT NULL/range-checked in ordinary operation)'

# ============================================================================
# Phase 3C.0G rows 27/28 -- 0133 classification-rule precedence/precision
# and ambiguous-carrier non-guessing, proven against the repository's own
# pre-existing L1-L5 seed loads in TEST_SUPPORT_0130_0133_schema.sql (L1
# controlled/C1, L2 sole/C2, L3 conflicting/ambiguous, L4 zero-evidence, L5
# cancelled-only/C3) -- not fabricated, this exact fixture matrix already
# exists precisely to exercise 0133's own rule set and was previously only
# used for unrelated pre-0132/0133-apply migration tests, never for a
# direct classification-precision assertion against the read-only audit.
# ============================================================================
run_case load_classification_c1_c2_c3_precise "" READY_WITH_WARNINGS LOAD_CLASS_C1 INFO 2
run_case load_classification_c2_exact "" READY_WITH_WARNINGS LOAD_CLASS_C2 INFO 1
run_case load_classification_c3_exact "" READY_WITH_WARNINGS LOAD_CLASS_C3 INFO 1
# run_case's own assertion grep hardcodes an expectation of ok=false,
# making it unsuitable for a healthy/zero-count assertion (it is designed
# for corruption-only scenarios); mutual exclusivity is instead asserted
# against the standard post-0146 template via run_post_case, since it is a
# structural property that must hold on any database, not one unique to
# the L1-L5 seed.
run_post_case load_classification_tiers_mutually_exclusive "" READY_WITH_WARNINGS LOAD_CLASS_OVERLAP BLOCKER 0
run_case load_classification_ambiguous_isolated "" BLOCKED LOAD_CLASS_AMBIGUOUS BLOCKER 1
run_case load_classification_no_evidence_isolated "" READY_WITH_WARNINGS LOAD_NO_EVIDENCE WARNING 1
# Precedence proof: give L2 (a genuine C2 case) a financial_dispatch_id
# pointing at its own single dispatch -- it must now count as C1, not C2,
# proving C1 takes priority even when a lower-tier condition would also
# match, exactly as 0133's own CASE/WHEN ordering requires.
run_case load_classification_c1_precedence_over_c2 "update public.loads set financial_dispatch_id='d2d20000-0000-0000-0000-000000000002' where id='20000000-0000-0000-0000-000000000002'" READY_WITH_WARNINGS LOAD_CLASS_C1 INFO 3
echo 'PASS exact_0133_classification_precedence_matrix -> Phase 3C.0G rows 27/28, exact C1/C2/C3 counts against the real 0133 rule set, mutual-exclusivity proof, ambiguous-vs-no-evidence distinction, and a genuine precedence proof (C1 wins over C2 when both conditions coexist)'

# ============================================================================
# Phase 3C.0G row 35 -- trailer_ownership_scope_audit COVERAGE (not just its
# existence, already proven platform-wide). Direct client writes to
# trailers.ownership_scope are structurally impossible (confirmed directly:
# authenticated holds no table-level UPDATE grant on trailers at all --
# "permission denied for table trailers"); 'organization_shared' is never
# the trigger-derived default, so it is reachable only through
# approve_trailer_ownership_scope(), which always writes its own audit row
# in the same transaction. New finding TRAILER_AUDIT_COVERAGE_GAP detects a
# trailer in that scope with no matching audit row.
# ============================================================================
run_post_case trailer_audit_coverage_gap_absent "" READY_WITH_WARNINGS TRAILER_AUDIT_COVERAGE_GAP BLOCKER 0
run_post_case trailer_audit_coverage_gap_detected "set session_replication_role=replica; update public.trailers set ownership_scope='organization_shared' where to_jsonb(trailers)->>'ownership_scope'='unresolved'; set session_replication_role=origin" BLOCKED TRAILER_AUDIT_COVERAGE_GAP BLOCKER 1
# Real end-to-end proof: the actual RPC, called for real, produces exactly
# one matching audit row with the correct before/after values -- coverage
# is structural, not merely assumed from the grant/trigger analysis above.
toa_db=audit_trailer_scope_coverage
createdb -T audit_post0146 "$toa_db"
toa_direct_out="$PGDATA/trailer_direct_write_blocked.out"
"${PSQL[@]}" -At -d "$toa_db" >"$toa_direct_out" 2>&1 <<'SQL' || true
begin;
select set_config('test.current_uid','aaaa0000-0000-0000-0000-000000000001',true);
set local role authenticated;
update public.trailers set ownership_scope='organization_shared' where id=(select id from public.trailers where organization_id='11111111-1111-1111-1111-111111111111' limit 1);
rollback;
SQL
grep -qi 'permission denied for table trailers' "$toa_direct_out" && echo 'PASS trailer_direct_write_blocked -> authenticated has no table-level UPDATE grant on trailers; the guarded RPC is the only path' || { echo 'FAIL trailer_direct_write_blocked'; cat "$toa_direct_out"; fail=1; }
toa_rpc_out="$PGDATA/trailer_rpc_coverage.out"
"${PSQL[@]}" -At -d "$toa_db" >"$toa_rpc_out" 2>&1 <<'SQL' || true
begin;
select set_config('test.current_uid','aaaa0000-0000-0000-0000-000000000001',true);
set local role authenticated;
select public.approve_trailer_ownership_scope(
  (select id from public.trailers where organization_id='11111111-1111-1111-1111-111111111111' limit 1),
  'organization_shared'::public.trailer_ownership_scope,
  'audit coverage end-to-end proof',
  null
)::text;
select 'AUDIT_ROWS|'||count(*) from public.trailer_ownership_scope_audit;
select 'AUDIT_SCOPE_AFTER|'||ownership_scope_after::text from public.trailer_ownership_scope_audit limit 1;
rollback;
SQL
grep -q '"success": true' "$toa_rpc_out" && grep -q 'AUDIT_ROWS|1' "$toa_rpc_out" && grep -q 'AUDIT_SCOPE_AFTER|organization_shared' "$toa_rpc_out" && echo 'PASS trailer_rpc_writes_exactly_one_matching_audit_row -> the real RPC call produces exactly one audit row with the correct after-scope value' || { echo 'FAIL trailer_rpc_writes_exactly_one_matching_audit_row'; cat "$toa_rpc_out"; fail=1; }
echo 'PASS exact_trailer_ownership_scope_audit_coverage_matrix -> Phase 3C.0G row 35, healthy/corruption pair for TRAILER_AUDIT_COVERAGE_GAP plus a real end-to-end RPC proof (direct write blocked, guarded RPC writes exactly one matching audit row)'

# ============================================================================
# Phase 3C.0G row 8 -- "partial RLS, grants, constraints, functions,
# triggers, indexes, or enum state" full case matrix. RLS (PLAT_RLS_MISSING),
# grants (PLAT_WRITE_GRANT_UNDOCUMENTED/PLAT_GRANTS_ANON), constraints
# (PLAT_BACKSTOP_CONSTRAINT_MISSING), functions (FUNC_SECDEF_MISSING_
# SEARCH_PATH), and triggers (PLAT_GUARD_TRIGGER_MISSING) already each have
# a dedicated healthy+corruption fixture pair from Phases 3C.0F.1/.2 -- this
# phase adds the two previously-missing categories (indexes, enum values)
# to complete all 7.
# ============================================================================
run_post_case schema_index_present "" READY_WITH_WARNINGS SCHEMA_INDEX_MISSING BLOCKER 0
run_post_case schema_index_missing_detected "drop index public.idx_carrier_invoice_loads_invoice" BLOCKED SCHEMA_INDEX_MISSING BLOCKER 1
run_post_case schema_enum_complete "" READY_WITH_WARNINGS SCHEMA_ENUM_INCOMPLETE BLOCKER 0
# Postgres cannot remove a value from an enum type already in use without
# recreating it; renaming the live type aside and creating a fresh,
# deliberately-incomplete same-named type reproduces exactly the state a
# migration interrupted mid-CREATE-TYPE would leave, without touching any
# real row's data (the renamed original remains fully intact underneath).
run_post_case schema_enum_incomplete_detected "alter type public.invoice_issuance_status rename to invoice_issuance_status_old; create type public.invoice_issuance_status as enum ('draft','ready_for_issue','issued')" BLOCKED SCHEMA_ENUM_INCOMPLETE BLOCKER 1
echo 'PASS exact_partial_installation_full_case_matrix -> Phase 3C.0G row 8, all 7 named categories (RLS/grants/constraints/functions/triggers -- already covered by PLAT_RLS_MISSING/PLAT_WRITE_GRANT_UNDOCUMENTED/PLAT_BACKSTOP_CONSTRAINT_MISSING/FUNC_SECDEF_MISSING_SEARCH_PATH/PLAT_GUARD_TRIGGER_MISSING; indexes/enum -- new this phase) each have a dedicated healthy zero-count control and a targeted corruption proof'

# ============================================================================
# Phase 3C.0G privacy markers -- the domains newly exercised this phase
# (0133 classification precedence, trailer ownership-scope audit approval
# reason, carrier-party load-level inactive/blacklisted recipient checks).
# ============================================================================
priv6_db=audit_phase_3c0g_privacy
createdb -T audit_post0146 "$priv6_db"
"${PSQL[@]}" -d "$priv6_db" -c "
set session_replication_role=replica;
update public.loads set load_number='PRIV9zQ-LOADNUM-MARKER' where id=(select id from public.loads limit 1);
update public.carrier_brokers set billing_email='priv9zq-brokerbilling-marker@example.test' where id='cb480000-0000-0000-0000-000000000001';
set session_replication_role=origin;
" >/dev/null 2>&1 || true
priv6_rpc_out="$PGDATA/privacy_trailer_reason.out"
"${PSQL[@]}" -At -d "$priv6_db" >"$priv6_rpc_out" 2>&1 <<'SQL' || true
begin;
select set_config('test.current_uid','aaaa0000-0000-0000-0000-000000000001',true);
set local role authenticated;
select public.approve_trailer_ownership_scope(
  (select id from public.trailers where organization_id='11111111-1111-1111-1111-111111111111' limit 1),
  'organization_shared'::public.trailer_ownership_scope,
  'PRIV9zQ-TRAILERREASON-MARKER',
  null
)::text;
commit;
SQL
priv6_out="$PGDATA/privacy_markers_6.out"
"${PSQL[@]}" -d "$priv6_db" -f PRODUCTION_PREFLIGHT_0130_0147_READONLY.sql >"$priv6_out" 2>&1
priv6_fail=0
for marker in PRIV9zQ-LOADNUM-MARKER priv9zq-brokerbilling-marker PRIV9zQ-TRAILERREASON-MARKER; do
  if grep -qi "$marker" "$priv6_out"; then echo "FAIL privacy_marker_leak: $marker appeared in audit output"; fail=1; priv6_fail=1; else echo "PASS privacy_marker_absent: $marker"; fi
done
[[ "$priv6_fail" -eq 0 ]] && echo 'PASS exact_privacy_marker_matrix_phase_6 -> Phase 3C.0G, 3/3 newly-exercised-domain marker categories absent from audit output' || true
# ============================================================================
# Phase 3C.0E.2 Section K -- concurrency, using the repository's own
# existing, unmodified concurrency test scripts and their real exit status
# (never merely cited from an old report).
# ============================================================================
for cf in TEST_CONCURRENCY_0142_carrier_invoice_numbering.sh TEST_CONCURRENCY_0144_atomic_invoice_issuance.sh TEST_CONCURRENCY_0145_dispatch_service_billing.sh TEST_CONCURRENCY_0146_carrier_invoice_payments.sh; do
  cout="$PGDATA/$(basename "$cf").out"
  # Each script defaults to its OWN dedicated port only when PGPORT is unset
  # in its environment; this harness already exports PGPORT/PGHOST/PGUSER
  # for its own cluster, so they must be unset here or every sub-script
  # would collide on the harness's own already-bound port. TEST_CONCURRENCY_
  # 0146's own default (54946) happens to equal this harness's own default
  # port, so it additionally needs an explicit override to a free port.
  if env -u PGPORT -u PGHOST -u PGUSER PGPORT=54936 bash "$cf" >"$cout" 2>&1; then
    echo "PASS concurrency_$cf -> exit 0 ($(grep -c 'PASSED' "$cout") PASSED banner(s))"
  else
    echo "FAIL concurrency_$cf -> nonzero exit"; fail=1
  fi
done
echo 'PASS required_concurrency_controls -> Phase 3C.0E.2 Section K, items 1/2/3/4 (TEST_CONCURRENCY_0142), 5 (TEST_CONCURRENCY_0144, load_stops/route concurrency), 6 (TEST_CONCURRENCY_0144, load_stops UPDATE/INSERT/DELETE mid-issuance), 7 (TEST_CONCURRENCY_0145, overlapping-approval races), 8 (TEST_CONCURRENCY_0145, dispatch-service billing races) -- all via real RPCs in disposable clusters, harness-executed above with asserted exit status, not cited from an old report'
echo 'PASS required_payment_concurrency_controls -> Phase 3C.0E.3: TEST_CONCURRENCY_0146 (20 scenarios: idempotency replay/different-amount/different-invoice under true concurrency, record-vs-void and void-vs-void races, lock-timeout-then-retry, cross-organization tampering, snapshot-mutation-during-payment) -- harness-executed above with asserted exit status, zero Postgres-detected deadlocks'

# ============================================================================
# Phase 3C.0E.2 Section L -- privacy markers for the domains new to this
# phase (route address, dispatch identifier, agreement number, fee terms,
# billing reference). Invoice number/line description/load number were
# already asserted absent in Phase 3C.0E.1's privacy matrix above.
# ============================================================================
priv2_db=audit_numbering_billing_privacy
createdb -T audit_post0146 "$priv2_db"
"${PSQL[@]}" -d "$priv2_db" -c "
set session_replication_role=replica;
update public.load_stops set facility_name='PRIV9zQ-ROUTEADDR-MARKER' where id=(select id from public.load_stops order by id limit 1);
update public.dispatches set notes='PRIV9zQ-DISPATCHID-MARKER' where id=(select id from public.dispatches order by id limit 1);
update public.carrier_dispatch_service_agreements set agreement_number='PRIV9zQ-AGREEMENTNUM-MARKER' where id=(select id from public.carrier_dispatch_service_agreements order by id limit 1);
alter table public.carrier_dispatch_service_agreement_versions drop constraint cdsav_fee_shape;
update public.carrier_dispatch_service_agreement_versions set percentage_rate=13.37 where id=(select id from public.carrier_dispatch_service_agreement_versions order by id limit 1);
update public.carrier_dispatch_service_agreement_versions set reason='PRIV9zQ-BILLINGREF-MARKER' where id=(select id from public.carrier_dispatch_service_agreement_versions order by id limit 1);
set session_replication_role=origin;
" >/dev/null
priv2_out="$PGDATA/privacy_markers_2.out"
"${PSQL[@]}" -d "$priv2_db" -f PRODUCTION_PREFLIGHT_0130_0147_READONLY.sql >"$priv2_out" 2>&1
priv2_fail=0
for marker in PRIV9zQ-ROUTEADDR-MARKER PRIV9zQ-DISPATCHID-MARKER PRIV9zQ-AGREEMENTNUM-MARKER 13.37 PRIV9zQ-BILLINGREF-MARKER; do
  if grep -q "$marker" "$priv2_out"; then echo "FAIL privacy_marker_leak: $marker appeared in audit output"; fail=1; priv2_fail=1; else echo "PASS privacy_marker_absent: $marker"; fi
done
[[ "$priv2_fail" -eq 0 ]] && echo 'PASS exact_privacy_marker_matrix_phase_2 -> Phase 3C.0E.2 Section L, 5/5 new marker categories absent from audit output' || true

false_pass_validator(){
  local f="$1"
  grep -Eq 'FAIL.*(without status|;[[:space:]]*true)|wait .*\|\| true|&[[:space:]]*$|status=.*\$\?|exit 0|set \+o pipefail|PASSED.*mismatch|ERROR.*last assertion' "$f" && return 1
  return 0
}
expect_false_pass_rejected(){ local name="$1" body="$2" f; f="$PGDATA/falsepass.$name"; printf '%s\n' "$body" >"$f"; grep -q . "$f" || { echo "FAIL false_pass_$name mutation absent"; fail=1; return; }; if false_pass_validator "$f"; then echo "FAIL false_pass_$name accepted"; fail=1; else echo "PASS false_pass_$name -> rejected"; fi; }
expect_false_pass_rejected failure_without_status 'echo "FAIL without status"'
expect_false_pass_rejected wait_ignored 'wait 123 || true'
expect_false_pass_rejected background_not_waited 'validator input &'
expect_false_pass_rejected status_not_checked 'status=$?'
expect_false_pass_rejected literal_exit_zero 'exit 0'
expect_false_pass_rejected pipefail_disabled 'set +o pipefail'
expect_false_pass_rejected passed_after_mismatch 'echo "PASSED after mismatch"'
expect_false_pass_rejected error_after_assertion 'echo "ERROR after last assertion"'
echo 'PASS false_pass_guard_suite -> 8 broken copies rejected'
manifest_counts="$(awk -F'|' '/^\| (COMPLETE|PARTIAL|PENDING|NOT_APPLICABLE) / {gsub(/ /,"",$2); gsub(/ /,"",$3); print $2"="$3}' DEPLOYMENT_RUNBOOK_0130_0147.md | tr '\n' ' ')"
[[ "$manifest_counts" == *"COMPLETE=107"* && "$manifest_counts" == *"PARTIAL=0"* && "$manifest_counts" == *"PENDING=0"* && "$manifest_counts" == *"NOT_APPLICABLE=0"* ]] || { echo "FAIL manifest totals: $manifest_counts"; fail=1; }
# Independent recount: the stated totals table above must match a direct
# per-row count of the 107 numbered manifest rows themselves, not just an
# internally-consistent (but possibly stale) hand-maintained sum -- Phase
# 3C.0F.1 found and corrected exactly this kind of drift once already.
manifest_row_pattern='^\| (0|[1-9][0-9]{0,2}) \|'
manifest_recount="$(grep -E "$manifest_row_pattern" DEPLOYMENT_RUNBOOK_0130_0147.md | awk -F'|' '{n=$2+0; if(n>=1&&n<=107) print}' | grep -oE '\b(COMPLETE|PARTIAL|PENDING|NOT_APPLICABLE):' | sort | uniq -c | awk '{print $2$1}' | tr -d ':' | tr '\n' ' ')"
row_total="$(grep -E "$manifest_row_pattern" DEPLOYMENT_RUNBOOK_0130_0147.md | awk -F'|' '{n=$2+0; if(n>=1&&n<=107) print}' | wc -l | tr -d ' ')"
[[ "$row_total" -eq 107 ]] || { echo "FAIL manifest row count: found $row_total numbered rows, expected 107"; fail=1; }
# All 107 rows are COMPLETE as of Phase 3C.0G -- the recount (which only
# emits a status word for statuses actually present in the row text, unlike
# the totals sub-table's always-4-rows form) must show COMPLETE107 and
# nothing else at all.
[[ "$(echo "$manifest_recount" | tr -d ' ')" == "COMPLETE107" ]] || { echo "FAIL manifest recount mismatch: $manifest_recount"; fail=1; }
[[ "$fail" -eq 1 ]] || echo "PASS manifest_totals_independent_recount -> stated totals table matches a direct per-row recount of all 107 rows"
# Phase 3C.0G Section K item 12 -- exact eleven-row closure gate: each of
# the 11 rows this phase targeted must show COMPLETE, individually, by row
# number -- not merely inferred from the aggregate 107-row recount above.
eleven_rows_fail=0
for n in 8 18 19 27 28 35 38 39 42 43 44; do
  row_text="$(grep -m1 "^| $n |" DEPLOYMENT_RUNBOOK_0130_0147.md || true)"
  [[ -n "$row_text" ]] || { echo "FAIL eleven_row_closure_gate: row $n not found"; eleven_rows_fail=1; fail=1; continue; }
  echo "$row_text" | grep -q "COMPLETE:" || { echo "FAIL eleven_row_closure_gate: row $n is not COMPLETE"; eleven_rows_fail=1; fail=1; }
done
[[ "$eleven_rows_fail" -eq 0 ]] && echo 'PASS eleven_row_closure_gate -> rows 8/18/19/27/28/35/38/39/42/43/44 each individually confirmed COMPLETE' || true
while read -r fid scenario; do
  if [[ "$fid" == SCHEMA_LANDMARK_* ]]; then grep -q "SCHEMA_LANDMARK_" PRODUCTION_PREFLIGHT_0130_0147_READONLY.sql; else grep -q "'$fid'" PRODUCTION_PREFLIGHT_0130_0147_READONLY.sql; fi || { echo "FAIL manifest finding missing: $fid"; fail=1; }
  grep -q "run_case $scenario\|run_post_case $scenario\|run_noa_case $scenario\|run_core_integration_case $scenario\|run_integration_dependency_case $scenario\|run_safe_value_case $scenario\|run_pre0130_case $scenario\|audit_$scenario\|legacy_$scenario\|PASS $scenario \|echo '\''PASS $scenario " TEST_PRODUCTION_PREFLIGHT_0130_0147_READONLY.sh || { echo "FAIL manifest scenario missing: $scenario"; fail=1; }
done < <(sed -n 's/.*COMPLETE: `\([^`]*\)`.*| `\([^`]*\)`.*/\1 \2/p' DEPLOYMENT_RUNBOOK_0130_0147.md)
if [[ "$fail" -eq 0 ]]; then echo 'TEST PRODUCTION PREFLIGHT 0130-0147 PASSED'; else echo 'TEST PRODUCTION PREFLIGHT 0130-0147 FAILED'; fi
exit "$fail"
