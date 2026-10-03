"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { Mail } from "lucide-react";
import { Button } from "@/components/ui/button";
import { DesktopEmailDialog } from "@/components/desktop/email-dialog";

// Opens the standard compose dialog for this page's registered email
// entity (RegisterDesktopActions email: dispatch_fee_invoice). The dialog
// resolves recipient, text and the PDF attachment on the server; closing
// it refreshes the page so "Last emailed" is current.
export function EmailCarrierButton({ label = "Email to Carrier" }: { label?: string }) {
  const [open, setOpen] = useState(false);
  const router = useRouter();
  return (
    <>
      <Button type="button" size="sm" onClick={() => setOpen(true)}>
        <Mail className="size-4" /> {label}
      </Button>
      <DesktopEmailDialog
        open={open}
        onOpenChange={(next) => {
          setOpen(next);
          if (!next) router.refresh();
        }}
      />
    </>
  );
}
