"use client";

import { useEffect } from "react";

// Fires window.print() once on mount -- used by ?autoprint=1 so "Download
// Receipt" gets straight to the browser's print dialog (Save as PDF), one
// fewer click than "View Receipt". Same browser-print-to-PDF approach as
// PrintInvoiceButton; no server-side PDF generation added for this.
export function AutoPrint() {
  useEffect(() => {
    const t = setTimeout(() => window.print(), 150);
    return () => clearTimeout(t);
  }, []);
  return null;
}
