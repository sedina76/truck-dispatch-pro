// POD status is always derived from a documents row (or its absence), never
// stored redundantly as its own column/enum. See 0023_pod_workflow.sql for
// the exact state definition this mirrors.
import type { DocumentRow } from "@/lib/documents/latest-document";

export type PodStatus = "missing" | "uploaded" | "verified" | "rejected";

// Alias, not a redeclaration: POD is just a documents row like any other
// document type -- see latest-document.ts, the single shared query every
// document-type/entity lookup in this app must go through.
export type PodDocument = DocumentRow;

export function computePodStatus(pod: PodDocument | null | undefined): PodStatus {
  if (!pod) return "missing";
  if (pod.is_verified) return "verified";
  if (pod.rejected_at) return "rejected";
  return "uploaded";
}

export const POD_STATUS_LABEL: Record<PodStatus, string> = {
  missing: "Missing",
  uploaded: "Uploaded",
  verified: "Verified",
  rejected: "Rejected",
};
