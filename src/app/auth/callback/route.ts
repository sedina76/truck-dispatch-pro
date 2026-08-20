import { NextResponse } from "next/server";
import { createClient } from "@/lib/supabase/server";

// The one PKCE code-exchange endpoint this app needs (spec section 12) --
// used exclusively by the password-recovery email link today. Supabase's
// @supabase/ssr server client uses the PKCE flow by default, so a
// recovery link lands here with a `?code=...` that must be exchanged for
// a real (short-lived, recovery-scoped) session BEFORE the visitor can
// reach /reset-password and call auth.updateUser(). Signup verification
// does NOT use this route -- it's OTP-based (verifySignupOtp(), typed
// code, no link/redirect at all).
export async function GET(request: Request) {
  const { searchParams, origin } = new URL(request.url);
  const code = searchParams.get("code");
  const next = searchParams.get("next") ?? "/dashboard";

  if (code) {
    const supabase = await createClient();
    const { error } = await supabase.auth.exchangeCodeForSession(code);
    if (!error) {
      return NextResponse.redirect(`${origin}${next}`);
    }
  }

  // Missing/invalid/expired code -- send to reset-password so it can show
  // its own honest "link expired" state (spec section 13) rather than a
  // raw error page.
  return NextResponse.redirect(`${origin}/reset-password?error=invalid_link`);
}
