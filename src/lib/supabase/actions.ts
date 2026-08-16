"use server";

import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";

export type ActionState = { error: string | null };

export async function login(_prev: ActionState, formData: FormData): Promise<ActionState> {
  const supabase = await createClient();

  const { error } = await supabase.auth.signInWithPassword({
    email: String(formData.get("email")),
    password: String(formData.get("password")),
  });

  if (error) return { error: error.message };

  redirect("/dashboard");
}

export async function signup(_prev: ActionState, formData: FormData): Promise<ActionState> {
  const supabase = await createClient();
  const fullName = String(formData.get("fullName"));

  const { data, error } = await supabase.auth.signUp({
    email: String(formData.get("email")),
    password: String(formData.get("password")),
    options: { data: { full_name: fullName } },
  });

  if (error) return { error: error.message };

  // Email confirmation enabled: no session yet. Send them to login with a notice.
  if (!data.session) {
    redirect("/login?confirmEmail=1");
  }

  redirect("/onboarding");
}

export async function logout() {
  const supabase = await createClient();
  await supabase.auth.signOut();
  redirect("/login");
}

export async function createOrganization(
  _prev: ActionState,
  formData: FormData
): Promise<ActionState> {
  const supabase = await createClient();
  const name = String(formData.get("name"));

  const slug =
    name
      .toLowerCase()
      .trim()
      .replace(/[^a-z0-9]+/g, "-")
      .replace(/^-+|-+$/g, "") +
    "-" +
    Math.random().toString(36).slice(2, 6);

  const { error } = await supabase.rpc("create_organization_with_owner", {
    p_name: name,
    p_slug: slug,
  });

  if (error) return { error: error.message };

  redirect("/dashboard");
}
