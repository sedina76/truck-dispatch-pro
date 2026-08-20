"use server";

import { headers } from "next/headers";
import { createServiceRoleClient } from "@/lib/supabase/service-role";

// Forgot-email recovery (spec sections 14-15) -- privacy-safe lookup using
// data ALREADY in this app's schema (organizations.name + profiles.phone),
// never a new migration. Runs with the service-role client because the
// requester is, by definition, not authenticated yet (RLS would otherwise
// legitimately block this exact query for anyone outside the org) -- but
// the response surface is deliberately tiny: a single masked email string
// or nothing. No row, no role, no organization id, no other member's
// existence is ever returned.
//
// Two-factor match (org name AND the requester's own phone) rather than
// name alone, specifically to resist enumeration: a bare company-name
// search would let anyone iterate common company names and learn which
// ones exist in this system at all. Requiring a phone that must also
// match a specific profile row in that exact org means a wrong guess on
// EITHER factor produces the identical "no match" response as a
// nonexistent company -- an attacker learns nothing about which factor
// was wrong.

export type ForgotEmailResult = { ok: true; maskedEmail: string } | { ok: false };

function maskEmail(email: string): string {
  const [local, domain] = email.split("@");
  if (!local || !domain) return "••••@••••";
  return `${local[0]}••••@${domain}`;
}

// Simple in-memory, per-process rate limiter (spec section 15). No new
// migration/table for this -- acceptable for this app's current
// single-instance `next start` deployment; documented as a known
// limitation (does not survive a restart, not shared across multiple
// server instances) rather than silently pretended to be more robust than
// it is.
const ATTEMPTS = new Map<string, { count: number; resetAt: number }>();
const WINDOW_MS = 15 * 60 * 1000; // 15 minutes
const MAX_ATTEMPTS = 5;

async function rateLimitKey(): Promise<string> {
  const h = await headers();
  return h.get("x-forwarded-for")?.split(",")[0]?.trim() || h.get("x-real-ip") || "unknown";
}

async function isRateLimited(): Promise<boolean> {
  const key = await rateLimitKey();
  const now = Date.now();
  const entry = ATTEMPTS.get(key);
  if (!entry || now > entry.resetAt) {
    ATTEMPTS.set(key, { count: 1, resetAt: now + WINDOW_MS });
    return false;
  }
  entry.count += 1;
  return entry.count > MAX_ATTEMPTS;
}

export type ForgotEmailState = { status: "idle" | "rate_limited" | "checked"; result: ForgotEmailResult | null };

export async function lookupForgotEmail(_prev: ForgotEmailState, formData: FormData): Promise<ForgotEmailState> {
  if (await isRateLimited()) {
    return { status: "rate_limited", result: null };
  }

  const companyName = String(formData.get("companyName") || "").trim();
  const phone = String(formData.get("phone") || "").trim();
  if (!companyName || !phone) {
    return { status: "checked", result: { ok: false } };
  }

  const service = createServiceRoleClient();

  // Case-insensitive exact-ish match on organization name -- deliberately
  // not a fuzzy/partial search (a partial match would let a guesser
  // discover real company names by trial).
  const { data: orgs } = await service.from("organizations").select("id").ilike("name", companyName);
  if (!orgs || orgs.length !== 1) {
    return { status: "checked", result: { ok: false } };
  }

  const { data: profiles } = await service
    .from("profiles")
    .select("email")
    .eq("organization_id", orgs[0].id)
    .eq("phone", phone)
    .eq("is_active", true);

  // Exactly one match required -- zero (no match) and multiple (an
  // ambiguous/shared phone number) are BOTH treated as "no match," never
  // disambiguated for the caller, so this can never be used to enumerate
  // how many people at a company share a phone entry either.
  if (!profiles || profiles.length !== 1) {
    return { status: "checked", result: { ok: false } };
  }

  return { status: "checked", result: { ok: true, maskedEmail: maskEmail(profiles[0].email) } };
}
