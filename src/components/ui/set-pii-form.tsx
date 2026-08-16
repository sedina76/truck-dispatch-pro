"use client";

import { useState, useTransition } from "react";
import { Lock } from "lucide-react";
import { Button } from "@/components/ui/button";

export function SetPiiForm({
  label,
  placeholder,
  onSave,
}: {
  label: string;
  placeholder: string;
  onSave: (value: string) => Promise<void>;
}) {
  const [value, setValue] = useState("");
  const [pending, startTransition] = useTransition();
  const [saved, setSaved] = useState(false);

  return (
    <form
      onSubmit={(e) => {
        e.preventDefault();
        if (!value.trim()) return;
        startTransition(async () => {
          await onSave(value);
          setValue("");
          setSaved(true);
          setTimeout(() => setSaved(false), 2500);
        });
      }}
      className="flex items-end gap-2"
    >
      <div className="space-y-1">
        <label className="text-xs font-medium text-muted-foreground">{label}</label>
        <input
          type="password"
          autoComplete="off"
          value={value}
          onChange={(e) => setValue(e.target.value)}
          placeholder={placeholder}
          className="h-9 w-48 rounded-lg border border-border bg-card px-3 font-mono text-sm shadow-elevation-1 outline-none focus-visible:border-primary focus-visible:ring-2 focus-visible:ring-primary/20"
        />
      </div>
      <Button type="submit" size="sm" variant="outline" disabled={pending || !value.trim()} className="gap-1.5">
        <Lock className="size-3.5" />
        {pending ? "Encrypting..." : saved ? "Saved" : "Save"}
      </Button>
    </form>
  );
}
