"use client";

import { useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { Button } from "@/components/ui/button";
import { FormField, FormGrid } from "@/components/ui/form-field";
import { useToast } from "@/components/ui/toast";
import { cn } from "@/lib/utils";
import { saveEquipment, type EquipmentData } from "../../actions";

const EQUIPMENT_TYPES = [
  { value: "dry_van", label: "Dry Van" },
  { value: "reefer", label: "Reefer" },
  { value: "flatbed", label: "Flatbed" },
  { value: "step_deck", label: "Step Deck" },
  { value: "tanker", label: "Tanker" },
  { value: "other", label: "Other" },
];
const TRAILER_TYPES = ["Dry Van", "Reefer", "Flatbed", "Step Deck", "Tanker", "Power Only"];
const REGIONS = ["Northeast", "Southeast", "Midwest", "Southwest", "West", "Nationwide"];

function toggle(list: string[], value: string): string[] {
  return list.includes(value) ? list.filter((v) => v !== value) : [...list, value];
}

export function EquipmentForm({ equipmentData }: { equipmentData: Record<string, unknown> | null }) {
  const toast = useToast();
  const router = useRouter();
  const [saving, startSave] = useTransition();

  const initial = (equipmentData ?? {}) as Partial<EquipmentData>;
  const [equipmentType, setEquipmentType] = useState(initial.equipment_type ?? "");
  const [trailerTypes, setTrailerTypes] = useState<string[]>(initial.trailer_types ?? []);
  const [operatingRegions, setOperatingRegions] = useState<string[]>(initial.operating_regions ?? []);

  function handleSubmit(e: React.FormEvent<HTMLFormElement>) {
    e.preventDefault();
    const formData = new FormData(e.currentTarget);
    const submitter = (e.nativeEvent as SubmitEvent).submitter as HTMLButtonElement | null;
    const continueNext = submitter?.name !== "save_only";

    const payload: EquipmentData = {
      equipment_type: equipmentType || null,
      truck_count: formData.get("truck_count") ? Number(formData.get("truck_count")) : null,
      trailer_count: formData.get("trailer_count") ? Number(formData.get("trailer_count")) : null,
      trailer_types: trailerTypes,
      preferred_freight: (formData.get("preferred_freight") as string)?.trim() || null,
      operating_regions: operatingRegions,
    };

    startSave(async () => {
      const result = await saveEquipment(payload);
      if (!result.ok) {
        toast.show("error", result.error);
        return;
      }
      if (continueNext) router.push("/carrier-onboarding/documents");
      else toast.show("success", "Saved.");
    });
  }

  return (
    <form className="mt-4 space-y-4" onSubmit={handleSubmit}>
      <FormGrid>
        <div className="space-y-1">
          <label htmlFor="equipment_type" className="text-[12px] font-medium text-desktop-text">Primary Equipment Type</label>
          <select
            id="equipment_type"
            value={equipmentType}
            onChange={(e) => setEquipmentType(e.target.value)}
            className="h-8 w-full rounded-sm border border-desktop-border bg-card px-2.5 text-[13px] shadow-elevation-1 outline-none transition-[box-shadow,border-color] focus-visible:border-primary focus-visible:ring-2 focus-visible:ring-primary/20"
          >
            <option value="">Select...</option>
            {EQUIPMENT_TYPES.map((opt) => (
              <option key={opt.value} value={opt.value}>{opt.label}</option>
            ))}
          </select>
        </div>
        <FormField label="Truck Count" name="truck_count" type="number" defaultValue={initial.truck_count ?? undefined} />
        <FormField label="Trailer Count" name="trailer_count" type="number" defaultValue={initial.trailer_count ?? undefined} />
      </FormGrid>

      <div>
        <p className="text-[12px] font-medium text-desktop-text">Trailer Types</p>
        <div className="mt-1.5 flex flex-wrap gap-1.5">
          {TRAILER_TYPES.map((t) => (
            <button
              key={t}
              type="button"
              onClick={() => setTrailerTypes((prev) => toggle(prev, t))}
              className={cn(
                "rounded-sm border px-2.5 py-1.5 text-[12.5px] font-medium transition-colors",
                trailerTypes.includes(t) ? "border-primary bg-primary/10 text-primary" : "border-desktop-border text-muted-foreground hover:bg-desktop-muted"
              )}
            >
              {t}
            </button>
          ))}
        </div>
      </div>

      <div>
        <p className="text-[12px] font-medium text-desktop-text">Operating Regions</p>
        <div className="mt-1.5 flex flex-wrap gap-1.5">
          {REGIONS.map((r) => (
            <button
              key={r}
              type="button"
              onClick={() => setOperatingRegions((prev) => toggle(prev, r))}
              className={cn(
                "rounded-sm border px-2.5 py-1.5 text-[12.5px] font-medium transition-colors",
                operatingRegions.includes(r) ? "border-primary bg-primary/10 text-primary" : "border-desktop-border text-muted-foreground hover:bg-desktop-muted"
              )}
            >
              {r}
            </button>
          ))}
        </div>
      </div>

      <div className="space-y-1 sm:max-w-md">
        <label htmlFor="preferred_freight" className="text-[12px] font-medium text-desktop-text">Preferred Freight</label>
        <textarea
          id="preferred_freight"
          name="preferred_freight"
          rows={2}
          defaultValue={initial.preferred_freight ?? ""}
          placeholder="e.g. Palletized dry goods, produce, machinery"
          className="w-full rounded-sm border border-desktop-border bg-card px-2.5 py-2 text-[13px] shadow-elevation-1 outline-none focus-visible:border-primary focus-visible:ring-2 focus-visible:ring-primary/20"
        />
      </div>

      <div className="flex flex-col-reverse gap-2 border-t border-desktop-border pt-4 sm:flex-row sm:justify-end">
        <Button type="submit" name="save_only" variant="outline" disabled={saving}>
          Save Progress
        </Button>
        <Button type="submit" disabled={saving}>
          {saving ? "Saving..." : "Continue to Documents"}
        </Button>
      </div>
    </form>
  );
}
