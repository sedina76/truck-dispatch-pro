"use client";

import { useState } from "react";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { ArrowRight, Info } from "lucide-react";
import { Button } from "@/components/ui/button";
import { RecordPicker, type RecordOption } from "@/components/ui/record-picker";
import {
  NEW_DOCUMENT_ENTITY_TYPES,
  NEW_DOCUMENT_ROUTING,
  type NewDocumentEntityType,
} from "@/lib/documents/library";

const SELECT_CLASS =
  "h-8 w-full rounded-sm border border-desktop-border bg-card px-2.5 text-[13px] shadow-elevation-1 outline-none transition-[box-shadow,border-color] focus-visible:border-primary focus-visible:ring-2 focus-visible:ring-primary/20 disabled:opacity-50";

// One display-ready option per business record. The page builds these
// server-side (primary/secondary/tertiary + a lowercased search haystack)
// so the picker stays presentation-only.
export type EntityOption = RecordOption;

const FIELD_LABEL: Record<NewDocumentEntityType, string> = {
  carrier: "Carrier",
  driver: "Driver",
  load: "Load",
  broker: "Broker",
  customer: "Customer",
};

const SEARCH_PLACEHOLDER: Record<NewDocumentEntityType, string> = {
  carrier: "Search carrier name, MC, or DOT...",
  driver: "Search driver name...",
  load: "Search load #, broker/customer, or city...",
  broker: "Search broker name or MC...",
  customer: "Search customer name or city...",
};

// The global "Add Document" flow is a ROUTER, not a form that writes a
// documents row. Step 1: record type. Step 2: the actual record (from a
// tenant-scoped searchable picker -- no UUID, ever). Step 3: Continue ->
// the record's real byte-upload workflow, or an honest "not available
// here" message with a link to the record. Nothing is inserted; there is
// no phantom document.
export function AddDocumentRouter({
  entities,
  initialEntityType,
  initialEntityId,
}: {
  entities: Record<NewDocumentEntityType, EntityOption[]>;
  initialEntityType?: NewDocumentEntityType | "";
  initialEntityId?: string;
}) {
  const router = useRouter();
  const [entityType, setEntityType] = useState<NewDocumentEntityType | "">(initialEntityType ?? "");
  const [entityId, setEntityId] = useState<string>(
    initialEntityType && initialEntityId ? initialEntityId : ""
  );
  const [showUnavailable, setShowUnavailable] = useState(false);

  const list = entityType ? entities[entityType] : [];
  const routing = entityType ? NEW_DOCUMENT_ROUTING[entityType] : null;
  const selectedPrimary = list.find((o) => o.id === entityId)?.primary ?? null;

  function onContinue() {
    if (!entityType || !entityId || !routing) return;
    if (routing.uploadHref) {
      router.push(routing.uploadHref(entityId));
    } else {
      setShowUnavailable(true);
    }
  }

  return (
    <div className="space-y-3">
      <div>
        <h1 className="text-[15px] font-semibold tracking-tight text-desktop-text">Add Document</h1>
        <p className="mt-0.5 text-xs text-muted-foreground">
          Pick the record, then continue to its document upload workflow.
        </p>
      </div>

      <div className="rounded-md border border-desktop-border bg-card shadow-elevation-1">
        <div className="flex h-7 items-center rounded-t-md bg-desktop-header px-3 text-[11px] font-semibold uppercase tracking-wide text-desktop-header-text">
          Add Document
        </div>
        <div className="space-y-4 p-4">
          <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
            {/* Step 1 -- record type (small, closed set: native select is fine) */}
            <div className="min-w-0 space-y-1">
              <label htmlFor="entity_type" className="text-[12px] font-medium text-desktop-text">
                Record type<span className="text-danger"> *</span>
              </label>
              <select
                id="entity_type"
                className={SELECT_CLASS}
                value={entityType}
                onChange={(e) => {
                  setEntityType(e.target.value as NewDocumentEntityType | "");
                  setEntityId("");
                  setShowUnavailable(false);
                }}
              >
                <option value="" disabled>
                  Select...
                </option>
                {NEW_DOCUMENT_ENTITY_TYPES.map((o) => (
                  <option key={o.value} value={o.value}>
                    {o.label}
                  </option>
                ))}
              </select>
            </div>

            {/* Step 2 -- the record (searchable picker) */}
            <div className="min-w-0 space-y-1">
              <label htmlFor="entity_id" className="text-[12px] font-medium text-desktop-text">
                {entityType ? FIELD_LABEL[entityType] : "Record"}
                <span className="text-danger"> *</span>
              </label>
              <RecordPicker
                id="entity_id"
                options={list}
                value={entityId || null}
                onChange={(nextId) => {
                  setEntityId(nextId);
                  setShowUnavailable(false);
                }}
                disabled={!entityType}
                placeholder={
                  entityType ? `Search & select a ${FIELD_LABEL[entityType].toLowerCase()}...` : "Choose a record type first"
                }
                searchPlaceholder={entityType ? SEARCH_PLACEHOLDER[entityType] : "Search..."}
                emptyLabel={
                  entityType ? `No ${FIELD_LABEL[entityType].toLowerCase()}s found.` : "Choose a record type first."
                }
                ariaLabel={entityType ? `Search ${FIELD_LABEL[entityType].toLowerCase()}s` : "Record"}
              />
              {entityType && list.length === 0 && (
                <p className="text-[11px] text-muted-foreground">
                  No {FIELD_LABEL[entityType].toLowerCase()} records in this organization yet.
                </p>
              )}
            </div>
          </div>

          {/* Step 3 -- outcome */}
          {showUnavailable && routing && !routing.uploadHref && (
            <div className="flex items-start gap-2 rounded-sm border border-desktop-border bg-desktop-muted/50 p-3 text-[12.5px] text-desktop-text">
              <Info className="mt-0.5 size-4 shrink-0 text-muted-foreground" />
              <div className="space-y-1">
                <p>
                  Document upload for {routing.recordLabel} records isn&apos;t available from the global library yet.
                  Open the {routing.recordLabel} to manage its documents and compliance.
                </p>
                {entityId && (
                  <Link
                    href={routing.recordHref(entityId)}
                    className="inline-flex items-center gap-1 font-medium text-primary hover:underline"
                  >
                    Open {selectedPrimary ?? `this ${routing.recordLabel}`}
                    <ArrowRight className="size-3.5" />
                  </Link>
                )}
              </div>
            </div>
          )}

          <div className="flex items-center justify-between border-t border-desktop-border pt-3">
            <Link
              href="/documents"
              className="inline-flex h-8 items-center rounded-sm px-3 text-[13px] font-medium text-muted-foreground transition-colors hover:bg-muted"
            >
              Cancel
            </Link>
            <Button type="button" onClick={onContinue} disabled={!entityType || !entityId}>
              Continue
            </Button>
          </div>
        </div>
      </div>
    </div>
  );
}
