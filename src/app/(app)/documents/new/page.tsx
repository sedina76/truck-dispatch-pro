import { FormCard } from "@/components/ui/form-card";
import { FormField, FormGrid, FormSelect } from "@/components/ui/form-field";
import { createDocument } from "../actions";

const ENTITY_TYPES = [
  "organization",
  "load",
  "dispatch",
  "carrier",
  "broker",
  "customer",
  "driver",
  "truck",
  "trailer",
  "invoice",
  "settlement",
  "expense",
];

const DOCUMENT_TYPES = [
  "rate_confirmation",
  "bol",
  "pod",
  "cdl",
  "insurance_certificate",
  "w9",
  "motor_carrier_authority",
  "vehicle_registration",
  "ifta_credential",
  "factoring_notice",
  "medical_card",
  "inspection_report",
  "notice_of_assignment",
  "other",
];

export default function NewDocumentPage() {
  return (
    <FormCard
      title="New Document"
      description="Attach a document to a load, carrier, driver, truck, or other record."
      action={createDocument}
      cancelHref="/documents"
      submitLabel="Add Document"
    >
      <FormGrid>
        <FormSelect
          label="Entity type"
          name="entity_type"
          required
          options={ENTITY_TYPES.map((t) => ({ value: t, label: t.charAt(0).toUpperCase() + t.slice(1) }))}
        />
        <FormField
          label="Entity ID"
          name="entity_id"
          required
          placeholder="Paste the ID of the related record"
        />
        <FormSelect
          label="Document type"
          name="document_type"
          required
          options={DOCUMENT_TYPES.map((t) => ({ value: t, label: t.replace(/_/g, " ") }))}
        />
        <FormField label="File name" name="file_name" required placeholder="rate_con.pdf" />
        <FormField
          label="File path"
          name="file_path"
          required
          placeholder="org-id/loads/load-id/file.pdf"
        />
        <FormField label="Expiry date (if applicable)" name="expiry_date" type="date" />
        <label className="flex items-center gap-2 text-sm font-medium">
          <input type="checkbox" name="is_verified" className="size-4 rounded border-[var(--color-border)]" />
          Verified
        </label>
      </FormGrid>
    </FormCard>
  );
}
