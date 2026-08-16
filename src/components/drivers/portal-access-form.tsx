"use client";

import { useState, useTransition } from "react";
import { Smartphone, ShieldOff } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";

export function PortalAccessForm({
  driverId,
  isActive,
  currentPhone,
  lastLoginAt,
  onSetPin,
  onRevoke,
}: {
  driverId: string;
  isActive: boolean;
  currentPhone: string | null;
  lastLoginAt: string | null;
  onSetPin: (driverId: string, formData: FormData) => Promise<void>;
  onRevoke: (driverId: string) => Promise<void>;
}) {
  const [phone, setPhone] = useState(currentPhone ?? "");
  const [pin, setPin] = useState("");
  const [pending, startTransition] = useTransition();
  const [saved, setSaved] = useState(false);

  return (
    <div className="space-y-3">
      {isActive && (
        <p className="text-xs text-success">
          Portal access enabled{currentPhone ? ` -- ${currentPhone}` : ""}.{" "}
          {lastLoginAt ? `Last login ${new Date(lastLoginAt).toLocaleString()}.` : "Never logged in yet."}
        </p>
      )}

      <form
        onSubmit={(e) => {
          e.preventDefault();
          if (!phone.trim() || !pin.trim()) return;
          const formData = new FormData();
          formData.set("portal_phone", phone.trim());
          formData.set("portal_pin", pin.trim());
          startTransition(async () => {
            await onSetPin(driverId, formData);
            setPin("");
            setSaved(true);
            setTimeout(() => setSaved(false), 2500);
          });
        }}
        className="flex flex-wrap items-end gap-2"
      >
        <div className="space-y-1">
          <label className="text-xs font-medium text-muted-foreground">Phone number</label>
          <Input
            type="tel"
            value={phone}
            onChange={(e) => setPhone(e.target.value)}
            placeholder="(555) 123-4567"
            className="h-9 w-40"
          />
        </div>
        <div className="space-y-1">
          <label className="text-xs font-medium text-muted-foreground">{isActive ? "New PIN" : "PIN"}</label>
          <Input
            type="password"
            inputMode="numeric"
            maxLength={6}
            value={pin}
            onChange={(e) => setPin(e.target.value.replace(/[^0-9]/g, ""))}
            placeholder="4-6 digits"
            className="h-9 w-32 font-mono"
          />
        </div>
        <Button type="submit" size="sm" variant="outline" disabled={pending || !phone.trim() || !pin.trim()} className="gap-1.5">
          <Smartphone className="size-3.5" />
          {pending ? "Saving..." : saved ? "Saved" : isActive ? "Reset PIN" : "Grant Access"}
        </Button>
        {isActive && (
          <Button
            type="button"
            size="sm"
            variant="danger"
            className="gap-1.5"
            onClick={() => startTransition(() => onRevoke(driverId))}
          >
            <ShieldOff className="size-3.5" />
            Revoke
          </Button>
        )}
      </form>
    </div>
  );
}
