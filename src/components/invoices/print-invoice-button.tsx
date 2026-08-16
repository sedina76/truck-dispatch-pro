"use client";

import { Printer } from "lucide-react";

// Real, working "PDF" export via the browser's native print-to-PDF (every
// modern browser's print dialog offers "Save as PDF" as a destination) --
// no new PDF-generation dependency added for one feature. The page this
// button lives on is styled specifically for print via the .pdf-page/
// .no-print classes in globals.css.
export function PrintInvoiceButton() {
  return (
    <button
      type="button"
      onClick={() => window.print()}
      className="no-print inline-flex items-center gap-1.5 rounded-lg bg-primary px-4 py-2 text-sm font-medium text-primary-foreground hover:bg-primary-hover"
    >
      <Printer className="size-4" />
      Print / Save as PDF
    </button>
  );
}
