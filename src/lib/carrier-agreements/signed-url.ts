import "server-only";
import { createClient } from "@/lib/supabase/server";
import { createServiceRoleClient } from "@/lib/supabase/service-role";
import { ExecutedAgreementAccessDeniedError, ExecutedAgreementResourceNotFoundError } from "./errors";

const STAFF_ROLES = ["owner", "admin", "dispatcher", "accountant"];

export async function getStaffExecutedAgreementSignedUrl(applicationId: string, signingId: string, download: boolean) {
  const supabase = await createClient();
  const [{ data: role }, { data: signing }] = await Promise.all([
    supabase.rpc("current_role"),
    supabase.from("carrier_agreement_signings")
      .select("id, application_id, generated_document_id, carrier_agreement_templates(name,version_number)")
      .eq("id", signingId).eq("application_id", applicationId).maybeSingle(),
  ]);
  if (!signing) throw new ExecutedAgreementResourceNotFoundError();
  if (!STAFF_ROLES.includes((role as string | null) ?? "viewer")) throw new ExecutedAgreementAccessDeniedError();
  return createArtifactUrl(signing.generated_document_id, signingId, applicationId, download);
}

export async function getCarrierExecutedAgreementSignedUrl(applicationId: string, signingId: string, download: boolean) {
  return createArtifactUrlForCarrier(applicationId, signingId, download);
}

async function createArtifactUrlForCarrier(applicationId: string, signingId: string, download: boolean) {
  const service = createServiceRoleClient();
  const { data: signing } = await service.from("carrier_agreement_signings")
    .select("generated_document_id").eq("id", signingId).eq("application_id", applicationId).maybeSingle();
  if (!signing) throw new ExecutedAgreementResourceNotFoundError();
  return createArtifactUrl(signing.generated_document_id, signingId, applicationId, download);
}

async function createArtifactUrl(documentId: string | null, signingId: string, applicationId: string, download: boolean) {
  if (!documentId) throw new ExecutedAgreementResourceNotFoundError();
  const service = createServiceRoleClient();
  const { data: document } = await service.from("documents")
    .select("id, organization_id, entity_type, entity_id, document_type, file_name, file_path, mime_type")
    .eq("id", documentId).maybeSingle();
  const { data: signing } = await service.from("carrier_agreement_signings")
    .select("organization_id, application_id, generated_document_id, document_generation_status")
    .eq("id", signingId).eq("application_id", applicationId).maybeSingle();
  if (!document || !signing || signing.generated_document_id !== document.id || signing.document_generation_status !== "generated"
    || document.organization_id !== signing.organization_id || document.entity_type !== "carrier_onboarding_application"
    || document.entity_id !== applicationId || document.document_type !== "signed_agreement" || document.mime_type !== "application/pdf") {
    throw new ExecutedAgreementResourceNotFoundError();
  }
  const filename = document.file_name || "executed-dispatch-agreement.pdf";
  const { data, error } = await service.storage.from("carrier-onboarding-documents")
    .createSignedUrl(document.file_path, 300, download ? { download: filename } : undefined);
  if (error || !data?.signedUrl) throw new Error("Could not create a signed agreement URL.");
  return { url: data.signedUrl, filename };
}
