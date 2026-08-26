"use client";

import { useTransition } from "react";
import { useRouter } from "next/navigation";
import { FormField, FormGrid } from "@/components/ui/form-field";
import { Button } from "@/components/ui/button";
import { useToast } from "@/components/ui/toast";
import { saveCompanyInfo, type MyApplication } from "../../actions";

export function CompanyForm({ application }: { application: MyApplication }) {
  const toast = useToast();
  const router = useRouter();
  const [saving, startSave] = useTransition();

  function handleSubmit(e: React.FormEvent<HTMLFormElement>) {
    e.preventDefault();
    const formData = new FormData(e.currentTarget);
    // Which button was actually clicked -- native SubmitEvent.submitter,
    // so one <form> can offer both "Save Progress" and "Continue" without
    // two separate onSubmit paths fighting over e.currentTarget.
    const submitter = (e.nativeEvent as SubmitEvent).submitter as HTMLButtonElement | null;
    const continueNext = submitter?.name !== "save_only";
    startSave(async () => {
      const result = await saveCompanyInfo(formData);
      if (!result.ok) {
        toast.show("error", result.error);
        return;
      }
      if (continueNext) {
        router.push("/carrier-onboarding/w9");
      } else {
        toast.show("success", "Saved.");
      }
    });
  }

  return (
    <form className="mt-4 space-y-4" onSubmit={handleSubmit}>
      <FormGrid>
        <FormField label="Legal Company Name" name="legal_name" defaultValue={application.legalName} required />
        <FormField label="DBA (if any)" name="dba_name" defaultValue={application.dbaName} />
        <FormField label="Contact Name" name="contact_name" defaultValue={application.contactName} required />
        <FormField label="Email" name="email" type="email" defaultValue={application.email} required />
        <FormField label="Phone" name="phone" type="tel" defaultValue={application.phone} required />
        <FormField label="MC Number" name="mc_number" defaultValue={application.mcNumber} placeholder="MC-123456" />
        <FormField label="USDOT Number" name="dot_number" defaultValue={application.dotNumber} placeholder="DOT-1234567" />
      </FormGrid>

      <div className="border-t border-desktop-border pt-4">
        <p className="text-[12.5px] font-semibold text-desktop-text">Address</p>
        <FormGrid>
          <FormField label="Address Line 1" name="address_line1" defaultValue={application.addressLine1} />
          <FormField label="Address Line 2" name="address_line2" defaultValue={application.addressLine2} />
          <FormField label="City" name="city" defaultValue={application.city} />
          <FormField label="State" name="state" defaultValue={application.state} placeholder="IL" />
          <FormField label="ZIP" name="postal_code" defaultValue={application.postalCode} />
        </FormGrid>
      </div>

      <div className="border-t border-desktop-border pt-4">
        <p className="text-[12.5px] font-semibold text-desktop-text">Tax ID</p>
        <p className="mt-0.5 text-[12px] text-muted-foreground">
          {application.einLast4 ? `On file: •••••${application.einLast4}. Leave blank to keep it unchanged.` : "Your EIN is encrypted and never shown back to you or our staff in full."}
        </p>
        <div className="mt-2 max-w-xs">
          <FormField label="EIN" name="ein" placeholder="XX-XXXXXXX" />
        </div>
      </div>

      <div className="border-t border-desktop-border pt-4">
        <p className="text-[12.5px] font-semibold text-desktop-text">Factoring (optional)</p>
        <FormGrid>
          <FormField label="Factoring Company" name="factoring_company_name" defaultValue={application.factoringCompanyName} />
        </FormGrid>
        <label className="mt-2 flex items-center gap-2 text-[13px] text-desktop-text">
          <input type="checkbox" name="has_factoring" defaultChecked={application.hasFactoring ?? false} className="size-4 rounded-sm border-desktop-border" />
          I use a factoring company
        </label>
      </div>

      <div className="flex flex-col-reverse gap-2 border-t border-desktop-border pt-4 sm:flex-row sm:justify-end">
        <Button type="submit" name="save_only" variant="outline" disabled={saving}>
          Save Progress
        </Button>
        <Button type="submit" disabled={saving}>
          {saving ? "Saving..." : "Continue to Equipment"}
        </Button>
      </div>
    </form>
  );
}
