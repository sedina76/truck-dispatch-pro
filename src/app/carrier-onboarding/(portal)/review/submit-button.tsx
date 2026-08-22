"use client";

import { useTransition } from "react";
import { useRouter } from "next/navigation";
import { Loader2, Send } from "lucide-react";
import { Button } from "@/components/ui/button";
import { useToast } from "@/components/ui/toast";
import { submitApplication } from "../../actions";

export function SubmitButton({ disabled = false }: { disabled?: boolean }) {
  const toast = useToast();
  const router = useRouter();
  const [submitting, startSubmit] = useTransition();

  function handleSubmit() {
    startSubmit(async () => {
      const result = await submitApplication();
      if (!result.ok) {
        toast.show("error", result.error);
        return;
      }
      router.push("/carrier-onboarding/complete");
    });
  }

  return (
    <Button type="button" size="lg" disabled={disabled || submitting} onClick={handleSubmit} className="w-full sm:w-auto">
      {submitting ? <Loader2 className="size-4 animate-spin" /> : <Send className="size-4" />}
      {submitting ? "Submitting..." : "Submit Application"}
    </Button>
  );
}
