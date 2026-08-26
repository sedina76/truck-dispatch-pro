"use client";

import { useRef, useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { CheckCircle2, XCircle, UploadCloud, Loader2, FileText, Camera } from "lucide-react";
import { Button } from "@/components/ui/button";
import { useToast } from "@/components/ui/toast";
import { cn } from "@/lib/utils";
import { DocumentScanner } from "@/components/documents/document-scanner";
import { getDocumentChecklist, uploadOnboardingDocument, type ChecklistItem } from "../../actions";

const TONE: Record<ChecklistItem["status"], { label: string; className: string; icon: React.ComponentType<{ className?: string }> }> = {
  missing: { label: "Missing", className: "text-muted-foreground", icon: FileText },
  uploaded: { label: "Uploaded -- Pending Review", className: "text-desktop-warning", icon: UploadCloud },
  rejected: { label: "Needs New Upload", className: "text-desktop-danger", icon: XCircle },
  accepted: { label: "Accepted", className: "text-desktop-success", icon: CheckCircle2 },
};

function ChecklistRow({ item, onUploaded }: { item: ChecklistItem; onUploaded: () => void }) {
  const toast = useToast();
  const [uploading, startUpload] = useTransition();
  const [scannerOpen, setScannerOpen] = useState(false);
  const inputRef = useRef<HTMLInputElement>(null);
  const tone = TONE[item.status];

  // Shared by the plain file input and the scanner's onCapture (Phase
  // 2Q.1) -- both call uploadOnboardingDocument() directly, so a scanned
  // insurance certificate/W-9/etc. goes through the exact same
  // organization-scoped storage write and review-status reset as a chosen
  // file. Rethrows on failure so the scanner keeps the scan and offers
  // Retry instead of losing it. The try/catch inside the transition
  // guards against an unexpected throw (e.g. a dropped connection) --
  // without it, a throw here would never reach resolve/reject and the
  // caller (including the scanner's own upload spinner) would hang
  // forever instead of surfacing an error.
  function submitFile(file: File): Promise<void> {
    const formData = new FormData();
    formData.set("file", file);
    return new Promise((resolve, reject) => {
      startUpload(async () => {
        try {
          const result = await uploadOnboardingDocument(item.documentType, formData);
          if (!result.ok) {
            toast.show("error", result.error);
            reject(new Error(result.error));
          } else {
            toast.show("success", `${item.label} uploaded.`);
            onUploaded();
            resolve();
          }
        } catch (e) {
          const message = e instanceof Error ? e.message : "Upload failed.";
          toast.show("error", message);
          reject(new Error(message));
        }
      });
    });
  }

  function handleFileChange(e: React.ChangeEvent<HTMLInputElement>) {
    const file = e.target.files?.[0];
    if (!file) return;
    submitFile(file)
      .catch(() => {})
      .finally(() => {
        if (inputRef.current) inputRef.current.value = "";
      });
  }

  return (
    <div className="flex flex-col gap-2 rounded-sm border border-desktop-border p-3 sm:flex-row sm:items-center sm:justify-between">
      <div className="min-w-0">
        <div className="flex items-center gap-2">
          <span className="text-[13.5px] font-medium text-desktop-text">{item.label}</span>
          {item.requirement === "required" && <span className="text-[10.5px] font-semibold text-danger">Required</span>}
        </div>
        <div className={cn("mt-0.5 flex items-center gap-1 text-[12px]", tone.className)}>
          <tone.icon className="size-3.5 shrink-0" />
          {tone.label}
          {item.fileName && item.status !== "missing" && <span className="truncate text-muted-foreground">-- {item.fileName}</span>}
        </div>
        {item.status === "rejected" && item.rejectionReason && (
          <p className="mt-1 text-[12px] text-danger">Reason: {item.rejectionReason}</p>
        )}
        {item.instructions && <p className="mt-1 text-[11.5px] text-muted-foreground">{item.instructions}</p>}
      </div>
      <div className="flex shrink-0 gap-1.5">
        <input ref={inputRef} type="file" accept="application/pdf,image/jpeg,image/png,image/heic,image/heif" className="hidden" onChange={handleFileChange} />
        <Button type="button" size="sm" variant="outline" disabled={uploading} onClick={() => setScannerOpen(true)} aria-label="Scan document">
          {uploading ? <Loader2 className="size-3.5 animate-spin" /> : <Camera className="size-3.5" />}
        </Button>
        <Button type="button" size="sm" variant={item.status === "missing" || item.status === "rejected" ? "primary" : "outline"} disabled={uploading} onClick={() => inputRef.current?.click()}>
          {uploading ? <Loader2 className="size-3.5 animate-spin" /> : item.status === "missing" || item.status === "rejected" ? "Upload" : "Replace"}
        </Button>
      </div>
      <DocumentScanner open={scannerOpen} onOpenChange={setScannerOpen} onCapture={submitFile} documentLabel={item.label} />
    </div>
  );
}

export function DocumentChecklist({ initialItems }: { initialItems: ChecklistItem[] }) {
  const [items, setItems] = useState(initialItems);
  const [refreshing, startRefresh] = useTransition();
  const router = useRouter();

  function refresh() {
    startRefresh(async () => {
      const fresh = await getDocumentChecklist();
      setItems(fresh);
    });
  }

  return (
    <div className="mt-4 space-y-2">
      {items.map((item) => (
        <ChecklistRow key={item.documentType} item={item} onUploaded={refresh} />
      ))}
      {refreshing && <p className="text-[11px] text-muted-foreground">Updating...</p>}

      <div className="flex justify-end border-t border-desktop-border pt-4">
        <Button type="button" onClick={() => router.push("/carrier-onboarding/agreement")}>
          Continue to Agreement
        </Button>
      </div>
    </div>
  );
}
