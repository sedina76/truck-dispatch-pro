"use client";

import { useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { Loader2, PenLine } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { useToast } from "@/components/ui/toast";
import { certifyAndGenerateMyDriverW9, saveMyDriverW9Draft, setMyDriverW9Tin } from "../../actions";
import { TAX_CLASSIFICATION_LABELS, isValidTinFormat, type W9TaxClassification, type W9TinType } from "@/lib/driver-w9/types";
import type { DriverW9Row } from "@/lib/driver-w9/types";

// Phase 2Q.2B -- mirrors src/app/carrier-onboarding/(portal)/w9/w9-form.tsx
// field-for-field (same form, same TIN-encryption boundary, same certify-
// then-generate-in-one-click UX) against the driver_w9s RPCs instead of
// carrier_w9s'. Not a copy/paste of a separate, less-secure
// implementation -- the plaintext TIN still only ever exists as one
// short-lived server-action argument, never stored/logged in this
// component.
const CLASSIFICATIONS = Object.entries(TAX_CLASSIFICATION_LABELS) as [W9TaxClassification, string][];

function Field({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <label className="block min-w-0 space-y-1 text-[12px] font-medium text-desktop-text">
      {label}
      {children}
    </label>
  );
}

export function DriverW9Form({ w9 }: { w9: DriverW9Row }) {
  const toast = useToast();
  const router = useRouter();
  const [saving, startSave] = useTransition();
  const [certifying, startCertify] = useTransition();

  const [nameOnTaxReturn, setNameOnTaxReturn] = useState(w9.name_on_tax_return ?? "");
  const [businessName, setBusinessName] = useState(w9.business_name ?? "");
  const [taxClassification, setTaxClassification] = useState<W9TaxClassification | "">(w9.tax_classification ?? "");
  const [llcClassification, setLlcClassification] = useState(w9.llc_classification ?? "");
  const [otherDescription, setOtherDescription] = useState(w9.other_classification_description ?? "");
  const [hasForeignPartners, setHasForeignPartners] = useState(w9.has_foreign_partners_owners);
  const [exemptPayeeCode, setExemptPayeeCode] = useState(w9.exempt_payee_code ?? "");
  const [fatcaCode, setFatcaCode] = useState(w9.fatca_exemption_code ?? "");
  const [addressLine1, setAddressLine1] = useState(w9.address_line1 ?? "");
  const [city, setCity] = useState(w9.city ?? "");
  const [state, setState] = useState(w9.state ?? "");
  const [postalCode, setPostalCode] = useState(w9.postal_code ?? "");
  const [tinType, setTinType] = useState<W9TinType>(w9.tin_type ?? "ssn");
  const [tin, setTin] = useState("");
  const [certifiedName, setCertifiedName] = useState("");
  const [certifiedTitle, setCertifiedTitle] = useState("");
  const [consentAccepted, setConsentAccepted] = useState(false);

  const showsForeignPartnersLine =
    taxClassification === "partnership" || taxClassification === "trust_estate" || (taxClassification === "llc" && llcClassification === "P");

  const canCertify =
    nameOnTaxReturn.trim().length > 0 &&
    taxClassification !== "" &&
    !(taxClassification === "llc" && !llcClassification) &&
    !(taxClassification === "other" && !otherDescription.trim()) &&
    addressLine1.trim().length > 0 &&
    city.trim().length > 0 &&
    state.trim().length > 0 &&
    postalCode.trim().length > 0 &&
    isValidTinFormat(tin) &&
    certifiedName.trim().length > 0 &&
    consentAccepted;

  function handleSaveDraft() {
    startSave(async () => {
      const result = await saveMyDriverW9Draft(w9.id, {
        nameOnTaxReturn, businessName, taxClassification: (taxClassification || "individual_sole_proprietor") as W9TaxClassification,
        llcClassification, otherClassificationDescription: otherDescription, hasForeignPartnersOwners: hasForeignPartners,
        exemptPayeeCode, fatcaExemptionCode: fatcaCode, addressLine1, city, state, postalCode,
      });
      if (!result.ok) toast.show("error", result.error);
      else toast.show("success", "Draft saved.");
    });
  }

  function handleCertify() {
    if (!isValidTinFormat(tin)) {
      toast.show("error", "Enter a 9-digit Social Security Number or Employer Identification Number.");
      return;
    }
    startCertify(async () => {
      const saveResult = await saveMyDriverW9Draft(w9.id, {
        nameOnTaxReturn, businessName, taxClassification: taxClassification as W9TaxClassification,
        llcClassification, otherClassificationDescription: otherDescription, hasForeignPartnersOwners: hasForeignPartners,
        exemptPayeeCode, fatcaExemptionCode: fatcaCode, addressLine1, city, state, postalCode,
      });
      if (!saveResult.ok) { toast.show("error", saveResult.error); return; }
      const tinResult = await setMyDriverW9Tin(w9.id, tinType, tin);
      if (!tinResult.ok) { toast.show("error", tinResult.error); return; }
      const result = await certifyAndGenerateMyDriverW9(w9.id, { certifiedName, certifiedTitle, tinType, tin });
      if (!result.ok) { toast.show("error", result.error); return; }
      toast.show("success", "W-9 certified and generated.");
      router.refresh();
    });
  }

  return (
    <div className="mt-4 min-w-0 space-y-5">
      <section className="min-w-0 space-y-3">
        <h3 className="text-[13px] font-semibold text-desktop-text">Taxpayer Information</h3>
        <div className="grid min-w-0 grid-cols-1 gap-3 sm:grid-cols-2">
          <Field label="Name of entity/individual (as shown on your tax return)">
            <Input value={nameOnTaxReturn} onChange={(e) => setNameOnTaxReturn(e.target.value)} className="w-full min-w-0" />
          </Field>
          <Field label="Business name/disregarded entity name (if different)">
            <Input value={businessName} onChange={(e) => setBusinessName(e.target.value)} className="w-full min-w-0" />
          </Field>
        </div>
      </section>

      <section className="min-w-0 space-y-3">
        <h3 className="text-[13px] font-semibold text-desktop-text">Federal Tax Classification</h3>
        <div className="grid min-w-0 grid-cols-1 gap-2 sm:grid-cols-2">
          {CLASSIFICATIONS.map(([value, label]) => (
            <label key={value} className="flex min-w-0 items-center gap-2 text-[13px] text-desktop-text">
              <input type="radio" name="tax_classification" checked={taxClassification === value} onChange={() => setTaxClassification(value)} className="size-4 shrink-0" />
              <span className="min-w-0 wrap-break-word">{label}</span>
            </label>
          ))}
        </div>
        {taxClassification === "llc" && (
          <Field label="LLC tax classification (C = C corporation, S = S corporation, P = Partnership)">
            <select value={llcClassification} onChange={(e) => setLlcClassification(e.target.value)} className="h-9 w-full min-w-0 rounded-sm border border-desktop-border bg-card px-2 text-[13px]">
              <option value="">Select...</option>
              <option value="C">C</option>
              <option value="S">S</option>
              <option value="P">P</option>
            </select>
          </Field>
        )}
        {taxClassification === "other" && (
          <Field label="Other (describe)">
            <Input value={otherDescription} onChange={(e) => setOtherDescription(e.target.value)} className="w-full min-w-0" />
          </Field>
        )}
        {showsForeignPartnersLine && (
          <label className="flex min-w-0 items-start gap-2 text-[12.5px] text-desktop-text">
            <input type="checkbox" checked={hasForeignPartners} onChange={(e) => setHasForeignPartners(e.target.checked)} className="mt-0.5 size-4 shrink-0" />
            <span className="min-w-0 wrap-break-word">I have foreign partners, owners, or beneficiaries in this partnership, trust, or estate.</span>
          </label>
        )}
      </section>

      <section className="min-w-0 space-y-3">
        <h3 className="text-[13px] font-semibold text-desktop-text">Exemptions (optional -- entities only, not individuals)</h3>
        <div className="grid min-w-0 grid-cols-1 gap-3 sm:grid-cols-2">
          <Field label="Exempt payee code (if any)">
            <Input value={exemptPayeeCode} onChange={(e) => setExemptPayeeCode(e.target.value)} className="w-full min-w-0" />
          </Field>
          <Field label="FATCA exemption code (if any)">
            <Input value={fatcaCode} onChange={(e) => setFatcaCode(e.target.value)} className="w-full min-w-0" />
          </Field>
        </div>
      </section>

      <section className="min-w-0 space-y-3">
        <h3 className="text-[13px] font-semibold text-desktop-text">Address</h3>
        <div className="grid min-w-0 grid-cols-1 gap-3">
          <Field label="Address (number, street, and apt. or suite no.)">
            <Input value={addressLine1} onChange={(e) => setAddressLine1(e.target.value)} className="w-full min-w-0" />
          </Field>
          <div className="grid min-w-0 grid-cols-1 gap-3 sm:grid-cols-3">
            <Field label="City">
              <Input value={city} onChange={(e) => setCity(e.target.value)} className="w-full min-w-0" />
            </Field>
            <Field label="State">
              <Input value={state} onChange={(e) => setState(e.target.value)} className="w-full min-w-0" />
            </Field>
            <Field label="ZIP code">
              <Input value={postalCode} onChange={(e) => setPostalCode(e.target.value)} className="w-full min-w-0" />
            </Field>
          </div>
        </div>
      </section>

      <section className="min-w-0 space-y-3">
        <h3 className="text-[13px] font-semibold text-desktop-text">Taxpayer Identification Number (TIN)</h3>
        <p className="text-[11.5px] text-muted-foreground">Enter your Social Security Number (individuals) or Employer Identification Number (most entities).</p>
        <div className="flex min-w-0 flex-wrap gap-4">
          <label className="flex items-center gap-1.5 text-[13px]"><input type="radio" checked={tinType === "ssn"} onChange={() => setTinType("ssn")} /> SSN</label>
          <label className="flex items-center gap-1.5 text-[13px]"><input type="radio" checked={tinType === "ein"} onChange={() => setTinType("ein")} /> EIN</label>
        </div>
        <Field label={tinType === "ssn" ? "Social Security Number" : "Employer Identification Number"}>
          <Input
            value={tin}
            onChange={(e) => setTin(e.target.value)}
            placeholder={tinType === "ssn" ? "XXX-XX-XXXX" : "XX-XXXXXXX"}
            className={`w-full min-w-0 max-w-xs font-mono ${tin && !isValidTinFormat(tin) ? "border-destructive" : ""}`}
          />
        </Field>
        <p className="text-[11px] text-muted-foreground">Your number is encrypted immediately and is never shown in full again -- only the last 4 digits are displayed after this step.</p>
      </section>

      <section className="min-w-0 space-y-3 border-t border-desktop-border pt-4">
        <h3 className="text-[13px] font-semibold text-desktop-text">Certification</h3>
        <div className="rounded-sm border border-desktop-border bg-desktop-bg p-3 text-[12px] leading-relaxed text-muted-foreground">
          <p className="font-medium text-desktop-text">Under penalties of perjury, I certify that:</p>
          <p className="mt-1">
            1. The number shown on this form is my correct taxpayer identification number; and 2. I am not subject to backup withholding for the reasons
            stated on Form W-9; and 3. I am a U.S. citizen or other U.S. person; and 4. The FATCA code(s) entered on this form, if any, are correct.
          </p>
        </div>
        <label className="flex min-w-0 items-start gap-2 text-[13px] text-desktop-text">
          <input type="checkbox" checked={consentAccepted} onChange={(e) => setConsentAccepted(e.target.checked)} className="mt-0.5 size-4 shrink-0" />
          <span className="min-w-0 wrap-break-word">
            I agree to use electronic records and signatures, and I certify the statements above under penalties of perjury.
          </span>
        </label>
        <div className="grid min-w-0 grid-cols-1 gap-3 sm:grid-cols-2">
          <Field label="Full Legal Name (electronic signature)">
            <Input value={certifiedName} onChange={(e) => setCertifiedName(e.target.value)} className={`w-full min-w-0 font-serif text-base italic ${certifiedName ? "border-primary" : ""}`} />
          </Field>
          <Field label="Title (if applicable)">
            <Input value={certifiedTitle} onChange={(e) => setCertifiedTitle(e.target.value)} className="w-full min-w-0" />
          </Field>
        </div>
      </section>

      <div className="flex flex-wrap justify-end gap-2 border-t border-desktop-border pt-4">
        <Button type="button" variant="outline" disabled={saving || certifying} onClick={handleSaveDraft}>
          {saving ? <Loader2 className="size-3.5 animate-spin" /> : null} Save Draft
        </Button>
        <Button type="button" disabled={!canCertify || certifying} onClick={handleCertify}>
          {certifying ? <Loader2 className="size-3.5 animate-spin" /> : <PenLine className="size-3.5" />}
          {certifying ? "Certifying..." : "Certify & Generate W-9"}
        </Button>
      </div>
    </div>
  );
}
