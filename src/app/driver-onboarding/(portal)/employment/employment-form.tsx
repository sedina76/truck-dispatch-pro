"use client";

import { useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { Loader2 } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { useToast } from "@/components/ui/toast";
import { saveDriverEmploymentInfo } from "../../actions";

type Application = {
  years_of_experience: number | null;
  equipment_experience: string | null;
  has_been_convicted_of_dui: boolean | null;
  has_had_license_suspended: boolean | null;
  has_had_preventable_accident: boolean | null;
  driving_record_explanation: string | null;
};

function YesNo({ label, value, onChange }: { label: string; value: boolean | null; onChange: (v: boolean) => void }) {
  return (
    <div className="flex flex-wrap items-center justify-between gap-2 text-[13px] text-desktop-text">
      <span>{label}</span>
      <div className="flex gap-3">
        <label className="flex items-center gap-1.5"><input type="radio" checked={value === false} onChange={() => onChange(false)} /> No</label>
        <label className="flex items-center gap-1.5"><input type="radio" checked={value === true} onChange={() => onChange(true)} /> Yes</label>
      </div>
    </div>
  );
}

// Self-disclosed driving record, same fields/wording the existing public
// /driver-application form already collects (0018) -- reused, not
// reinvented. This app has no MVR/background-check integration, so none
// of this is presented as a verified/pulled record.
export function EmploymentForm({ application }: { application: Application }) {
  const toast = useToast();
  const router = useRouter();
  const [saving, startSave] = useTransition();

  const [years, setYears] = useState(application.years_of_experience != null ? String(application.years_of_experience) : "");
  const [equipment, setEquipment] = useState(application.equipment_experience ?? "");
  const [dui, setDui] = useState<boolean | null>(application.has_been_convicted_of_dui);
  const [suspended, setSuspended] = useState<boolean | null>(application.has_had_license_suspended);
  const [accident, setAccident] = useState<boolean | null>(application.has_had_preventable_accident);
  const [explanation, setExplanation] = useState(application.driving_record_explanation ?? "");

  const needsExplanation = dui === true || suspended === true || accident === true;

  function handleContinue() {
    startSave(async () => {
      const fd = new FormData();
      fd.set("years_of_experience", years);
      fd.set("equipment_experience", equipment);
      if (dui !== null) fd.set("has_been_convicted_of_dui", dui ? "on" : "off");
      if (suspended !== null) fd.set("has_had_license_suspended", suspended ? "on" : "off");
      if (accident !== null) fd.set("has_had_preventable_accident", accident ? "on" : "off");
      fd.set("driving_record_explanation", explanation);
      const result = await saveDriverEmploymentInfo(fd);
      if (!result.ok) { toast.show("error", result.error); return; }
      router.push("/driver-onboarding/tax-w9");
    });
  }

  return (
    <div className="min-w-0 space-y-5 rounded-md border border-desktop-border bg-card p-4 sm:p-5">
      <h2 className="text-[15px] font-semibold text-desktop-text">Driving &amp; Employment Information</h2>

      <div className="grid min-w-0 grid-cols-1 gap-3 sm:grid-cols-2">
        <label className="block min-w-0 space-y-1 text-[12px] font-medium text-desktop-text">
          Years of driving experience
          <Input type="number" min="0" step="0.5" value={years} onChange={(e) => setYears(e.target.value)} className="w-full min-w-0" />
        </label>
        <label className="block min-w-0 space-y-1 text-[12px] font-medium text-desktop-text">
          Equipment experience
          <Input value={equipment} onChange={(e) => setEquipment(e.target.value)} className="w-full min-w-0" placeholder="e.g. dry van, reefer, flatbed" />
        </label>
      </div>

      <div className="space-y-2 border-t border-desktop-border pt-4">
        <h3 className="text-[13px] font-semibold text-desktop-text">Driving Record (self-reported)</h3>
        <YesNo label="Convicted of DUI/DWI in the last 5 years?" value={dui} onChange={setDui} />
        <YesNo label="License ever suspended or revoked?" value={suspended} onChange={setSuspended} />
        <YesNo label="Preventable accident in the last 3 years?" value={accident} onChange={setAccident} />
        {needsExplanation && (
          <label className="block min-w-0 space-y-1 text-[12px] font-medium text-desktop-text">
            Please explain
            <textarea
              value={explanation}
              onChange={(e) => setExplanation(e.target.value)}
              rows={3}
              className="w-full min-w-0 rounded-sm border border-desktop-border bg-card px-3 py-2 text-[13px]"
            />
          </label>
        )}
      </div>

      <div className="flex justify-end border-t border-desktop-border pt-4">
        <Button type="button" disabled={saving} onClick={handleContinue} className="h-11 w-full sm:w-auto">
          {saving ? <Loader2 className="size-4 animate-spin" /> : null} Save &amp; Continue
        </Button>
      </div>
    </div>
  );
}
