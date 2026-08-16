import Link from "next/link";
import { ArrowLeft, Landmark, Star } from "lucide-react";
import { createClient } from "@/lib/supabase/server";
import { PageHeader } from "@/components/ui/page-header";
import { Button } from "@/components/ui/button";
import { EmptyState } from "@/components/ui/empty-state";
import { RevealPiiButton } from "@/components/ui/reveal-pii-button";
import { SetPiiForm } from "@/components/ui/set-pii-form";
import {
  createBankAccount,
  deleteBankAccount,
  setBankAccountNumber,
  revealBankAccountNumber,
} from "../../actions";

export default async function BankAccountsPage() {
  const supabase = await createClient();

  const [{ data: accounts }, { data: profile }] = await Promise.all([
    supabase
      .from("organization_bank_accounts")
      .select("id, bank_name, account_nickname, account_type, routing_number_last4, account_number_last4, is_primary")
      .order("is_primary", { ascending: false }),
    (async () => {
      const {
        data: { user },
      } = await supabase.auth.getUser();
      return supabase.from("profiles").select("role").eq("id", user!.id).single();
    })(),
  ]);
  const isOwner = profile?.role === "owner";

  return (
    <div className="space-y-6">
      <Link href="/settings/organization" className="inline-flex items-center gap-1.5 text-sm text-muted-foreground hover:text-foreground">
        <ArrowLeft className="size-4" />
        Back to Company
      </Link>

      <PageHeader
        title="Bank Accounts"
        description="Payment instructions for receiving broker and factoring payments. Account and routing numbers are encrypted at rest."
      />

      {!accounts || accounts.length === 0 ? (
        <EmptyState title="No bank accounts on file" description="Add one below to include it on invoices and payment instructions." />
      ) : (
        <div className="space-y-3">
          {accounts.map((acct) => (
            <div key={acct.id} className="rounded-xl border border-border bg-card p-4 shadow-elevation-1">
              <div className="flex items-center justify-between">
                <div className="flex items-center gap-2">
                  <div className="flex size-9 items-center justify-center rounded-lg bg-primary/10 text-primary">
                    <Landmark className="size-4" />
                  </div>
                  <div>
                    <p className="flex items-center gap-1.5 text-sm font-semibold">
                      {acct.bank_name}
                      {acct.is_primary && (
                        <span className="inline-flex items-center gap-0.5 rounded-full bg-success/10 px-2 py-0.5 text-[10px] font-medium text-success">
                          <Star className="size-2.5 fill-current" /> Primary
                        </span>
                      )}
                    </p>
                    <p className="text-xs text-muted-foreground capitalize">
                      {acct.account_nickname ?? acct.account_type}
                    </p>
                  </div>
                </div>
                {isOwner && (
                  <form action={deleteBankAccount.bind(null, acct.id)} onSubmit={(e) => { if (!confirm("Remove this bank account?")) e.preventDefault(); }}>
                    <Button type="submit" variant="danger" size="sm">Remove</Button>
                  </form>
                )}
              </div>

              {isOwner && (
                <div className="mt-4 grid grid-cols-1 gap-4 border-t border-border pt-4 sm:grid-cols-2">
                  <div>
                    <p className="mb-1.5 text-xs font-medium text-muted-foreground">Account number</p>
                    {acct.account_number_last4 ? (
                      <RevealPiiButton
                        maskedValue={`••••••${acct.account_number_last4}`}
                        onReveal={revealBankAccountNumber.bind(null, acct.id, "account_number")}
                        promptForReason
                      />
                    ) : (
                      <SetPiiForm
                        label="Set account number"
                        placeholder="000123456789"
                        onSave={setBankAccountNumber.bind(null, acct.id, "account_number")}
                      />
                    )}
                  </div>
                  <div>
                    <p className="mb-1.5 text-xs font-medium text-muted-foreground">Routing number</p>
                    {acct.routing_number_last4 ? (
                      <RevealPiiButton
                        maskedValue={`•••••${acct.routing_number_last4}`}
                        onReveal={revealBankAccountNumber.bind(null, acct.id, "routing_number")}
                        promptForReason
                      />
                    ) : (
                      <SetPiiForm
                        label="Set routing number"
                        placeholder="021000021"
                        onSave={setBankAccountNumber.bind(null, acct.id, "routing_number")}
                      />
                    )}
                  </div>
                </div>
              )}
            </div>
          ))}
        </div>
      )}

      {isOwner && (
        <form action={createBankAccount} className="rounded-xl border border-dashed border-border p-4">
          <p className="mb-3 text-sm font-medium">Add a bank account</p>
          <div className="flex flex-wrap items-end gap-3">
            <div className="space-y-1">
              <label className="text-xs font-medium text-muted-foreground">Bank name</label>
              <input name="bank_name" required className="h-9 w-48 rounded-lg border border-border bg-card px-3 text-sm shadow-elevation-1 outline-none focus-visible:border-primary focus-visible:ring-2 focus-visible:ring-primary/20" />
            </div>
            <div className="space-y-1">
              <label className="text-xs font-medium text-muted-foreground">Nickname</label>
              <input name="account_nickname" placeholder="Operating account" className="h-9 w-44 rounded-lg border border-border bg-card px-3 text-sm shadow-elevation-1 outline-none focus-visible:border-primary focus-visible:ring-2 focus-visible:ring-primary/20" />
            </div>
            <div className="space-y-1">
              <label className="text-xs font-medium text-muted-foreground">Type</label>
              <select name="account_type" className="h-9 rounded-lg border border-border bg-card px-3 text-sm shadow-elevation-1 outline-none focus-visible:border-primary focus-visible:ring-2 focus-visible:ring-primary/20">
                <option value="checking">Checking</option>
                <option value="savings">Savings</option>
              </select>
            </div>
            <label className="flex h-9 items-center gap-1.5 text-sm">
              <input type="checkbox" name="is_primary" className="size-4 rounded border-border" />
              Primary
            </label>
            <Button type="submit" size="sm">Add Account</Button>
          </div>
        </form>
      )}
    </div>
  );
}
