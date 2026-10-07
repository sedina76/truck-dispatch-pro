"use client";

import { useEffect, useState } from "react";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { Truck, Eye, EyeOff, Loader2 } from "lucide-react";
import { rememberedPhone, rememberPhone } from "@/lib/driver-portal/remember-phone";
import { driverInputClass as inputClass, driverPrimaryButtonClass } from "@/lib/driver-portal/ui";

// Driver Portal sign-in: phone + PIN against /api/driver-portal/login
// (verify_driver_portal_login), never Supabase Auth. Built for a phone in
// one hand at a truck stop: 16px+ text (no iPhone zoom-on-focus), 48px
// fields and buttons, numeric keypads, the phone number remembered on this
// device, and a "Forgot PIN?" path.
export default function DriverPortalLoginPage() {
  const router = useRouter();
  const [phone, setPhone] = useState("");
  const [pin, setPin] = useState("");
  const [showPin, setShowPin] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [submitting, setSubmitting] = useState(false);

  useEffect(() => {
    const saved = rememberedPhone();
    if (saved) setPhone(saved);
  }, []);

  async function onSubmit(e: React.FormEvent) {
    e.preventDefault();
    setSubmitting(true);
    setError(null);

    const res = await fetch("/api/driver-portal/login", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ phone, pin }),
    }).catch(() => null);

    if (!res || !res.ok) {
      const body = res ? await res.json().catch(() => null) : null;
      setError(body?.error ?? (res ? "Login failed." : "No connection. Check your signal and try again."));
      setSubmitting(false);
      return;
    }

    rememberPhone(phone);
    router.push("/driver-portal");
    router.refresh();
  }

  return (
    <div className="flex flex-1 flex-col justify-center">
      <div className="mx-auto w-full max-w-sm">
        <div className="mb-8 flex flex-col items-center gap-2 text-center">
          <div className="flex size-14 items-center justify-center rounded-2xl bg-primary/10 text-primary">
            <Truck className="size-7" />
          </div>
          <p className="text-xs font-medium tracking-wide text-muted-foreground">Truck Dispatch Pro</p>
          <h1 className="text-2xl font-semibold tracking-tight">Driver Portal</h1>
          <p className="text-base text-muted-foreground">Sign in with your phone number and PIN.</p>
        </div>

        <form onSubmit={onSubmit} className="space-y-4">
          <div className="space-y-1.5">
            <label className="text-sm font-medium" htmlFor="phone">
              Phone number
            </label>
            <input
              id="phone"
              type="tel"
              inputMode="tel"
              autoComplete="tel"
              placeholder="(555) 123-4567"
              value={phone}
              onChange={(e) => setPhone(e.target.value)}
              required
              className={inputClass}
            />
          </div>

          <div className="space-y-1.5">
            <div className="flex items-baseline justify-between">
              <label className="text-sm font-medium" htmlFor="pin">
                PIN
              </label>
              <Link href={`/driver-portal/forgot-pin${phone ? `?phone=${encodeURIComponent(phone)}` : ""}`} className="py-1 text-sm font-medium text-primary">
                Forgot PIN?
              </Link>
            </div>
            <div className="relative">
              <input
                id="pin"
                type={showPin ? "text" : "password"}
                inputMode="numeric"
                pattern="[0-9]*"
                autoComplete="current-password"
                maxLength={6}
                placeholder="4-6 digits"
                value={pin}
                onChange={(e) => setPin(e.target.value.replace(/[^0-9]/g, ""))}
                required
                className={`${inputClass} pr-12 tracking-widest`}
              />
              <button
                type="button"
                onClick={() => setShowPin((v) => !v)}
                aria-label={showPin ? "Hide PIN" : "Show PIN"}
                className="absolute inset-y-0 right-0 flex w-12 items-center justify-center text-muted-foreground"
              >
                {showPin ? <EyeOff className="size-5" /> : <Eye className="size-5" />}
              </button>
            </div>
          </div>

          {error && (
            <p role="alert" className="rounded-lg bg-danger/10 px-3 py-2 text-sm text-danger">
              {error}
            </p>
          )}

          <button
            type="submit"
            disabled={submitting}
            className={driverPrimaryButtonClass}
          >
            {submitting && <Loader2 className="size-5 animate-spin" />}
            {submitting ? "Signing in..." : "Sign In"}
          </button>
        </form>

        <p className="mt-6 text-center text-sm text-muted-foreground">
          Don&apos;t have portal access yet? Ask your dispatcher to set up your phone number and PIN.
        </p>
      </div>
    </div>
  );
}
