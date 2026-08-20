import Link from "next/link";
import { AuthShell } from "@/components/auth/auth-shell";
import { AuthCard } from "@/components/auth/auth-card";
import { SignupForm } from "./signup-form";

export default function SignupPage() {
  return (
    <AuthShell centered>
      <AuthCard>
        <div className="space-y-5">
          <div>
            <h1 className="text-2xl font-bold tracking-tight text-[#1a1a18]">Create Your Account</h1>
            <p className="mt-1 text-sm text-[#6b6b64]">Join thousands of trucking companies running smarter.</p>
          </div>

          <SignupForm />

          <p className="text-center text-sm text-[#6b6b64]">
            Already have an account?{" "}
            <Link href="/login" className="font-medium text-[#1c54b8] hover:underline">
              Sign in
            </Link>
          </p>
        </div>
      </AuthCard>
    </AuthShell>
  );
}
