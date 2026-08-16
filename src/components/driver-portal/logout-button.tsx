"use client";

import { useRouter } from "next/navigation";
import { LogOut } from "lucide-react";

export function LogoutButton() {
  const router = useRouter();

  async function onLogout() {
    await fetch("/api/driver-portal/logout", { method: "POST" });
    router.push("/driver-portal/login");
    router.refresh();
  }

  return (
    <button
      type="button"
      onClick={onLogout}
      className="flex size-9 items-center justify-center rounded-lg border border-border text-muted-foreground hover:bg-muted"
      aria-label="Log out"
    >
      <LogOut className="size-4" />
    </button>
  );
}
