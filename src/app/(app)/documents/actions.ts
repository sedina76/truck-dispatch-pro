"use server";

import { insertRecord, updateRecord } from "@/lib/actions/records";
import { emptyToNull } from "@/lib/utils/form";

function documentValues(formData: FormData) {
  return {
    entity_type: String(formData.get("entity_type")),
    entity_id: String(formData.get("entity_id")),
    document_type: String(formData.get("document_type")),
    file_name: String(formData.get("file_name")),
    // NOTE: file_path is a manually-entered placeholder until Supabase
    // Storage upload is wired up (see docs/PLAN.md Week 3). It should
    // become the object path returned by a real upload call.
    file_path: String(formData.get("file_path")),
    expiry_date: emptyToNull(formData.get("expiry_date")),
    is_verified: formData.get("is_verified") === "on",
  };
}

export async function createDocument(formData: FormData) {
  await insertRecord("documents", documentValues(formData), "/documents");
}

export async function updateDocument(id: string, formData: FormData) {
  await updateRecord("documents", id, documentValues(formData), "/documents");
}
