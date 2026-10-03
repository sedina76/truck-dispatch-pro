import { redirect } from "next/navigation";

// The carrier's invoices ("broker pays the carrier" loads) are listed with
// every other invoice to a broker under Billing -> Invoices; this old list
// address forwards there. Each invoice still opens at /carrier-invoices/<id>.
export default function CarrierInvoicesPage() {
  redirect("/invoices");
}
