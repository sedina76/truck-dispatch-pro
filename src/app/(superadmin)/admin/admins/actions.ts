"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";

export async function addPlatformAdmin(formData: FormData) {
  const supabase = await createClient();
  const email = String(formData.get("email") ?? "").trim();
  if (!email) return;
  await supabase.rpc("add_platform_admin", { p_email: email });
  revalidatePath("/admin/admins");
}

export async function removePlatformAdmin(adminId: string) {
  const supabase = await createClient();
  await supabase.rpc("remove_platform_admin", { p_admin_id: adminId });
  revalidatePath("/admin/admins");
}
