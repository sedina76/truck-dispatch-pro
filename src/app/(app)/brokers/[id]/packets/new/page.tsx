import { notFound } from "next/navigation";
import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { requireRole } from "@/lib/auth/require-role";
import { createBrokerPacketDraft } from "../actions";

export default async function NewBrokerPacketPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  await requireRole(["owner", "admin", "dispatcher"]);
  const supabase = await createClient();
  const [{ data: broker }, { data: carriers }] = await Promise.all([
    supabase.from("brokers").select("id,legal_name").eq("id", id).maybeSingle(),
    supabase.from("carriers").select("id,legal_name").eq("is_active", true).order("legal_name"),
  ]);
  if (!broker) notFound();

  return (
    <div className="min-w-0 space-y-3">
      <Link href={`/brokers/${id}?tab=broker-packets`} className="text-xs text-muted-foreground hover:text-foreground">
        ← Broker Packets
      </Link>
      <h1 className="wrap-break-word text-xl font-semibold">New Broker Packet for {broker.legal_name}</h1>
      <p className="max-w-full text-sm text-muted-foreground">
        Choose the carrier profile this packet presents, if this organization represents more than one carrier. Leave it
        unset to use this organization&apos;s own operating profile. You&apos;ll select documents on the next screen.
      </p>
      <form action={createBrokerPacketDraft.bind(null, id)} className="min-w-0 space-y-3 rounded-md border bg-card p-4">
        {carriers?.length ? (
          <label className="block min-w-0 space-y-1 text-sm">
            <span className="font-medium">Carrier profile (optional)</span>
            <select name="carrier_id" className="h-9 w-full rounded-md border bg-background px-3">
              <option value="">This organization&apos;s own profile</option>
              {carriers.map((c) => (
                <option key={c.id} value={c.id}>
                  {c.legal_name}
                </option>
              ))}
            </select>
          </label>
        ) : (
          <input type="hidden" name="carrier_id" value="" />
        )}
        <button className="h-9 w-full rounded-md bg-primary px-3 text-sm font-medium text-primary-foreground sm:w-auto">Start Draft</button>
      </form>
    </div>
  );
}
