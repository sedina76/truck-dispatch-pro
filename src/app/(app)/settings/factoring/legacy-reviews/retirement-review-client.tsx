"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { Button } from "@/components/ui/button";
import { deactivateReviewedRelationship, recordReviewedRetirement, resolveRetiredRelationshipException } from "./actions";

type Row = {
  id: string; relationshipId: string; name: string; carrierId: string | null; priorCarrierId: string | null;
  isActive: boolean; isDefault: boolean; relationshipUpdatedAt: string; reviewUpdatedAt: string;
  decisionStatus: string; strictStatus: string; factoredInvoices: number; unprovenInvoices: number;
  exceptionStatus: string | null; decisionEvidenceRef: string | null;
};

function Review({ row }: { row: Row }) {
  const router = useRouter();
  const [reason, setReason] = useState("");
  const [evidence, setEvidence] = useState("");
  const [confirmation, setConfirmation] = useState("");
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState("");
  const matchingCarrier = row.carrierId && row.carrierId === row.priorCarrierId;
  const pending = row.decisionStatus === "pending";
  const allowed = confirmation === "RETIRE" && reason.trim().length >= 12 && matchingCarrier && !row.isDefault;
  const pendingAllowed = allowed && evidence.trim().length >= 8;
  const run = async (step: "deactivate" | "retire" | "resolve") => {
    setBusy(true);
    setMessage("");
    try {
      const result = step === "deactivate"
        ? await deactivateReviewedRelationship(row.id, row.relationshipUpdatedAt, reason, crypto.randomUUID())
        : step === "retire"
          ? await recordReviewedRetirement(row.id, row.reviewUpdatedAt, reason, evidence, crypto.randomUUID())
          : await resolveRetiredRelationshipException(row.id, reason);
      if (!result.ok) setMessage(result.error);
      else { setMessage("Recorded. Refreshing the review."); router.refresh(); }
    } catch { setMessage("This step failed. Refresh and inspect the record before trying again."); }
    finally { setBusy(false); }
  };
  return <article className="space-y-3 rounded-lg border p-4">
    <h2 className="font-semibold">{row.name}</h2>
    <p className="text-sm">Ownership review: <strong>{row.decisionStatus}</strong> · strict evidence: {row.strictStatus} · relationship: {row.isActive ? "active" : "inactive"} · exception: {row.exceptionStatus ?? "none"}</p>
    <p className="text-sm">Historical factored invoices: {row.factoredInvoices}; without carrier evidence: {row.unprovenInvoices}. Carrier assignment: {matchingCarrier ? "unchanged" : "changed — stop and investigate"}.</p>
    {row.decisionEvidenceRef ? <p className="text-sm">Recorded evidence reference: {row.decisionEvidenceRef}</p> : null}
    {(pending || row.exceptionStatus === "unresolved") && <div className="space-y-2">
      <label className="block text-sm">Reason
        <textarea className="mt-1 block w-full rounded border p-2" value={reason} onChange={(e) => setReason(e.target.value)} maxLength={500} placeholder="Why is this relationship being retired?" />
      </label>
      {pending && <label className="block text-sm">Evidence reference
        <input className="mt-1 block w-full rounded border p-2" value={evidence} onChange={(e) => setEvidence(e.target.value)} maxLength={300} placeholder="Internal test record or review reference (no secret data)" />
      </label>}
      <label className="block text-sm">Type RETIRE to confirm
        <input className="mt-1 block rounded border p-2" value={confirmation} onChange={(e) => setConfirmation(e.target.value)} />
      </label>
    </div>}
    <div className="flex flex-wrap gap-2">
      {pending && row.isActive && <Button type="button" disabled={!pendingAllowed || busy || !row.relationshipUpdatedAt} onClick={() => run("deactivate")}>1. Deactivate relationship</Button>}
      {pending && !row.isActive && <Button type="button" disabled={!pendingAllowed || busy || !row.reviewUpdatedAt} onClick={() => run("retire")}>2. Record retirement</Button>}
      {row.decisionStatus === "retired" && row.exceptionStatus === "unresolved" && <Button type="button" disabled={!allowed || busy || row.isActive} onClick={() => run("resolve")}>3. Archive retired exception</Button>}
    </div>
    {message && <p role="status" className="text-sm">{message}</p>}
  </article>;
}

export function RetirementReviewClient({ rows }: { rows: Row[] }) {
  return <div className="space-y-4">{rows.length ? rows.map((row) => <Review key={`${row.id}:${row.decisionStatus}:${row.isActive}:${row.exceptionStatus}`} row={row} />) :
    <p className="text-sm">No pending or retired unsupported assignments in this organization.</p>}</div>;
}
