import { NextResponse } from "next/server";
import { createClient } from "@/lib/supabase/server";
import { safeNext } from "@/lib/auth/oauth-providers";

// The PKCE code-exchange endpoint. Two kinds of visit land here:
//  - the password-recovery email link (`?code=...&next=/reset-password`);
//  - "Continue with Google / Microsoft" (`?flow=oauth&code=...`). A new
//    person then has no company yet and the app layout sends them to
//    company setup (/onboarding); an existing user goes to the dashboard.
// Signup by email does NOT use this route -- it's OTP-based (typed code).
export async function GET(request: Request) {
  const { searchParams, origin } = new URL(request.url);
  const code = searchParams.get("code");
  const oauth = searchParams.get("flow") === "oauth";
  const next = safeNext(searchParams.get("next"));

  if (code) {
    const supabase = await createClient();
    const { error } = await supabase.auth.exchangeCodeForSession(code);
    if (!error) {
      return NextResponse.redirect(`${origin}${next}`);
    }
  }

  // Cancelled / failed provider sign-in -> back to sign-in with a plain message.
  if (oauth || searchParams.get("error")) {
    return NextResponse.redirect(`${origin}/login?error=oauth`);
  }

  // Missing/invalid/expired recovery code -- send to reset-password so it
  // can show its own honest "link expired" state (spec section 13) rather
  // than a raw error page.
  return NextResponse.redirect(`${origin}/reset-password?error=invalid_link`);
}
