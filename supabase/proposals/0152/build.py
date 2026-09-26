#!/usr/bin/env python3
"""Proposal 0152 generator. NOT APPROVED FOR PRODUCTION.

Repairs the idempotency-replay defect class (authorization / request binding must precede or accompany any replay) in eight RPCs and
removes service_role EXECUTE from three internal-only SECURITY DEFINER helpers. Every repaired function is derived from the
AUTHORITATIVE migration text of its last definition by anchored, asserted edits, so each semantic diff is exactly the edits below.

    python3 build.py           # (re)write the generated files
    python3 build.py --check   # exit 1 if any generated file is stale
"""
import difflib
import glob
import hashlib
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
SUPA = HERE.parents[1]
MIG = SUPA / "migrations"

FUNCS = [  # (name, signature, defining migration prefix)
    ("reassign_dispatch_resources", "public.reassign_dispatch_resources(uuid,uuid,uuid,uuid,text,text,timestamptz)", "0135"),
    ("set_carrier_factoring_policy", "public.set_carrier_factoring_policy(uuid,public.carrier_factoring_mode,text,timestamptz,text)", "0139"),
    ("configure_carrier_factoring_integration", "public.configure_carrier_factoring_integration(uuid,text,text,public.integration_provider,text,text,timestamptz,text)", "0141"),
    ("rotate_carrier_factoring_integration", "public.rotate_carrier_factoring_integration(uuid,text,text,public.integration_provider,text,text,timestamptz,text)", "0141"),
    ("transition_carrier_factoring_integration_lifecycle", "public.transition_carrier_factoring_integration_lifecycle(text,uuid,text,timestamptz,text)", "0141"),
    ("deactivate_factoring_relationship", "public.deactivate_factoring_relationship(uuid,text,timestamptz,text,boolean)", "0141"),
    ("review_legacy_invoice_carrier_migration", "public.review_legacy_invoice_carrier_migration(uuid,text,text,timestamptz,text)", "0142"),
    ("update_carrier_invoice_draft", "public.update_carrier_invoice_draft(uuid,jsonb,timestamptz,text,text)", "0143"),
]
HELPERS = [  # internal-only SECURITY DEFINER helpers: no client role, and not service_role, may execute them directly
    "public._issue_dispatch_service_invoice_internal(uuid, public.carrier_invoices, uuid, uuid, text, text, text, integer, text)",
    "public.transition_carrier_factoring_integration_lifecycle(text, uuid, text, timestamptz, text)",
    "public._generate_carrier_invoice_payment_number_internal()",
]
LEDGER_COLUMNS = [("public.factoring_policy_idempotency", "0139"), ("public.factoring_integration_lifecycle_idempotency", "0141")]
FPFN = "public.compute_financial_request_fingerprint(jsonb)"


def norm(body):
    return re.sub(r"\s+", "", re.sub(r"--[^\n]*", "", body).lower())


def md5(s):
    return hashlib.md5(s.encode()).hexdigest()


def q(s):
    return "'" + s.replace("'", "''") + "'"


def extract(name, prefix):
    """The LAST 'create [or replace] function public.<name>(' block in the migrations, which must live in `prefix`."""
    found = None
    for f in sorted(MIG.glob("01[0-4]*.sql")) + sorted(MIG.glob("0135*.sql")):
        t = f.read_text()
        for m in re.finditer(r"create (?:or replace )?function public\.%s\(" % re.escape(name), t, re.I):
            a = m.start()
            tag = re.search(r"\bas\s+(\$\w*\$)", t[a:]).group(1)
            i = t.index(tag, a + t[a:].index(tag) + len(tag))
            blk = t[a:i + len(tag)] + ";"
            if found is None or f.name >= found[0]:
                found = (f.name, blk)
    assert found and found[0].startswith(prefix), (name, found and found[0])
    blk = found[1]
    return re.sub(r"^create function", "create or replace function", blk, flags=re.I)


def body_of(blk):
    tag = re.search(r"\bas\s+(\$\w*\$)", blk).group(1)
    return blk.split(tag)[1]


def sub(blk, old, new, count=1):
    assert blk.count(old) == count, (blk.count(old), old[:90])
    return blk.replace(old, new)


def fp_payload(op, target_name, target_expr, params):
    items = [f"'operation', '{op}'", "'schema_version', 1", "'organization_id', v_org", f"'{target_name}', {target_expr}"] + params
    return "public.compute_financial_request_fingerprint(jsonb_build_object(\n      " + ",\n      ".join(items) + "\n    ))"


EXP = "'expected_updated_at', to_char(p_expected_updated_at at time zone 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS.US\"Z\"')"

MISMATCH_JSON = "return jsonb_build_object('success', false, 'code', 'IDEMPOTENCY_KEY_REUSED', 'message', 'This idempotency key was already used for a different request.');"


# ------------------------------------------------------------------ per-function edits
def edit_reassign(blk):
    blk = sub(blk, "  v_cached jsonb;\n", "  v_cached jsonb;\n  v_c_driver uuid;\n  v_c_truck uuid;\n  v_c_trailer uuid;\n  v_c_reason text;\n")

    def replay(where):
        return f"""  if p_idempotency_key is not null then
    select r.result, r.new_driver_id, r.new_truck_id, r.new_trailer_id, r.reason
      into v_cached, v_c_driver, v_c_truck, v_c_trailer, v_c_reason
    from public.dispatch_resource_reassignments r
    where r.dispatch_id = p_dispatch_id and r.idempotency_key = p_idempotency_key and r.organization_id = v_org;
    if found then
      -- ({where}) the key is bound to the ORIGINAL request (driver, truck, trailer, reason as recorded in the ledger row).
      if (v_c_driver, v_c_truck, v_c_trailer, v_c_reason) is distinct from (p_driver_id, p_truck_id, p_trailer_id, p_reason) then
        raise exception 'reassign_dispatch_resources: this idempotency key was already used for a different request.' using errcode = 'RRIDK';
      end if;
      return v_cached || jsonb_build_object('idempotent_replay', true);
    end if;
  end if;
"""
    s = blk.index("  -- Idempotency short-circuit -- BEFORE any lock, any validation, any")
    e = blk.index("  -- ===== STEP 1: LOCK THE LOAD FIRST")
    old = blk[s:e]
    assert "from public.dispatch_resource_reassignments" in old and "RRDNF" in old
    new = """  -- 0152: the target dispatch is resolved and verified to belong to the caller's organization (else the SAME RRDNF a missing dispatch
  -- gets) BEFORE the ledger is read. The role gate above already precedes this point.
  select organization_id, load_id into v_dispatch_org, v_load_id
  from public.dispatches where id = p_dispatch_id;
  if v_dispatch_org is null or v_dispatch_org <> v_org then
    raise exception 'reassign_dispatch_resources: dispatch % not found.', p_dispatch_id using errcode = 'RRDNF';
  end if;

  -- Idempotency short-circuit -- AFTER authorization, BEFORE any lock, validation or write; organization-scoped and request-bound.
""" + replay("pre-lock") + "\n"
    blk = blk[:s] + new + blk[e:]
    a4 = "  from public.dispatches where id = p_dispatch_id for update;\n"
    assert blk.count(a4) == 1
    blk = blk.replace(a4, a4 + "\n  -- 0152: re-check the ledger UNDER the load+dispatch locks so a concurrent duplicate replays the winner's committed result.\n" + replay("post-lock"))
    return blk


def edit_policy(blk):
    blk = sub(blk, "  v_cached jsonb;\n", "  v_cached jsonb;\n  v_cached_fp text;\n  v_fp text;\n  v_carrier_org uuid;\n")

    def replay(where):
        return f"""  if p_idempotency_key is not null then
    select result, request_fingerprint into v_cached, v_cached_fp from public.factoring_policy_idempotency
      where carrier_id = p_carrier_id and idempotency_key = p_idempotency_key and organization_id = v_org;
    if found then
      -- ({where}) request-bound; fails CLOSED: a NULL or different fingerprint is never replayed (the column is NOT NULL, this is defence in depth).
      if v_cached_fp is distinct from v_fp then
        raise exception 'set_carrier_factoring_policy: this idempotency key was already used for a different request.' using errcode = 'FPIDK';
      end if;
      return v_cached || jsonb_build_object('idempotent_replay', true);
    end if;
  end if;
"""
    old = """  if p_idempotency_key is not null then
    select result into v_cached from public.factoring_policy_idempotency
      where carrier_id = p_carrier_id and idempotency_key = p_idempotency_key;
    if found then
      return v_cached || jsonb_build_object('idempotent_replay', true);
    end if;
  end if;
"""
    new = """  -- 0152: the target carrier must belong to the caller's organization (else the SAME FPDNF a missing carrier gets) BEFORE the ledger is read.
  select organization_id into v_carrier_org from public.carriers where id = p_carrier_id;
  if v_carrier_org is null or v_carrier_org <> v_org then
    raise exception 'set_carrier_factoring_policy: carrier not found.' using errcode = 'FPDNF';
  end if;
  v_fp := """ + fp_payload("set_carrier_factoring_policy", "carrier_id", "p_carrier_id", ["'mode', p_mode", "'reason', nullif(btrim(coalesce(p_reason, '')), '')"]) + ";\n" + replay("pre-lock")
    blk = sub(blk, old, new)
    a4 = "  from public.carriers where id = p_carrier_id for update;\n"
    assert blk.count(a4) == 1
    blk = blk.replace(a4, a4 + "\n  -- 0152: re-check the ledger UNDER the advisory + row locks so a concurrent duplicate replays the winner's committed result.\n" + replay("post-lock"))
    old_ins = """    insert into public.factoring_policy_idempotency (organization_id, carrier_id, idempotency_key, result)
    values (v_org, p_carrier_id, p_idempotency_key, v_readiness)"""
    blk = sub(blk, old_ins, """    insert into public.factoring_policy_idempotency (organization_id, carrier_id, idempotency_key, result, request_fingerprint)
    values (v_org, p_carrier_id, p_idempotency_key, v_readiness, v_fp)""")
    return blk


def edit_lifecycle_family(blk, action_expr, target_name, target_param, params, extra_decl=""):
    """0141 RPCs: authentication, organization + owner/admin role and the organization-scoped target check ALREADY precede the ledger
    read; what is missing is request binding. Adds a fingerprint (stored in a new NOT NULL column) and compares it on replay."""
    blk = sub(blk, "  v_cached public.factoring_integration_lifecycle_idempotency%rowtype;\n",
              "  v_cached public.factoring_integration_lifecycle_idempotency%rowtype;\n  v_fp text;\n")
    m = re.search(r"  select \* into v_cached from public\.factoring_integration_lifecycle_idempotency\n    where action = [^\n]*\n  if found then\n    return v_cached\.result \|\| jsonb_build_object\('idempotent_replay', true\);\n  end if;\n", blk)
    assert m, "lifecycle replay block"
    old = m.group(0)
    where_line = re.search(r"    where action = ([^\n]*)\n", old).group(1)
    new = f"""  -- 0152: request binding. The organization-scoped target lookup and the owner/admin gate above already precede this read.
  v_fp := {fp_payload(action_expr[0], target_name, target_param, params)};
  select * into v_cached from public.factoring_integration_lifecycle_idempotency
    where action = {where_line}
  if found then
    if v_cached.request_fingerprint is distinct from v_fp then
      {MISMATCH_JSON}
    end if;
    return v_cached.result || jsonb_build_object('idempotent_replay', true);
  end if;
"""
    blk = blk.replace(old, new)
    m = re.search(r"  insert into public\.factoring_integration_lifecycle_idempotency \(organization_id, action, target_id, idempotency_key, result\)\n  values \(([^;]*)\);\n", blk)
    assert m, "lifecycle insert"
    blk = blk.replace(m.group(0), f"  insert into public.factoring_integration_lifecycle_idempotency (organization_id, action, target_id, idempotency_key, result, request_fingerprint)\n  values ({m.group(1)}, v_fp);\n")
    return blk


def edit_configure(blk):
    return edit_lifecycle_family(blk, ("configure_carrier_factoring_integration",), "relationship_id", "p_relationship_id",
                                 ["'secret_reference', p_secret_reference", "'external_account_identifier', p_external_account_identifier", "'provider', p_provider",
                                  "'submission_destination', p_submission_destination", "'reason', nullif(btrim(coalesce(p_reason, '')), '')"])


def edit_rotate(blk):
    return edit_lifecycle_family(blk, ("rotate_carrier_factoring_integration",), "integration_id", "p_integration_id",
                                 ["'secret_reference', p_secret_reference", "'external_account_identifier', p_external_account_identifier", "'provider', p_provider",
                                  "'submission_destination', p_submission_destination", "'reason', nullif(btrim(coalesce(p_reason, '')), '')"])


def edit_transition(blk):
    return edit_lifecycle_family(blk, ("transition_carrier_factoring_integration_lifecycle",), "integration_id", "p_integration_id",
                                 ["'action', p_action", "'reason', nullif(btrim(coalesce(p_reason, '')), '')"])


def edit_deactivate_rel(blk):
    return edit_lifecycle_family(blk, ("deactivate_factoring_relationship",), "relationship_id", "p_relationship_id",
                                 ["'coordinated', coalesce(p_coordinated, false)", "'reason', nullif(btrim(coalesce(p_reason, '')), '')"])


def edit_review(blk):
    """0142 review_legacy_invoice_carrier_migration: the replay lookup ran BEFORE the role gate and was unbound. Now: role gate first
    (unchanged position relative to validation), and the replay decision is taken AFTER the row lock + organization-verified target
    check, bound to the review row itself (review id, resolution, notes)."""
    old_lookup = """  select result into v_cached from public.legacy_invoice_review_idempotency
  where organization_id = v_org and idempotency_key = p_idempotency_key;
  if v_cached is not null then
    return v_cached;
  end if;

"""
    blk = sub(blk, old_lookup, "")
    blk = sub(blk, "  v_cached jsonb;\n", "  v_cached jsonb;\n  v_cached_review uuid;\n")
    blk = sub(blk, "  select id, organization_id, legacy_invoice_id, updated_at into v_row\n", "  select id, organization_id, legacy_invoice_id, updated_at, resolution, review_notes into v_row\n")
    anchor = """  if v_row.updated_at <> p_expected_updated_at then"""
    new = """  -- 0152: replay decision AFTER the role gate, the row lock and the organization-verified target check. Bound to the review row itself:
  -- the key must have been used for THIS review, with the same resolution and notes (the row still holds the originals).
  select result, review_id into v_cached, v_cached_review from public.legacy_invoice_review_idempotency
  where organization_id = v_org and idempotency_key = p_idempotency_key;
  if v_cached is not null then
    if v_cached_review is distinct from p_review_id or v_row.resolution is distinct from btrim(p_resolution) or v_row.review_notes is distinct from p_notes then
      return jsonb_build_object('success', false, 'code', 'IDEMPOTENCY_KEY_REUSED', 'message', 'This idempotency key was already used for a different request.');
    end if;
    return v_cached;
  end if;

"""
    return sub(blk, anchor, new + anchor)


def edit_update_draft(blk):
    """0143 update_carrier_invoice_draft: the org-verified, fingerprint-bound replay ran BEFORE the role/field-permission gate. The gate is
    now re-applied AT REPLAY (first-call error precedence is untouched)."""
    old = """  if v_cached_result is not null then
    if v_cached_fingerprint <> v_fingerprint then"""
    new = """  if v_cached_result is not null then
    -- 0152: a replay requires CURRENT authorization exactly as performing the edit does (role, and the fields this role may edit).
    if public.has_role(array['owner', 'admin']::public.org_role[]) then
      v_role_keys := array['notes', 'due_date', 'payment_terms_days', 'broker_id', 'customer_id', 'currency'];
    elsif public.has_role(array['accountant']::public.org_role[]) then
      v_role_keys := array['notes', 'due_date', 'payment_terms_days', 'currency'];
    elsif public.has_role(array['dispatcher']::public.org_role[]) then
      v_role_keys := array['notes'];
    else
      return jsonb_build_object('success', false, 'code', 'FORBIDDEN', 'message', 'You do not have permission to edit this invoice.');
    end if;
    if not (v_patch_keys <@ v_role_keys) then
      return jsonb_build_object('success', false, 'code', 'FORBIDDEN', 'message', 'One or more fields in this patch are not permitted for your role.');
    end if;
    if v_cached_fingerprint <> v_fingerprint then"""
    assert blk.count(old) == 1, blk.count(old)
    return blk.replace(old, new)


EDITORS = {
    "reassign_dispatch_resources": edit_reassign,
    "set_carrier_factoring_policy": edit_policy,
    "configure_carrier_factoring_integration": edit_configure,
    "rotate_carrier_factoring_integration": edit_rotate,
    "transition_carrier_factoring_integration_lifecycle": edit_transition,
    "deactivate_factoring_relationship": edit_deactivate_rel,
    "review_legacy_invoice_carrier_migration": edit_review,
    "update_carrier_invoice_draft": edit_update_draft,
}


def blocks():
    out = {}
    for name, sig, prefix in FUNCS:
        old = extract(name, prefix)
        new = EDITORS[name](old)
        assert new != old
        out[name] = (sig, old, new)
    return out


# ------------------------------------------------------------------ SQL generation
def hdr(title):
    return f"""-- =============================================================================
-- {title}
-- PROPOSAL 0152 -- NOT APPROVED FOR PRODUCTION. NOT APPLIED. NOT A PRODUCTION MIGRATION (lives under supabase/proposals/, not supabase/migrations/).
-- Sequencing: 0130..0147 -> 0149 -> 0150 -> 0151 -> 0152 (this). Current proposal 0148 is unrelated and MUST be
-- renumbered to 0153 or higher before promotion."""


def md5expr(sig):
    return f"(select md5(regexp_replace(lower(regexp_replace(prosrc, '--[^\\n]*', '', 'g')), '\\s+', '', 'g')) from pg_proc where oid = to_regprocedure({q(sig)}))"


def proposed():
    B = blocks()
    fn_sql = "\n\n".join(B[n][2] for n, _, _ in FUNCS)
    olds = ",\n".join(f"    ({q(sig)}, {q(md5(norm(body_of(B[n][1]))))})" for n, sig, _ in FUNCS)
    news = ",\n".join(f"    ({q(sig)}, {q(md5(norm(body_of(B[n][2]))))})" for n, sig, _ in FUNCS)
    helpers = ", ".join(q(h) for h in HELPERS)
    revokes = "\n".join(f"revoke all on function {h} from public, anon, authenticated, service_role;" for h in HELPERS)
    return f"""{hdr("proposed_0152.sql -- authorize before replay + bind replay to the original request (8 RPCs) + internal-helper privilege hardening")}
--
-- DEFECT CLASS. An idempotency ledger was read (and its cached result returned) before one or more of: current role, target-organization
-- ownership, request binding. Confirmed by proposals/0152/defect_repro.sql on the real 0135/0139/0141/0142/0143 functions (see AUDIT.md).
-- REPAIRED (function bodies only; signatures, SECURITY DEFINER, search_path, owner, ACL, comments unchanged):
--   reassign_dispatch_resources (0135), set_carrier_factoring_policy (0139), configure_/rotate_carrier_factoring_integration,
--   transition_carrier_factoring_integration_lifecycle, deactivate_factoring_relationship (0141), review_legacy_invoice_carrier_migration (0142),
--   update_carrier_invoice_draft (0143).  transition_dispatch_status is repaired by proposal 0151 (not repeated here).
-- SCHEMA (necessary, minimal): one NOT NULL column  request_fingerprint text  on factoring_policy_idempotency (0139) and
--   factoring_integration_lifecycle_idempotency (0141) -- neither ledger stores the request, so request binding is otherwise impossible.
--   ZERO-ROW INVARIANT: both ledgers are introduced by 0139/0141 in the same maintenance window and must still be EMPTY here; the migration takes
--   ACCESS EXCLUSIVE locks on both, re-counts under the locks and ABORTS WITHOUT CHANGES if either holds a row (no fingerprint is ever fabricated).
--   (0135's ledger already stores driver/truck/trailer/reason; 0142's review row and 0143's ledger already bind; no other table changes.)
-- PRIVILEGES: EXECUTE revoked from service_role (and public/anon/authenticated) on three internal-only SECURITY DEFINER helpers. The owner keeps
--   implicit EXECUTE, so the approved callers (which share the owner) keep working. Supabase grants EXECUTE on new functions to service_role by default.
-- STABLE MISMATCH CODES: jsonb-returning RPCs -> code IDEMPOTENCY_KEY_REUSED (the existing 0143+ code); raising RPCs -> RRIDK (reassign), FPIDK (policy).
-- POLICY: actor is NOT bound; a different CURRENT authorized owner/admin (dispatcher for reassign) may replay organization-owned operations.
-- =============================================================================
begin;
-- LOCK ORDER (fixed, documented; the only place these two locks are taken together): 1) factoring_policy_idempotency, 2) factoring_integration_lifecycle_idempotency,
-- acquired left-to-right by ONE LOCK TABLE statement. No RPC or migration takes them in any other order (each repaired RPC writes at most ONE of the two ledgers per
-- transaction). A bounded wait turns any unexpected contention into a clean abort (nothing changed) instead of an indefinite hang in the maintenance window.
set local lock_timeout = '15s';

-- ======================= PHASE 1 -- PRECONDITIONS ==============================
do $mig$
declare
  r record;
  v_md5 text;
begin
  for r in select * from (values
{olds}
  ) as t(sig, body_md5) loop
    if to_regprocedure(r.sig) is null then raise exception '0152 precondition: % missing. STOP.', r.sig; end if;
    select md5(regexp_replace(lower(regexp_replace(prosrc, '--[^\\n]*', '', 'g')), '\\s+', '', 'g')) into v_md5 from pg_proc where oid = to_regprocedure(r.sig);
    if v_md5 is distinct from r.body_md5 then raise exception '0152 precondition: live % is not the reviewed baseline definition (md5 %) -- already repaired, or drifted. STOP.', r.sig, v_md5; end if;
    if not (select p.prosecdef and p.proconfig::text = '{{"search_path=pg_catalog, public"}}' from pg_proc p where p.oid = to_regprocedure(r.sig)) then
      raise exception '0152 precondition: % is not SECURITY DEFINER with the pinned search_path. STOP.', r.sig;
    end if;
  end loop;
  -- 0151 must already be applied (transition_dispatch_status authorizes before replay): 0152 continues the same defect class.
  if position('tsidk' in (select regexp_replace(lower(prosrc), '\\s+', '', 'g') from pg_proc where oid = to_regprocedure('public.transition_dispatch_status(uuid,public.dispatch_status,text,text)'))) = 0 then
    raise exception '0152 precondition: proposal 0151 is not applied. STOP.';
  end if;
  if to_regprocedure({q(FPFN)}) is null then raise exception '0152 precondition: compute_financial_request_fingerprint(jsonb) missing (0143). STOP.'; end if;
  if to_regclass('public.factoring_policy_idempotency') is null or to_regclass('public.factoring_integration_lifecycle_idempotency') is null
     or to_regclass('public.dispatch_resource_reassignments') is null or to_regclass('public.legacy_invoice_review_idempotency') is null
     or to_regclass('public.carrier_invoice_lifecycle_idempotency') is null then
    raise exception '0152 precondition: a ledger table is missing. STOP.';
  end if;
  if exists (select 1 from information_schema.columns where table_schema = 'public' and column_name = 'request_fingerprint'
             and table_name in ('factoring_policy_idempotency', 'factoring_integration_lifecycle_idempotency')) then
    raise exception '0152 precondition: request_fingerprint already exists -- already applied? STOP.';
  end if;
  -- ZERO-ROW INVARIANT, checked UNDER exclusive locks (no concurrent writer can slip a row in before the ALTERs commit). Independent of preflight.sql.
  lock table public.factoring_policy_idempotency, public.factoring_integration_lifecycle_idempotency in access exclusive mode;   -- fixed order: policy ledger, then lifecycle ledger
  if (select count(*) from public.factoring_policy_idempotency) <> 0 then
    raise exception '0152 precondition: factoring_policy_idempotency is NOT empty (% row(s)); fingerprints cannot be derived for existing rows and a NULL fingerprint must never replay. STOP -- nothing was changed.', (select count(*) from public.factoring_policy_idempotency);
  end if;
  if (select count(*) from public.factoring_integration_lifecycle_idempotency) <> 0 then
    raise exception '0152 precondition: factoring_integration_lifecycle_idempotency is NOT empty (% row(s)); fingerprints cannot be derived for existing rows and a NULL fingerprint must never replay. STOP -- nothing was changed.', (select count(*) from public.factoring_integration_lifecycle_idempotency);
  end if;
  foreach v_md5 in array array[{helpers}] loop
    if to_regprocedure(v_md5) is null then raise exception '0152 precondition: helper % missing. STOP.', v_md5; end if;
  end loop;

  create temp table _mig0152_funcs on commit drop as
    select p.oid::regprocedure::text as sig, md5(p.prosrc) as body_md5, coalesce(p.proacl::text, '') as acl, coalesce(p.proconfig::text, '') as config,
           p.prosecdef, p.proowner, p.prorettype, p.provolatile, pg_get_function_arguments(p.oid) as args, coalesce(obj_description(p.oid, 'pg_proc'), '') as descr
    from pg_proc p where p.pronamespace = 'public'::regnamespace;
  create temp table _mig0152_misc on commit drop as
    select (select count(*) from public.factoring_policy_idempotency) n_pol, (select md5(coalesce(string_agg(to_jsonb(t)::text, '|' order by t.carrier_id, t.idempotency_key), '')) from public.factoring_policy_idempotency t) pol_md5,
           (select count(*) from public.factoring_integration_lifecycle_idempotency) n_life, (select md5(coalesce(string_agg(to_jsonb(t)::text, '|' order by t.action, t.target_id, t.idempotency_key), '')) from public.factoring_integration_lifecycle_idempotency t) life_md5,
           (select count(*) from public.dispatch_resource_reassignments) n_rea, (select md5(coalesce(string_agg(to_jsonb(t)::text, '|' order by t.id), '')) from public.dispatch_resource_reassignments t) rea_md5,
           (select count(*) from public.legacy_invoice_review_idempotency) n_rev, (select count(*) from public.carrier_invoice_lifecycle_idempotency) n_civ;
  raise notice '0152 PHASE 1 passed.';
end
$mig$;

-- ======================= PHASE 2 -- SCHEMA (NOT NULL columns), FUNCTIONS, PRIVILEGES =====
alter table public.factoring_policy_idempotency add column request_fingerprint text not null;
alter table public.factoring_integration_lifecycle_idempotency add column request_fingerprint text not null;
comment on column public.factoring_policy_idempotency.request_fingerprint is
  '0152: sha256 request fingerprint (operation, organization, carrier, mode, reason; NOT the expected_updated_at concurrency token -- 0139 deliberately replays across a stale token). NOT NULL: 0152 applies only while this ledger is empty. A replay whose fingerprint differs is refused (FPIDK).';
comment on column public.factoring_integration_lifecycle_idempotency.request_fingerprint is
  '0152: sha256 request fingerprint (operation, organization, target, every material parameter, reason; NOT the expected_updated_at concurrency token, which replay deliberately ignores). NOT NULL: 0152 applies only while this ledger is empty. A replay whose fingerprint differs is refused (IDEMPOTENCY_KEY_REUSED).';

{fn_sql}

{revokes}

-- ======================= PHASE 3 -- POSTCONDITIONS =============================
do $mig$
declare
  r record;
  v_bad integer;
  m record;
begin
  for r in select * from (values
{news}
  ) as t(sig, body_md5) loop
    if (select md5(regexp_replace(lower(regexp_replace(prosrc, '--[^\\n]*', '', 'g')), '\\s+', '', 'g')) from pg_proc where oid = to_regprocedure(r.sig)) is distinct from r.body_md5 then
      raise exception '0152 postcondition: live % is not the reviewed 0152 definition.', r.sig;
    end if;
  end loop;

  create temp table _mig0152_after on commit drop as
    select p.oid::regprocedure::text as sig, md5(p.prosrc) as body_md5, coalesce(p.proacl::text, '') as acl, coalesce(p.proconfig::text, '') as config,
           p.prosecdef, p.proowner, p.prorettype, p.provolatile, pg_get_function_arguments(p.oid) as args, coalesce(obj_description(p.oid, 'pg_proc'), '') as descr
    from pg_proc p where p.pronamespace = 'public'::regnamespace;
  -- no function added/removed; every property except ACL identical; ACL identical except the three helpers
  select count(*) into v_bad from _mig0152_funcs o full join _mig0152_after n using (sig)
   where o.sig is null or n.sig is null
      or (o.config, o.prosecdef, o.proowner, o.prorettype, o.provolatile, o.args, o.descr) is distinct from (n.config, n.prosecdef, n.proowner, n.prorettype, n.provolatile, n.args, n.descr)
      or (o.acl is distinct from n.acl and o.sig not in (select to_regprocedure(h)::text from unnest(array[{helpers}]) h));
  if v_bad <> 0 then raise exception '0152 postcondition: % function(s) added/removed or with changed properties/ACL.', v_bad; end if;
  -- exactly the eight bodies changed
  select count(*) into v_bad from _mig0152_funcs o join _mig0152_after n using (sig) where o.body_md5 is distinct from n.body_md5;
  if v_bad <> {len(FUNCS)} then raise exception '0152 postcondition: expected exactly {len(FUNCS)} changed function bodies, found %.', v_bad; end if;
  select count(*) into v_bad from _mig0152_funcs o join _mig0152_after n using (sig)
   where o.body_md5 is distinct from n.body_md5 and o.sig not in (select to_regprocedure(s)::text from unnest(array[{", ".join(q(s) for _, s, _ in FUNCS)}]) s);
  if v_bad <> 0 then raise exception '0152 postcondition: a function outside the reviewed eight changed.'; end if;

  foreach r.sig in array array[{helpers}] loop
    if has_function_privilege('service_role', to_regprocedure(r.sig), 'execute') or has_function_privilege('authenticated', to_regprocedure(r.sig), 'execute')
       or has_function_privilege('anon', to_regprocedure(r.sig), 'execute') or (select (p.proacl is null or exists (select 1 from unnest(p.proacl) a where a::text like '=%')) from pg_proc p where p.oid = to_regprocedure(r.sig)) then
      raise exception '0152 postcondition: % is still executable by a client role / service_role.', r.sig;
    end if;
  end loop;

  select count(*) into v_bad from information_schema.columns where table_schema = 'public' and column_name = 'request_fingerprint' and data_type = 'text' and is_nullable = 'NO'
     and table_name in ('factoring_policy_idempotency', 'factoring_integration_lifecycle_idempotency');
  if v_bad <> 2 then raise exception '0152 postcondition: request_fingerprint columns missing.'; end if;

  select * into m from _mig0152_misc;
  if (select count(*) from public.factoring_policy_idempotency) <> m.n_pol or (select md5(coalesce(string_agg((to_jsonb(t) - 'request_fingerprint')::text, '|' order by t.carrier_id, t.idempotency_key), '')) from public.factoring_policy_idempotency t) <> m.pol_md5
     or (select count(*) from public.factoring_integration_lifecycle_idempotency) <> m.n_life or (select md5(coalesce(string_agg((to_jsonb(t) - 'request_fingerprint')::text, '|' order by t.action, t.target_id, t.idempotency_key), '')) from public.factoring_integration_lifecycle_idempotency t) <> m.life_md5
     or (select count(*) from public.dispatch_resource_reassignments) <> m.n_rea or (select md5(coalesce(string_agg(to_jsonb(t)::text, '|' order by t.id), '')) from public.dispatch_resource_reassignments t) <> m.rea_md5
     or (select count(*) from public.legacy_invoice_review_idempotency) <> m.n_rev or (select count(*) from public.carrier_invoice_lifecycle_idempotency) <> m.n_civ then
    raise exception '0152 postcondition: a ledger changed (0152 never writes them).';
  end if;
  raise notice '0152 complete: 8 RPCs authorize/bind before replay; 2 NOT NULL fingerprint columns; 3 internal helpers no longer executable by service_role.';
end
$mig$;

commit;
"""


def verifier_tail(title, label):
    return f"""verdict as (
  select count(*) filter (where result = 'PASS') as n_pass, count(*) filter (where result = 'FAIL') as n_fail, count(*) filter (where result = 'INFO') as n_info,
         case when count(*) filter (where result = 'FAIL') = 0 and count(*) filter (where result = 'PASS') > 0 then 0
              else ({q(label + ' FAIL: ')} || (count(*) filter (where result = 'FAIL'))::text || ' failing check(s). Full report follows.' || E'\\n'
                    || string_agg(section || ' | ' || item || ' | ' || result || ' | ' || detail, E'\\n' order by ord))::int
         end as gate   -- a deliberate cast error: raises only when a check fails
  from rows
)
select r.ord, r.section, r.item, r.result, r.detail from rows r cross join verdict v where v.gate = 0
union all
select 9000, 'RESULT', {q(title)}, 'PASS', v.n_pass::text || ' checks passed, 0 failed, ' || v.n_info::text || ' informational rows' from verdict v where v.gate = 0
order by 1;
"""


def func_rows(which, base):
    B = blocks()
    rows = []
    for i, (n, sig, _) in enumerate(FUNCS):
        h = md5(norm(body_of(B[n][1 if which == "old" else 2])))
        internal = n == "transition_carrier_factoring_integration_lifecycle"
        rows.append(f"""  union all select {base + i * 3}, 'FUNCTION', '{n}: body is the reviewed {"baseline" if which == "old" else "0152"} definition',
         case when {md5expr(sig)} = {q(h)} then 'PASS' else 'FAIL' end, coalesce({md5expr(sig)}, 'MISSING')
  union all select {base + i * 3 + 1}, 'FUNCTION', '{n}: SECURITY DEFINER, pinned search_path, {"internal-only (authenticated may NOT execute)" if internal else "EXECUTE for authenticated, none for PUBLIC"}',
         case when (select p.prosecdef and p.proconfig::text = '{{"search_path=pg_catalog, public"}}' and {"not " if internal else ""}has_function_privilege('authenticated', p.oid, 'execute')
                           and not (p.proacl is null or exists (select 1 from unnest(p.proacl) a where a::text like '=%')) from pg_proc p where p.oid = to_regprocedure({q(sig)})) then 'PASS' else 'FAIL' end,
         coalesce((select coalesce(p.proacl::text, 'NULL') from pg_proc p where p.oid = to_regprocedure({q(sig)})), 'MISSING')""")
    return "\n".join(rows)


def helper_rows(base, expect_revoked):
    out = []
    for i, h in enumerate(HELPERS):
        if expect_revoked:
            cond = f"not has_function_privilege('service_role', to_regprocedure({q(h)}), 'execute') and not has_function_privilege('authenticated', to_regprocedure({q(h)}), 'execute') and not has_function_privilege('anon', to_regprocedure({q(h)}), 'execute') and not (select (p.proacl is null or exists (select 1 from unnest(p.proacl) a where a::text like '=%')) from pg_proc p where p.oid = to_regprocedure({q(h)}))"
            title = f"internal helper {h.split('(')[0]} is executable by NO client role and NOT service_role"
        else:
            cond = f"not has_function_privilege('authenticated', to_regprocedure({q(h)}), 'execute') and not has_function_privilege('anon', to_regprocedure({q(h)}), 'execute') and not (select (p.proacl is null or exists (select 1 from unnest(p.proacl) a where a::text like '=%')) from pg_proc p where p.oid = to_regprocedure({q(h)}))"
            title = f"internal helper {h.split('(')[0]} is not executable by authenticated/anon/PUBLIC (service_role: INFO below)"
        out.append(f"  union all select {base + i * 2}, 'PRIVILEGE', {q(title)}, case when to_regprocedure({q(h)}) is not null and {cond} then 'PASS' else 'FAIL' end, coalesce((select coalesce(proacl::text, 'NULL') from pg_proc where oid = to_regprocedure({q(h)})), 'MISSING')")
        if not expect_revoked:
            out.append(f"  union all select {base + i * 2 + 1}, 'PRIVILEGE', {q('service_role EXECUTE on ' + h.split('(')[0])}, 'INFO', coalesce(has_function_privilege('service_role', to_regprocedure({q(h)}), 'execute')::text, 'MISSING')")
    return "\n".join(out)


def preflight():
    return f"""{hdr("preflight.sql")}
--
-- Run BEFORE applying 0152. READ-ONLY: ONE select statement over catalogs and public tables; no data-/schema-changing statement, no
-- transaction control, no temporary object. RESULT: every row INFO or PASS and a final RESULT | PASS row; otherwise the statement RAISES
-- (invalid input syntax for type integer: "PREFLIGHT 0152 FAIL ...") whose text is the complete report.
-- =============================================================================
with rows as (
  select 100 as ord, 'SERVER' as section, 'server_version' as item, 'INFO' as result, current_setting('server_version')::text as detail
  union all select 110, 'PRECONDITION', 'proposal 0151 is applied (transition_dispatch_status authorizes before replay)',
         case when position('tsidk' in coalesce((select regexp_replace(lower(prosrc), '\\s+', '', 'g') from pg_proc where oid = to_regprocedure('public.transition_dispatch_status(uuid,public.dispatch_status,text,text)')), '')) > 0 then 'PASS' else 'FAIL' end, 'catalog'
  union all select 111, 'PRECONDITION', 'compute_financial_request_fingerprint(jsonb) exists (0143)', case when to_regprocedure({q(FPFN)}) is not null then 'PASS' else 'FAIL' end, 'catalog'
  union all select 112, 'PRECONDITION', 'the five ledger tables exist',
         case when to_regclass('public.factoring_policy_idempotency') is not null and to_regclass('public.factoring_integration_lifecycle_idempotency') is not null and to_regclass('public.dispatch_resource_reassignments') is not null
                   and to_regclass('public.legacy_invoice_review_idempotency') is not null and to_regclass('public.carrier_invoice_lifecycle_idempotency') is not null then 'PASS' else 'FAIL' end, 'catalog'
  union all select 113, 'PRECONDITION', 'request_fingerprint columns do not exist yet (0152 not applied)',
         case when not exists (select 1 from information_schema.columns where table_schema = 'public' and column_name = 'request_fingerprint' and table_name in ('factoring_policy_idempotency', 'factoring_integration_lifecycle_idempotency')) then 'PASS' else 'FAIL' end, 'catalog'
{func_rows("old", 200)}
{helper_rows(400, False)}
  union all select 500, 'LEDGER', 'dispatch_resource_reassignments rows', 'INFO', (select count(*) from public.dispatch_resource_reassignments)::text
  union all select 501, 'LEDGER', 'factoring_policy_idempotency is EMPTY (zero-row invariant; fingerprints cannot be derived for existing rows)',
         case when (select count(*) from public.factoring_policy_idempotency) = 0 then 'PASS' else 'FAIL' end, (select count(*) from public.factoring_policy_idempotency)::text || ' row(s)'
  union all select 502, 'LEDGER', 'factoring_integration_lifecycle_idempotency is EMPTY (zero-row invariant; fingerprints cannot be derived for existing rows)',
         case when (select count(*) from public.factoring_integration_lifecycle_idempotency) = 0 then 'PASS' else 'FAIL' end, (select count(*) from public.factoring_integration_lifecycle_idempotency)::text || ' row(s)'
  union all select 503, 'LEDGER', 'legacy_invoice_review_idempotency rows', 'INFO', (select count(*) from public.legacy_invoice_review_idempotency)::text
  union all select 504, 'LEDGER', 'carrier_invoice_lifecycle_idempotency rows', 'INFO', (select count(*) from public.carrier_invoice_lifecycle_idempotency)::text
  union all select 510, 'LEDGER', 'reassignment ledger rows whose organization differs from their dispatch''s (would stop replaying; must be 0)',
         case when (select count(*) from public.dispatch_resource_reassignments t join public.dispatches d on d.id = t.dispatch_id where d.organization_id <> t.organization_id) = 0 then 'PASS' else 'FAIL' end, 'ledger'
  union all select 511, 'LEDGER', 'policy ledger rows whose organization differs from their carrier''s (must be 0)',
         case when (select count(*) from public.factoring_policy_idempotency t join public.carriers c on c.id = t.carrier_id where c.organization_id <> t.organization_id) = 0 then 'PASS' else 'FAIL' end, 'ledger'
),
{verifier_tail('PREFLIGHT 0152: live definitions are the reviewed baseline', 'PREFLIGHT 0152')}"""


def post_apply():
    return f"""{hdr("post_apply.sql")}
--
-- Run AFTER applying 0152 (and any time later). READ-ONLY: ONE select statement. RESULT: rows INFO/PASS + a final RESULT | PASS row, or a
-- raised error ("POST-APPLY 0152 FAIL ...") whose text is the complete report.
-- =============================================================================
with rows as (
  select 100 as ord, 'SERVER' as section, 'server_version' as item, 'INFO' as result, current_setting('server_version')::text as detail
  union all select 110, 'SCHEMA', 'request_fingerprint is a NOT NULL text column on both 0139/0141 ledgers',
         case when (select count(*) from information_schema.columns where table_schema = 'public' and column_name = 'request_fingerprint' and data_type = 'text' and is_nullable = 'NO'
                     and table_name in ('factoring_policy_idempotency', 'factoring_integration_lifecycle_idempotency')) = 2 then 'PASS' else 'FAIL' end, 'catalog'
  union all select 111, 'SCHEMA', 'no ledger row has a NULL fingerprint (impossible by the NOT NULL constraint; must be 0)',
         case when (select count(*) from public.factoring_policy_idempotency where request_fingerprint is null) + (select count(*) from public.factoring_integration_lifecycle_idempotency where request_fingerprint is null) = 0 then 'PASS' else 'FAIL' end, 'ledgers'
{func_rows("new", 200)}
{helper_rows(400, True)}
),
{verifier_tail('POST-APPLY 0152: replay authorization + request binding + helper privileges in place', 'POST-APPLY 0152')}"""


def rollback():
    B = blocks()
    old_sql = "\n\n".join(B[n][1] for n, _, _ in FUNCS)
    news = ",\n".join(f"    ({q(sig)}, {q(md5(norm(body_of(B[n][2]))))})" for n, sig, _ in FUNCS)
    grants = "\n".join(f"grant execute on function {h} to service_role;" for h in HELPERS)
    return f"""{hdr("rollback.sql -- EMERGENCY reversal of proposal 0152")}
--
-- Restores the EXACT baseline function bodies (verbatim from migrations 0135/0139/0141/0142/0143), drops the two request_fingerprint columns
-- (fingerprints written since 0152 are lost; replays of those rows revert to the baseline target + key binding) and re-grants EXECUTE to service_role on the
-- three helpers (the state Supabase's default privileges produced). WARNING: this re-introduces the replay-before-authorization defects.
-- Refuses unless every live body is exactly the reviewed 0152 definition (anything else = drift). Single transaction.
-- =============================================================================
begin;

do $mig$
declare r record; v_md5 text;
begin
  for r in select * from (values
{news}
  ) as t(sig, body_md5) loop
    select md5(regexp_replace(lower(regexp_replace(prosrc, '--[^\\n]*', '', 'g')), '\\s+', '', 'g')) into v_md5 from pg_proc where oid = to_regprocedure(r.sig);
    if v_md5 is distinct from r.body_md5 then raise exception 'ROLLBACK 0152 REFUSED: live % is not the reviewed 0152 definition (md5 %) -- nothing changed.', r.sig, v_md5; end if;
  end loop;
  create temp table _rb0152_funcs on commit drop as
    select p.oid::regprocedure::text as sig, coalesce(p.proconfig::text, '') as config, p.prosecdef, p.proowner from pg_proc p where p.pronamespace = 'public'::regnamespace;
end
$mig$;

{old_sql}

alter table public.factoring_policy_idempotency drop column request_fingerprint;
alter table public.factoring_integration_lifecycle_idempotency drop column request_fingerprint;
{grants}

do $mig$
declare r record; v_md5 text; v_bad integer;
begin
  for r in select * from (values
{",\n".join(f"    ({q(sig)}, {q(md5(norm(body_of(B[n][1]))))})" for n, sig, _ in FUNCS)}
  ) as t(sig, body_md5) loop
    select md5(regexp_replace(lower(regexp_replace(prosrc, '--[^\\n]*', '', 'g')), '\\s+', '', 'g')) into v_md5 from pg_proc where oid = to_regprocedure(r.sig);
    if v_md5 is distinct from r.body_md5 then raise exception 'ROLLBACK 0152 postcondition: % is not the baseline body (md5 %).', r.sig, v_md5; end if;
  end loop;
  select count(*) into v_bad from _rb0152_funcs o join pg_proc p on p.oid::regprocedure::text = o.sig
   where (o.config, o.prosecdef, o.proowner) is distinct from (coalesce(p.proconfig::text, ''), p.prosecdef, p.proowner);
  if v_bad <> 0 then raise exception 'ROLLBACK 0152 postcondition: % function propert(ies) changed.', v_bad; end if;
  if exists (select 1 from information_schema.columns where table_schema = 'public' and column_name = 'request_fingerprint' and table_name in ('factoring_policy_idempotency', 'factoring_integration_lifecycle_idempotency')) then
    raise exception 'ROLLBACK 0152 postcondition: a fingerprint column remains.';
  end if;
  raise notice 'ROLLBACK 0152 complete: baseline bodies restored, fingerprint columns dropped, helper EXECUTE for service_role restored.';
end
$mig$;

commit;
"""


def diffs():
    out = {}
    for n, sig, old_new in [(n, s, None) for n, s, _ in FUNCS]:
        B = blocks()
        o, w = B[n][1].splitlines(), B[n][2].splitlines()
        out[f"diffs/{n}.patch"] = "\n".join(difflib.unified_diff(o, w, f"baseline ({n})", f"0152 ({n})", lineterm="", n=2)) + "\n"
    return out


# ------------------------------------------------------------------ authorization / replay matrix (disposable harness script)
RPCS = [  # kind, RPC, U1 (original, authorized), U2 (another authorized user), UR (same-org role NOT allowed), FU (foreign-org caller), U2's original role
    ("rea", "reassign_dispatch_resources", "u_disp1", "u_disp1b", "u_acct1", "u_disp2", "dispatcher"),
    ("pol", "set_carrier_factoring_policy", "u_owner1", "u_admin1", "u_disp1", "u_owner2", "admin"),
    ("cfg", "configure_carrier_factoring_integration", "u_owner1", "u_admin1", "u_disp1", "u_owner2", "admin"),
    ("rot", "rotate_carrier_factoring_integration", "u_owner1", "u_admin1", "u_disp1", "u_owner2", "admin"),
    ("ver", "verify_carrier_factoring_integration (-> transition_carrier_factoring_integration_lifecycle)", "u_owner1", "u_admin1", "u_disp1", "u_owner2", "admin"),
    ("dea", "deactivate_factoring_relationship", "u_owner1", "u_admin1", "u_disp1", "u_owner2", "admin"),
    ("rev", "review_legacy_invoice_carrier_migration", "u_owner1", "u_admin1", "u_acct1", "u_owner2", "admin"),
    ("drf", "update_carrier_invoice_draft", "u_disp1", "u_disp1b", "u_viewer1", "u_owner2", "dispatcher"),
]
STEPS = ["s0_orig", "s1_same_user_replay", "s2_other_authorized_replay", "s3_unauthenticated", "s4_unauthorized_role", "s5_foreign_org_real_key",
         "s6_foreign_org_wrong_key", "s7_removed_member", "s8_moved_member", "s9_downgraded_member", "s10_changed_request", "s11_same_key_other_target",
         "s12_same_key_other_org", "s13_failed_tx", "s14_retry_after_failure", "s15_retry_replays"]


def matrix_sql():
    out = []
    for kind, _rpc, u1, u2, ur, fu, u2role in RPCS:
        k, k3 = f"KEY-{kind}-1", f"KEY-{kind}-3"
        st = lambda tag, user, tgt, key, var="a": f"select td0149_t.step('{kind}', '{tag}', {('null' if user is None else repr(user))}, '{tgt}', '{key}', '{var}');"
        out += [f"-- ---- {kind}: {_rpc}", f"insert into td0149_t.rec (rpc, tag, outcome, msg, n_led, n_act) values ('{kind}', 'pre', '', '', td0149_t.led('{kind}'), td0149_t.act());", "set role authenticated;",
                st("s0_orig", u1, "1", k), st("s1_same_user_replay", u1, "1", k), st("s2_other_authorized_replay", u2, "1", k),
                st("s3_unauthenticated", None, "1", k), st("s4_unauthorized_role", ur, "1", k),
                st("s5_foreign_org_real_key", fu, "1", k), st("s6_foreign_org_wrong_key", fu, "1", k + "-WRONG"),
                "reset role;", f"update public.profiles set organization_id = null where id = td0149_t.id('{u2}');", "set role authenticated;",
                st("s7_removed_member", u2, "1", k),
                "reset role;", f"update public.profiles set organization_id = td0149_t.id('o2') where id = td0149_t.id('{u2}');", "set role authenticated;",
                st("s8_moved_member", u2, "1", k),
                "reset role;", f"update public.profiles set organization_id = td0149_t.id('o1'), role = 'viewer' where id = td0149_t.id('{u2}');", "set role authenticated;",
                st("s9_downgraded_member", u2, "1", k),
                "reset role;", f"update public.profiles set role = '{u2role}' where id = td0149_t.id('{u2}');", "set role authenticated;",
                st("s10_changed_request", u1, "1", k, "b"), st("s11_same_key_other_target", u1, "2", k),
                st("s12_same_key_other_org", fu, "x1", k),
                "reset role;", "set td0149.boom = 'activity_logs';", "set role authenticated;",
                st("s13_failed_tx", u1, "3", k3),
                "reset role;", "set td0149.boom = '';", "set role authenticated;",
                st("s14_retry_after_failure", u1, "3", k3), st("s15_retry_replays", u1, "3", k3), "reset role;", ""]
    out.append("select 'ROW', rpc, tag, outcome, msg, n_led, n_act from td0149_t.rec order by seq;")
    return "\n".join(out) + "\n"


def matrix_file():
    return f"""-- =============================================================================
-- matrix.sql -- PROPOSAL 0152 authorization / replay matrix (GENERATED by build.py from RPCS/STEPS).
-- NOT APPROVED FOR PRODUCTION. Current proposal 0148 must be renumbered to 0153 or higher before promotion.
-- DISPOSABLE SCRATCH DATABASE ONLY. Run through tests.py only, once on the BASELINE (0151 state) and once after
-- 0152, on identical databases; tests.py asserts the expected outcomes. ONE transaction that ENDS IN ROLLBACK.
-- Per repaired RPC: original call, same-user replay, other authorized user, unauthenticated, unauthorized same-org role, foreign org with the
-- real key and with a wrong key, removed / moved / downgraded member, changed request, same key on another target, same key in another
-- organization, failed transaction, retry, further retry. Outcomes: S = success, +R = idempotent_replay flag, F:<code>, X:<sqlstate>.
-- =============================================================================
-- @@GUARD@@
\\set ON_ERROR_STOP on
begin;
set client_min_messages = notice;
-- @@FIXTURE@@
{matrix_sql()}rollback;
"""


# ------------------------------------------------------------------ runtime probes for the 0144-0147 RPCs classified SAFE
A_ORG, B_ORG = "11111111-1111-1111-1111-111111111111", "22222222-2222-2222-2222-222222222222"
OWNER, ACCT, DISP, DRIVER, VIEWER, OWNER_B = ("aaaa0000-0000-0000-0000-000000000001", "cccc0000-0000-0000-0000-000000000001", "dddd0000-0000-0000-0000-000000000001",
                                              "eeee0000-0000-0000-0000-000000000001", "ffff0000-0000-0000-0000-000000000001", "bbbb0000-0000-0000-0000-000000000001")
ADMIN = "aaaa0000-0000-0000-0000-000000000002"
LEDGER_LIFE, LEDGER_AGR, LEDGER_DC, LEDGER_DD = ("carrier_invoice_lifecycle_idempotency", "carrier_dispatch_service_agreement_idempotency",
                                                 "carrier_invoice_draft_create_idempotency", "carrier_invoice_draft_delete_idempotency")
SAFE_KINDS = [  # kind, RPC, U1, U2, U2 role, UR, ledger, business table, foreign-org target available (s12)
    ("cdr", "create_carrier_invoice_draft (0147)", OWNER, ACCT, "accountant", DRIVER, LEDGER_DC, "carrier_invoices", True),
    ("ddr", "delete_carrier_invoice_draft (0147)", OWNER, ACCT, "accountant", DISP, LEDGER_DD, "carrier_invoices", True),
    ("iss", "issue_carrier_invoice (0146)", OWNER, ACCT, "accountant", DISP, LEDGER_LIFE, "carrier_invoices", False),
    ("pay", "record_carrier_invoice_payment (0146)", OWNER, ACCT, "accountant", DISP, LEDGER_LIFE, "carrier_invoice_payments", False),
    ("vpay", "void_carrier_invoice_payment (0146)", OWNER, ACCT, "accountant", DISP, LEDGER_LIFE, "carrier_invoice_payments", False),
    ("agr", "create_carrier_dispatch_service_agreement (0145)", OWNER, ADMIN, "admin", DISP, LEDGER_AGR, "carrier_dispatch_service_agreements", True),
    ("agv", "create_carrier_dispatch_service_agreement_version (0145)", OWNER, ADMIN, "admin", DISP, LEDGER_AGR, "carrier_dispatch_service_agreement_versions", False),
    ("apv", "approve_carrier_dispatch_service_agreement_version (0145)", OWNER, ADMIN, "admin", DISP, LEDGER_AGR, "carrier_dispatch_service_agreement_versions", False),
    ("dav", "deactivate_carrier_dispatch_service_agreement_version (0145)", OWNER, ADMIN, "admin", DISP, LEDGER_AGR, "carrier_dispatch_service_agreement_versions", False),
    ("dag", "deactivate_carrier_dispatch_service_agreement (0145)", OWNER, ADMIN, "admin", DISP, LEDGER_AGR, "carrier_dispatch_service_agreements", False),
]
US = "\x1f"


def probe_sql():
    led_case = "\n".join(f"      when '{k}' then '{led}'" for k, _r, _u1, _u2, _r2, _ur, led, _b, _f in SAFE_KINDS)
    biz_case = "\n".join(f"      when '{k}' then '{biz}'" for k, _r, _u1, _u2, _r2, _ur, _l, biz, _f in SAFE_KINDS)
    head = f"""-- =============================================================================
-- probe_safe_0144_0147.sql -- PROPOSAL 0152: runtime probes for every externally executable idempotent RPC of 0144-0147 classified SAFE
-- (GENERATED by build.py). NOT APPROVED FOR PRODUCTION. NOT A MIGRATION. DISPOSABLE SCRATCH DATABASE ONLY.
-- Current proposal 0148 must be renumbered to 0153 or higher before promotion. Appended by tests.py to a copy of TEST_0147 (which supplies the
-- 0130..0147 chain and the stub organizations/users); builds its own carriers, loads, drafts, issued invoices, payments and agreements.
-- Probes per RPC: original call, same-user replay, other authorized user, unauthenticated, unauthorized same-org role, foreign org with the real key and a
-- wrong key, removed / moved / downgraded member, changed request, same key on another target, same key in another org (where a foreign target exists),
-- failed transaction (fault injected at the ledger insert, AFTER the business writes), retry, further retry. Ledger, audit and business-table counts and
-- a business-table fingerprint are recorded after every call.
-- =============================================================================
\\set ON_ERROR_STOP on
reset role;
select set_config('test.current_uid', '{OWNER}', false);
create schema pb;
grant usage on schema pb to authenticated;
create table pb.tgt (tag text primary key, id uuid not null, t0 timestamptz, aux uuid);
create table pb.rec (seq bigserial primary key, kind text, tag text, outcome text, msg text, n_led bigint, n_act bigint, n_biz bigint, biz text);
grant select, insert on pb.tgt, pb.rec to authenticated;
grant usage on sequence pb.rec_seq_seq to authenticated;
create function pb.id(p text) returns uuid language sql immutable as $$ select md5('pb0152:' || p)::uuid $$;
insert into auth.users (id) values ('{ADMIN}') on conflict do nothing;
insert into public.profiles (id, organization_id, full_name, email, role) values ('{ADMIN}', '{A_ORG}', 'Admin A', 'admina@example.com', 'admin') on conflict do nothing;
insert into public.brokers (id, organization_id, company_name) values (pb.id('brokerB'), '{B_ORG}', 'Probe Broker B') on conflict do nothing;
update public.organizations set remittance_instructions = coalesce(remittance_instructions, 'Probe remittance') where id = '{A_ORG}';

-- fixture builders (superuser, owner identity; all rows are created through the real tables / RPCs)
create function pb.mk_carrier(p_org uuid, p_tag text, p_link boolean) returns uuid language plpgsql as $$
declare v uuid := pb.id('carrier:' || p_tag);
begin
  insert into public.carriers (id, organization_id, legal_name, address_line1, city, state, postal_code, email, is_active)
  values (v, p_org, 'PB Carrier ' || p_tag, '1 Probe St', 'Dallas', 'TX', '75201', 'pb@example.com', true);
  update public.carriers set invoice_code = translate(upper(substr(md5(p_tag), 1, 6)), '0123456789', 'GHIJKLMNOP'), factoring_mode = 'direct' where id = v;
  if p_link then
    insert into public.carrier_brokers (id, organization_id, carrier_id, broker_id, status, billing_email, payment_terms_days, factoring_eligible, activated_at, activated_by)
    values (pb.id('cb:' || p_tag), p_org, v, 'a0b00000-0000-0000-0000-000000000001', 'active', 'ap@brokera.example', 30, true, now(), '{OWNER}');
  end if;
  return v;
end $$;
create function pb.mk_draft(p_carrier uuid, p_tag text, p_with_load boolean) returns uuid language plpgsql as $$
declare v_inv uuid; v_load uuid := pb.id('load:' || p_tag);
begin
  insert into public.carrier_invoices (organization_id, invoice_document_type, carrier_id, recipient_type, recipient_broker_id, created_by)
  values ('{A_ORG}', 'carrier_freight_invoice', p_carrier, 'broker', 'a0b00000-0000-0000-0000-000000000001', '{OWNER}') returning id into v_inv;
  if p_with_load then
    insert into public.loads (id, organization_id, load_number, broker_id, status, rate) values (v_load, '{A_ORG}', 'LD-PB-' || p_tag, 'a0b00000-0000-0000-0000-000000000001', 'delivered', 1000.00);
    update public.loads set carrier_id = p_carrier, carrier_resolution = 'resolved' where id = v_load;
    insert into public.load_stops (organization_id, load_id, stop_type, stop_sequence, facility_name, city, state, scheduled_at) values
      ('{A_ORG}', v_load, 'pickup', 1, 'Shipper PB', 'Dallas', 'TX', now() - interval '3 days'), ('{A_ORG}', v_load, 'delivery', 2, 'Receiver PB', 'Houston', 'TX', now() - interval '1 day');
    insert into public.carrier_invoice_line_items (organization_id, invoice_id, description, quantity, unit_price, line_type, source_load_id) values ('{A_ORG}', v_inv, 'Freight PB ' || p_tag, 1, 1000.00, 'freight_charge', v_load);
    insert into public.carrier_invoice_loads (organization_id, invoice_id, load_id) values ('{A_ORG}', v_inv, v_load);
  end if;
  return v_inv;
end $$;
create function pb.mk_issued(p_tag text) returns uuid language plpgsql as $$
declare v_car uuid := pb.mk_carrier('{A_ORG}', 'iv:' || p_tag, true); v_inv uuid; v jsonb;
begin
  v_inv := pb.mk_draft(v_car, 'iv:' || p_tag, true);
  v := public.issue_carrier_invoice(v_inv, (select updated_at from public.carrier_invoices where id = v_inv), 'fixture issuance', 'pbfix-issue-' || p_tag);
  if v ->> 'code' <> 'ISSUED' then raise exception 'probe fixture: issuance failed for %: %', p_tag, v; end if;
  return v_inv;
end $$;
create function pb.mk_agreement(p_tag text) returns uuid language plpgsql as $$
declare v_car uuid := pb.mk_carrier('{A_ORG}', 'ag:' || p_tag, false); v jsonb;
begin
  v := public.create_carrier_dispatch_service_agreement(v_car, 'FIX-' || p_tag, 'fixture agreement', 'pbfix-agr-' || p_tag);
  if v ->> 'code' <> 'CREATED' then raise exception 'probe fixture: agreement failed for %: %', p_tag, v; end if;
  return (v ->> 'agreement_id')::uuid;
end $$;
create function pb.mk_version(p_agreement uuid, p_tag text, p_approve boolean) returns uuid language plpgsql as $$
declare v jsonb; ver uuid;
begin
  v := public.create_carrier_dispatch_service_agreement_version(p_agreement, 'flat_per_load', null, 50.00, null, null, 'USD', 15, current_date - 10, null, 'fixture version', 'pbfix-ver-' || p_tag);
  if v ->> 'code' <> 'CREATED' then raise exception 'probe fixture: version failed for %: %', p_tag, v; end if;
  ver := (v ->> 'version_id')::uuid;
  if p_approve then
    v := public.approve_carrier_dispatch_service_agreement_version(ver, (select updated_at from public.carrier_dispatch_service_agreement_versions where id = ver), 'fixture approval', 'pbfix-apv-' || p_tag);
    if v ->> 'code' <> 'APPROVED' then raise exception 'probe fixture: approval failed for %: %', p_tag, v; end if;
  end if;
  return ver;
end $$;

do $t$
declare g int; car uuid; v uuid; inv uuid; pay jsonb; ag uuid;
begin
  for g in 1..3 loop
    car := pb.mk_carrier('{A_ORG}', 'cdr' || g, false);
    insert into pb.tgt values ('cdr:' || g, car, null, 'a0b00000-0000-0000-0000-000000000001');
    inv := pb.mk_draft(pb.mk_carrier('{A_ORG}', 'ddr' || g, false), 'ddr' || g, false);
    insert into pb.tgt values ('ddr:' || g, inv, (select updated_at from public.carrier_invoices where id = inv), null);
    inv := pb.mk_draft(pb.mk_carrier('{A_ORG}', 'iss' || g, true), 'iss' || g, true);
    insert into pb.tgt values ('iss:' || g, inv, (select updated_at from public.carrier_invoices where id = inv), null);
    inv := pb.mk_issued('pay' || g);
    insert into pb.tgt values ('pay:' || g, inv, (select updated_at from public.carrier_invoices where id = inv), null);
    inv := pb.mk_issued('vpay' || g);
    pay := public.record_carrier_invoice_payment(inv, 100.00, current_date, 'ach', 'FIXREF', (select updated_at from public.carrier_invoices where id = inv), 'fixture payment', 'pbfix-pay-' || g);
    if pay ->> 'code' <> 'PAYMENT_RECORDED' then raise exception 'probe fixture: payment failed: %', pay; end if;
    insert into pb.tgt values ('vpay:' || g, (pay ->> 'payment_id')::uuid, (select updated_at from public.carrier_invoice_payments where id = (pay ->> 'payment_id')::uuid), null);
    car := pb.mk_carrier('{A_ORG}', 'agr' || g, false);
    insert into pb.tgt values ('agr:' || g, car, null, null);
    ag := pb.mk_agreement('agv' || g);
    insert into pb.tgt values ('agv:' || g, ag, null, null);
    v := pb.mk_version(pb.mk_agreement('apv' || g), 'apv' || g, false);
    insert into pb.tgt values ('apv:' || g, v, (select updated_at from public.carrier_dispatch_service_agreement_versions where id = v), null);
    v := pb.mk_version(pb.mk_agreement('dav' || g), 'dav' || g, true);
    insert into pb.tgt values ('dav:' || g, v, (select updated_at from public.carrier_dispatch_service_agreement_versions where id = v), null);
    ag := pb.mk_agreement('dag' || g);
    insert into pb.tgt values ('dag:' || g, ag, (select updated_at from public.carrier_dispatch_service_agreements where id = ag), null);
  end loop;
  insert into public.carriers (id, organization_id, legal_name, address_line1, city, state, postal_code, email, is_active) values (pb.id('carrier:cdrx'), '{B_ORG}', 'PB Carrier B', '1 B St', 'Reno', 'NV', '89501', 'pbb@example.com', true);
  insert into pb.tgt values ('cdr:x1', pb.id('carrier:cdrx'), null, pb.id('brokerB'));
  insert into public.carriers (id, organization_id, legal_name, address_line1, city, state, postal_code, email, is_active) values (pb.id('carrier:agrx'), '{B_ORG}', 'PB Carrier B2', '2 B St', 'Reno', 'NV', '89501', 'pbb2@example.com', true);
  insert into pb.tgt values ('agr:x1', pb.id('carrier:agrx'), null, null);
  insert into public.carrier_invoices (id, organization_id, invoice_document_type, carrier_id, recipient_type, recipient_broker_id, created_by)
  values (pb.id('draftB'), '{B_ORG}', 'carrier_freight_invoice', pb.id('carrier:cdrx'), 'broker', pb.id('brokerB'), '{OWNER_B}');
  insert into pb.tgt values ('ddr:x1', pb.id('draftB'), (select updated_at from public.carrier_invoices where id = pb.id('draftB')), null);
end $t$;

create function pb.led(p_kind text) returns bigint language plpgsql stable security definer as $$
declare n bigint;
begin execute format('select count(*) from public.%I', case p_kind
{led_case}
    end) into n; return n; end $$;
create function pb.biz(p_kind text, out n bigint, out h text) language plpgsql stable security definer as $$
begin execute format($f$select count(*), md5(coalesce(string_agg(to_jsonb(t)::text, '|' order by t.id), '')) from public.%I t$f$, case p_kind
{biz_case}
    end) into n, h; end $$;
create function pb.act() returns bigint language sql stable security definer as $$ select count(*) from public.activity_logs $$;
grant execute on function pb.led(text), pb.biz(text), pb.act() to authenticated;

create function pb.call(p_kind text, p_user text, p_target text, p_key text, p_variant text default 'a', out outcome text, out msg text) language plpgsql as $$
declare t pb.tgt; r jsonb;
begin
  perform set_config('test.current_uid', coalesce(p_user, ''), false);
  select * into t from pb.tgt where tag = p_kind || ':' || p_target;
  begin
    if p_kind = 'cdr' then r := public.create_carrier_invoice_draft('carrier_freight_invoice', t.id, 'broker', t.aux, null, 'USD', 30, null, 'notes ' || p_variant, 'a valid reason', p_key);
    elsif p_kind = 'ddr' then r := public.delete_carrier_invoice_draft(t.id, t.t0, 'a valid reason ' || p_variant, p_key);
    elsif p_kind = 'iss' then r := public.issue_carrier_invoice(t.id, t.t0, 'a valid reason ' || p_variant, p_key);
    elsif p_kind = 'pay' then r := public.record_carrier_invoice_payment(t.id, case p_variant when 'a' then 100.00 else 101.00 end, current_date, 'ach', 'REF', t.t0, 'a valid reason', p_key);
    elsif p_kind = 'vpay' then r := public.void_carrier_invoice_payment(t.id, t.t0, 'a valid reason ' || p_variant, p_key);
    elsif p_kind = 'agr' then r := public.create_carrier_dispatch_service_agreement(t.id, 'AGR-' || p_target || '-' || p_variant, 'a valid reason', p_key);
    elsif p_kind = 'agv' then r := public.create_carrier_dispatch_service_agreement_version(t.id, 'flat_per_load', null, case p_variant when 'a' then 50.00 else 60.00 end, null, null, 'USD', 15, current_date - 10, null, 'a valid reason', p_key);
    elsif p_kind = 'apv' then r := public.approve_carrier_dispatch_service_agreement_version(t.id, t.t0, 'a valid reason ' || p_variant, p_key);
    elsif p_kind = 'dav' then r := public.deactivate_carrier_dispatch_service_agreement_version(t.id, t.t0, 'a valid reason ' || p_variant, p_key);
    elsif p_kind = 'dag' then r := public.deactivate_carrier_dispatch_service_agreement(t.id, t.t0, 'a valid reason ' || p_variant, p_key);
    else raise exception 'unknown probe kind %', p_kind; end if;
    outcome := case when (r ->> 'success') = 'true' then 'S' else 'F:' || coalesce(r ->> 'code', 'unspecified') end;
    msg := coalesce(r ->> 'message', '');
  exception when others then
    get stacked diagnostics outcome := returned_sqlstate, msg := message_text;
    outcome := 'X:' || outcome;
  end;
  msg := regexp_replace(msg, '[0-9a-f]{{8}}-[0-9a-f]{{4}}-[0-9a-f]{{4}}-[0-9a-f]{{4}}-[0-9a-f]{{12}}', '<uuid>', 'g');
end $$;
grant execute on function pb.call(text, text, text, text, text) to authenticated;
create function pb.step(p_kind text, p_tag text, p_user text, p_target text, p_key text, p_variant text default 'a') returns void language plpgsql as $$
declare o record; b record;
begin
  select * into o from pb.call(p_kind, p_user, p_target, p_key, p_variant);
  select * into b from pb.biz(p_kind);
  insert into pb.rec (kind, tag, outcome, msg, n_led, n_act, n_biz, biz) values (p_kind, p_tag, o.outcome, o.msg, pb.led(p_kind), pb.act(), b.n, b.h);
end $$;
grant execute on function pb.step(text, text, text, text, text, text) to authenticated;
create function pb.snap(p_kind text) returns void language plpgsql as $$
declare b record;
begin select * into b from pb.biz(p_kind); insert into pb.rec (kind, tag, outcome, msg, n_led, n_act, n_biz, biz) values (p_kind, 'pre', '', '', pb.led(p_kind), pb.act(), b.n, b.h); end $$;
grant execute on function pb.snap(text) to authenticated;

create function pb.boom() returns trigger language plpgsql as $$
begin
  if current_setting('td0149.boom', true) = tg_table_name then raise exception 'FORCED downstream failure in %', tg_table_name using errcode = 'P0F11'; end if;
  return new;
end $$;
create trigger pb_boom before insert on public.carrier_invoice_lifecycle_idempotency for each row execute function pb.boom();
create trigger pb_boom before insert on public.carrier_dispatch_service_agreement_idempotency for each row execute function pb.boom();
create trigger pb_boom before insert on public.carrier_invoice_draft_create_idempotency for each row execute function pb.boom();
create trigger pb_boom before insert on public.carrier_invoice_draft_delete_idempotency for each row execute function pb.boom();
"""
    out = [head]
    for kind, rpc, u1, u2, u2role, ur, led, biz, foreign in SAFE_KINDS:
        k, k3 = f"KEY-{kind}-1", f"KEY-{kind}-3"
        st = lambda tag, user, tgt, key, var="a": f"select pb.step('{kind}', '{tag}', {('null' if user is None else repr(user))}, '{tgt}', '{key}', '{var}');"
        out += [f"-- ---- {kind}: {rpc}", f"select pb.snap('{kind}');", "set role authenticated;",
                st("s0_orig", u1, "1", k), st("s1_same_user_replay", u1, "1", k), st("s2_other_authorized_replay", u2, "1", k),
                st("s3_unauthenticated", None, "1", k), st("s4_unauthorized_role", ur, "1", k),
                st("s5_foreign_org_real_key", OWNER_B, "1", k), st("s6_foreign_org_wrong_key", OWNER_B, "1", k + "-WRONG"),
                "reset role;", f"update public.profiles set organization_id = null where id = '{u2}';", "set role authenticated;", st("s7_removed_member", u2, "1", k),
                "reset role;", f"update public.profiles set organization_id = '{B_ORG}' where id = '{u2}';", "set role authenticated;", st("s8_moved_member", u2, "1", k),
                "reset role;", f"update public.profiles set organization_id = '{A_ORG}', role = 'viewer' where id = '{u2}';", "set role authenticated;", st("s9_downgraded_member", u2, "1", k),
                "reset role;", f"update public.profiles set role = '{u2role}' where id = '{u2}';", "set role authenticated;",
                st("s10_changed_request", u1, "1", k, "b"), st("s11_same_key_other_target", u1, "2", k)]
        if foreign:
            out.append(st("s12_same_key_other_org", OWNER_B, "x1", k))
        out += ["reset role;", f"set td0149.boom = '{led}';", "set role authenticated;", st("s13_failed_tx", u1, "3", k3),
                "reset role;", "set td0149.boom = '';", "set role authenticated;",
                st("s14_retry_after_failure", u1, "3", k3), st("s15_retry_replays", u1, "3", k3), "reset role;", ""]
    out += ["\\pset format unaligned", "\\pset tuples_only on", f"\\pset fieldsep '{US}'",
            "select 'PROBE', kind, tag, outcome, msg, n_led, n_act, n_biz, biz from pb.rec order by seq;"]
    return "\n".join(out) + "\n"


def build_all():
    files = {"proposed_0152.sql": proposed(), "preflight.sql": preflight(), "post_apply.sql": post_apply(), "rollback.sql": rollback(), "matrix.sql": matrix_file(), "probe_safe_0144_0147.sql": probe_sql()}
    files.update(diffs())
    return files


if __name__ == "__main__":
    files = build_all()
    if "--check" in sys.argv:
        stale = [n for n, t in files.items() if not (HERE / n).exists() or (HERE / n).read_text() != t]
        print("stale: " + ", ".join(stale) if stale else "all generated files are current")
        sys.exit(1 if stale else 0)
    for n, t in files.items():
        (HERE / n).write_text(t)
        print(f"wrote {n} ({len(t)} bytes, sha256 {hashlib.sha256(t.encode()).hexdigest()[:16]})")
