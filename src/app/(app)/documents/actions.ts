"use server";

import { updateRecord } from "@/lib/actions/records";
import { emptyToNull } from "@/lib/utils/form";

// NOTE: there is no createDocument() here anymore. The global "Add
// Document" flow (/documents/new) is a workflow router -- it sends the
// user to a record's real byte-upload workflow and never inserts a
// documents row. A metadata-only insert with a server-generated file_path
// but no storage object was a phantom-record defect (see the phantom-
// document repair report). Real documents are created by the workflows
// that also upload the bytes: uploadLoadDocument() (loads/pod-actions.ts),
// the W-9 / carrier-agreement / broker-packet / setup-package / statement
// generators, expense/fuel receipt uploads, etc.

// Metadata edit for an existing document (/documents/[id]). Left as-is by
// the phantom-document repair -- see the report for the recommended
// follow-up to give this edit form the same tenant-scoped selectors and
// drop the free-text entity_id / file_path fields.
function documentValues(formData: FormData) {
  return {
    entity_type: String(formData.get("entity_type")),
    entity_id: String(formData.get("entity_id")),
    document_type: String(formData.get("document_type")),
    file_name: String(formData.get("file_name")),
    file_path: String(formData.get("file_path")),
    expiry_date: emptyToNull(formData.get("expiry_date")),
    is_verified: formData.get("is_verified") === "on",
  };
}

export async function updateDocument(id: string, formData: FormData) {
  await updateRecord("documents", id, documentValues(formData), "/documents");
}
