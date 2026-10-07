import { Suspense } from "react";
import { ForgotPinForm } from "./forgot-pin-form";

export const metadata = { title: "Forgot PIN · Driver Portal" };

export default function ForgotPinPage() {
  return (
    <Suspense>
      <ForgotPinForm />
    </Suspense>
  );
}
