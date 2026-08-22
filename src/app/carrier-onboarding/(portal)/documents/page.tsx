import { getDocumentChecklist } from "../../actions";
import { DocumentChecklist } from "./document-checklist";

export default async function OnboardingDocumentsPage() {
  const checklist = await getDocumentChecklist();
  return (
    <div className="rounded-md border border-desktop-border bg-card p-4 sm:p-5">
      <h2 className="text-[15px] font-semibold text-desktop-text">Required Documents</h2>
      <p className="mt-0.5 text-[13px] text-muted-foreground">Upload clear photos or PDFs. Accepted formats: PDF, JPG, PNG, HEIC (10 MB max).</p>
      <DocumentChecklist initialItems={checklist} />
    </div>
  );
}
