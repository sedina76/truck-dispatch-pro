"use client";

import { useState } from "react";
import { Loader2 } from "lucide-react";
import { createClient } from "@/lib/supabase/client";
import { enabledProviders, PROVIDER_LABEL, type OAuthProvider } from "@/lib/auth/oauth-providers";
import { cn } from "@/lib/utils";

const PROVIDERS = enabledProviders(process.env.NEXT_PUBLIC_AUTH_PROVIDERS);

// Each provider's official logo file, if one has been added to /public/brand
// (google.svg, microsoft.svg -- the artwork each company publishes for
// sign-in buttons). No file = the button simply shows its text.
const LOGO: Record<OAuthProvider, string> = { google: "/brand/google.svg", azure: "/brand/microsoft.svg" };

// "Continue with Google / Microsoft". New people land on company setup
// (onboarding) after the provider sends them back; existing users land on
// their dashboard. Renders nothing until a provider is switched on.
export function OAuthButtons({ mode, dark = false }: { mode: "signin" | "signup"; dark?: boolean }) {
  const [busy, setBusy] = useState<OAuthProvider | null>(null);
  const [error, setError] = useState<string | null>(null);
  if (PROVIDERS.length === 0) return null;

  async function go(provider: OAuthProvider) {
    setBusy(provider);
    setError(null);
    const supabase = createClient();
    const { error: err } = await supabase.auth.signInWithOAuth({
      provider,
      options: {
        redirectTo: `${window.location.origin}/auth/callback?flow=oauth&next=/dashboard`,
        ...(provider === "azure" ? { scopes: "email" } : {}),
      },
    });
    if (err) {
      setBusy(null);
      setError(`${PROVIDER_LABEL[provider]} sign-in isn't available right now. Use your email and password instead.`);
    }
  }

  return (
    <div className="space-y-4" data-testid="oauth-buttons">
      <div className="space-y-2.5">
        {PROVIDERS.map((p) => (
          <button
            key={p}
            type="button"
            onClick={() => go(p)}
            disabled={busy !== null}
            className={cn(
              "flex h-11 w-full items-center justify-center gap-2 rounded-md border text-[14.5px] font-semibold transition-colors disabled:opacity-60",
              dark ? "border-white/20 bg-white text-[#1a1a18] hover:bg-white/90" : "border-[#d9d9d4] bg-white text-[#1a1a18] hover:bg-[#f2f2ef]"
            )}
          >
            {busy === p ? (
              <Loader2 className="size-[18px] animate-spin" />
            ) : (
              // Google's official icon-only file is a 40x40 button with the "G" in
              // its middle 20x20; show just that middle part (the file itself is
              // used unchanged), so the "G" sits at text size without a box.
              <span className="relative size-[18px] shrink-0 overflow-hidden" aria-hidden="true">
                {/* eslint-disable-next-line @next/next/no-img-element -- tiny static brand file, may be absent */}
                <img
                  src={LOGO[p]}
                  alt=""
                  width={36}
                  height={36}
                  className="absolute left-[-9px] top-[-9px] size-9 max-w-none"
                  onError={(e) => ((e.currentTarget.parentElement as HTMLElement).style.display = "none")}
                />
              </span>
            )}
            {mode === "signup" ? "Sign up" : "Continue"} with {PROVIDER_LABEL[p]}
          </button>
        ))}
      </div>
      {error && (
        <p role="alert" className="text-sm text-danger">
          {error}
        </p>
      )}
      <div className={cn("flex items-center gap-3 text-xs uppercase tracking-wide", dark ? "text-white/40" : "text-[#8a8a83]")}>
        <span className={cn("h-px flex-1", dark ? "bg-white/15" : "bg-[#e4e4e0]")} />
        or use your email
        <span className={cn("h-px flex-1", dark ? "bg-white/15" : "bg-[#e4e4e0]")} />
      </div>
    </div>
  );
}
