"use client";

import { useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { Loader2 } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { useToast } from "@/components/ui/toast";
import { saveDriverPersonalInfo } from "../../actions";

function Field({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <label className="block min-w-0 space-y-1 text-[12px] font-medium text-desktop-text">
      {label}
      {children}
    </label>
  );
}

type Application = {
  first_name: string;
  middle_name: string | null;
  last_name: string;
  phone: string | null;
  email: string | null;
  date_of_birth: string | null;
  address_line1: string | null;
  city: string | null;
  state: string | null;
  postal_code: string | null;
  emergency_contact_name: string | null;
  emergency_contact_phone: string | null;
};

export function PersonalInfoForm({ application }: { application: Application }) {
  const toast = useToast();
  const router = useRouter();
  const [saving, startSave] = useTransition();

  const [firstName, setFirstName] = useState(application.first_name ?? "");
  const [middleName, setMiddleName] = useState(application.middle_name ?? "");
  const [lastName, setLastName] = useState(application.last_name ?? "");
  const [phone, setPhone] = useState(application.phone ?? "");
  const [email, setEmail] = useState(application.email ?? "");
  const [dob, setDob] = useState(application.date_of_birth ?? "");
  const [addressLine1, setAddressLine1] = useState(application.address_line1 ?? "");
  const [city, setCity] = useState(application.city ?? "");
  const [state, setState] = useState(application.state ?? "");
  const [postalCode, setPostalCode] = useState(application.postal_code ?? "");
  const [emergencyName, setEmergencyName] = useState(application.emergency_contact_name ?? "");
  const [emergencyPhone, setEmergencyPhone] = useState(application.emergency_contact_phone ?? "");

  function buildFormData() {
    const fd = new FormData();
    fd.set("first_name", firstName);
    fd.set("middle_name", middleName);
    fd.set("last_name", lastName);
    fd.set("phone", phone);
    fd.set("email", email);
    fd.set("date_of_birth", dob);
    fd.set("address_line1", addressLine1);
    fd.set("city", city);
    fd.set("state", state);
    fd.set("postal_code", postalCode);
    fd.set("emergency_contact_name", emergencyName);
    fd.set("emergency_contact_phone", emergencyPhone);
    return fd;
  }

  function handleContinue() {
    startSave(async () => {
      const result = await saveDriverPersonalInfo(buildFormData());
      if (!result.ok) { toast.show("error", result.error); return; }
      router.push("/driver-onboarding/license");
    });
  }

  return (
    <div className="min-w-0 space-y-5 rounded-md border border-desktop-border bg-card p-4 sm:p-5">
      <h2 className="text-[15px] font-semibold text-desktop-text">Personal Information</h2>

      <div className="grid min-w-0 grid-cols-1 gap-3 sm:grid-cols-2">
        <Field label="Legal first name"><Input value={firstName} onChange={(e) => setFirstName(e.target.value)} className="w-full min-w-0" /></Field>
        <Field label="Middle name (if used)"><Input value={middleName} onChange={(e) => setMiddleName(e.target.value)} className="w-full min-w-0" /></Field>
        <Field label="Legal last name"><Input value={lastName} onChange={(e) => setLastName(e.target.value)} className="w-full min-w-0" /></Field>
        <Field label="Date of birth"><Input type="date" value={dob} onChange={(e) => setDob(e.target.value)} className="w-full min-w-0" /></Field>
        <Field label="Phone"><Input type="tel" value={phone} onChange={(e) => setPhone(e.target.value)} className="w-full min-w-0" /></Field>
        <Field label="Email"><Input type="email" value={email} onChange={(e) => setEmail(e.target.value)} className="w-full min-w-0" /></Field>
      </div>

      <div className="space-y-3">
        <h3 className="text-[13px] font-semibold text-desktop-text">Address</h3>
        <Field label="Address"><Input value={addressLine1} onChange={(e) => setAddressLine1(e.target.value)} className="w-full min-w-0" /></Field>
        <div className="grid min-w-0 grid-cols-1 gap-3 sm:grid-cols-3">
          <Field label="City"><Input value={city} onChange={(e) => setCity(e.target.value)} className="w-full min-w-0" /></Field>
          <Field label="State"><Input value={state} onChange={(e) => setState(e.target.value)} className="w-full min-w-0" /></Field>
          <Field label="ZIP code"><Input value={postalCode} onChange={(e) => setPostalCode(e.target.value)} className="w-full min-w-0" /></Field>
        </div>
      </div>

      <div className="space-y-3">
        <h3 className="text-[13px] font-semibold text-desktop-text">Emergency Contact</h3>
        <div className="grid min-w-0 grid-cols-1 gap-3 sm:grid-cols-2">
          <Field label="Name"><Input value={emergencyName} onChange={(e) => setEmergencyName(e.target.value)} className="w-full min-w-0" /></Field>
          <Field label="Phone"><Input type="tel" value={emergencyPhone} onChange={(e) => setEmergencyPhone(e.target.value)} className="w-full min-w-0" /></Field>
        </div>
      </div>

      <div className="flex justify-end border-t border-desktop-border pt-4">
        <Button type="button" disabled={saving} onClick={handleContinue} className="h-11 w-full sm:w-auto">
          {saving ? <Loader2 className="size-4 animate-spin" /> : null} Save &amp; Continue
        </Button>
      </div>
    </div>
  );
}
