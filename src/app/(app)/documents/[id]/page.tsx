import { notFound } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { deleteRecord } from "@/lib/actions/records";
import { FormCard } from "@/components/ui/form-card";
import { FormField, FormGrid, FormSelect } from "@/components/ui/form-field";
import { updateDocument } from "../actions";

const ENTITY_TYPES = [
  "organization", "load", "dispatch", "carrier", "broker", "customer",
  "driver", "truck", "trailer", "invoice", "settlement", "expense",
];

const DOCUMENT_TYPES = [
  "rate_confirmation", "bol", "pod", "cdl", "insurance_certificate", "w9",
  "motor_carrier_authority", "vehicle_registration", "ifta_credential",
  "factoring_notice", "medical_card", "inspection_report",
  "notice_of_assignment", "other",
];

export default async function DocumentDetailPage({
  params,
}: {
  params: Promise<{ id: string }>;
}) {
  const { id } = await params;
  const supabase = await createClient();

  const { data: document } = await supabase.from("documents").select("*").eq("id", id).single();
  if (!document) notFound();

  return (
    <FormCard
      title={document.file_name}
      description="Document metadata. Changes save immediately."
      action={updateDocument.bind(null, id)}
      cancelHref="/documents"
      deleteAction={deleteRecord.bind(null, "documents", id, "/documents")}
    >
      <FormGrid>
        <FormSelect
          label="Entity type"
          name="entity_type"
          required
          defaultValue={document.entity_type}
          options={ENTITY_TYPES.map((t) => ({ value: t, label: t.charAt(0).toUpperCase() + t.slice(1) }))}
        />
        <FormField label="Entity ID" name="entity_id" required defaultValue={document.entity_id} />
        <FormSelect
          label="Document type"
          name="document_type"
          required
          defaultValue={document.document_type}
          options={DOCUMENT_TYPES.map((t) => ({ value: t, label: t.replace(/_/g, " ") }))}
        />
        <FormField label="File name" name="file_name" required defaultValue={document.file_name} />
        <FormField label="File path" name="file_path" required defaultValue={document.file_path} />
        <FormField label="Expiry date" name="expiry_date" type="date" defaultValue={document.expiry_date} />
        <label className="flex items-center gap-2 text-sm font-medium">
          <input
            type="checkbox"
            name="is_verified"
            defaultChecked={document.is_verified}
            className="size-4 rounded border-[var(--color-border)]"
          />
          Verified
        </label>
      </FormGrid>
    </FormCard>
  );
}
