"use client";

import { useEffect, useState } from "react";
import Link from "next/link";
import { useRouter, useSearchParams } from "next/navigation";
import { KeyRound, ArrowLeft, Loader2, MailCheck } from "lucide-react";
import { rememberedPhone, rememberPhone } from "@/lib/driver-portal/remember-phone";
import { driverInputClass, driverPrimaryButtonClass } from "@/lib/driver-portal/ui";

// Two steps: (1) phone number -> a 6-digit code is emailed and the office is
// told; (2) code + new PIN -> signed straight in. See the
// /api/driver-portal/pin-reset routes and migration 0172.
export function ForgotPinForm() {
  const router = useRouter();
  const params = useSearchParams();
  const [step, setStep] = useState<"phone" | "code">("phone");
  const [phone, setPhone] = useState(params.get("phone") ?? "");
  const [code, setCode] = useState("");
  const [pin, setPin] = useState("");
  const [confirm, setConfirm] = useState("");
  const [notice, setNotice] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    if (!params.get("phone")) {
      const saved = rememberedPhone();
      if (saved) setPhone(saved);
    }
  }, [params]);

  async function post(path: string, body: unknown) {
    const res = await fetch(path, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) }).catch(() => null);
    const json = res ? await res.json().catch(() => null) : null;
    return { ok: !!res?.ok, json, offline: !res };
  }

  async function requestCode(e: React.FormEvent) {
    e.preventDefault();
    setBusy(true);
    setError(null);
    const { ok, json, offline } = await post("/api/driver-portal/pin-reset/request", { phone });
    setBusy(false);
    if (!ok) {
      setError(offline ? "No connection. Check your signal and try again." : json?.error ?? "Something went wrong. Try again.");
      return;
    }
    setNotice(json?.message ?? null);
    setStep("code");
  }

  async function setNewPin(e: React.FormEvent) {
    e.preventDefault();
    setBusy(true);
    setError(null);
    const { ok, json, offline } = await post("/api/driver-portal/pin-reset/confirm", { phone, code, pin, confirm });
    if (!ok) {
      setBusy(false);
      setError(offline ? "No connection. Check your signal and try again." : json?.error ?? "Could not reset your PIN. Try again.");
      return;
    }
    rememberPhone(phone);
    router.push("/driver-portal");
    router.refresh();
  }

  return (
    <div className="flex flex-1 flex-col justify-center">
      <div className="mx-auto w-full max-w-sm">
        <Link href="/driver-portal/login" className="mb-6 inline-flex h-11 items-center gap-1.5 text-sm font-medium text-muted-foreground">
          <ArrowLeft className="size-4" /> Back to sign in
        </Link>

        <div className="mb-6 flex flex-col items-center gap-2 text-center">
          <div className="flex size-14 items-center justify-center rounded-2xl bg-primary/10 text-primary">
            {step === "phone" ? <KeyRound className="size-7" /> : <MailCheck className="size-7" />}
          </div>
          <h1 className="text-2xl font-semibold tracking-tight">{step === "phone" ? "Forgot your PIN?" : "Enter your code"}</h1>
          <p className="text-base text-muted-foreground">
            {step === "phone"
              ? "Enter the phone number you sign in with. We'll email a code to the address on your driver record."
              : "Type the 6-digit code from the email, then choose a new PIN."}
          </p>
        </div>

        {step === "phone" ? (
          <form onSubmit={requestCode} className="space-y-4">
            <div className="space-y-1.5">
              <label className="text-sm font-medium" htmlFor="phone">Phone number</label>
              <input id="phone" type="tel" inputMode="tel" autoComplete="tel" placeholder="(555) 123-4567" value={phone} onChange={(e) => setPhone(e.target.value)} required className={driverInputClass} />
            </div>
            {error && <p role="alert" className="rounded-lg bg-danger/10 px-3 py-2 text-sm text-danger">{error}</p>}
            <button type="submit" disabled={busy} className={driverPrimaryButtonClass}>
              {busy && <Loader2 className="size-5 animate-spin" />} Email me a code
            </button>
          </form>
        ) : (
          <form onSubmit={setNewPin} className="space-y-4">
            {notice && <p role="status" className="rounded-lg bg-primary/10 px-3 py-2.5 text-sm text-foreground">{notice}</p>}
            <div className="space-y-1.5">
              <label className="text-sm font-medium" htmlFor="code">6-digit code</label>
              <input
                id="code"
                inputMode="numeric"
                pattern="[0-9]*"
                autoComplete="one-time-code"
                maxLength={6}
                placeholder="123456"
                value={code}
                onChange={(e) => setCode(e.target.value.replace(/\D/g, ""))}
                required
                className={`${driverInputClass} text-center text-xl tracking-[0.4em]`}
              />
            </div>
            <div className="grid grid-cols-2 gap-3">
              <div className="space-y-1.5">
                <label className="text-sm font-medium" htmlFor="pin">New PIN</label>
                <input id="pin" type="password" inputMode="numeric" pattern="[0-9]*" autoComplete="new-password" maxLength={6} placeholder="4-6 digits" value={pin} onChange={(e) => setPin(e.target.value.replace(/\D/g, ""))} required className={`${driverInputClass} tracking-widest`} />
              </div>
              <div className="space-y-1.5">
                <label className="text-sm font-medium" htmlFor="confirm">Repeat PIN</label>
                <input id="confirm" type="password" inputMode="numeric" pattern="[0-9]*" autoComplete="new-password" maxLength={6} placeholder="Again" value={confirm} onChange={(e) => setConfirm(e.target.value.replace(/\D/g, ""))} required className={`${driverInputClass} tracking-widest`} />
              </div>
            </div>
            {error && <p role="alert" className="rounded-lg bg-danger/10 px-3 py-2 text-sm text-danger">{error}</p>}
            <button type="submit" disabled={busy} className={driverPrimaryButtonClass}>
              {busy && <Loader2 className="size-5 animate-spin" />} Set PIN and sign in
            </button>
            <button type="button" disabled={busy} onClick={() => { setStep("phone"); setError(null); setCode(""); }} className="h-11 w-full text-sm font-medium text-primary">
              Didn&apos;t get it? Send a new code
            </button>
          </form>
        )}
      </div>
    </div>
  );
}
