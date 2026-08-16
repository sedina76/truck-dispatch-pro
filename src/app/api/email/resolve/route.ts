import { NextResponse } from "next/server";
import { createClient } from "@/lib/supabase/server";
import { resolveEmailForEntity } from "@/lib/email/resolve-entity";

// Resolves "who would this go to, what's the subject/body, what
// attachment" for the Email compose dialog. The actual resolution logic
// lives in src/lib/email/resolve-entity.ts, shared with /api/email/send,
// which independently re-derives this same answer right before sending
// rather than trusting whatever the client last saw here.
export async function POST(req: Request) {
  const { entityType, entityId } = await req.json();
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) return NextResponse.json({ error: "Not authenticated." }, { status: 401 });

  const result = await resolveEmailForEntity(entityType, entityId, supabase);
  if ("error" in result) return NextResponse.json({ error: result.error }, { status: result.status });

  // Only the fields the compose dialog actually needs go to the client --
  // organizationName/numberLabel/packetStoragePath/statementStoragePath are
  // internal, used only by /api/email/send's own re-resolution.
  const { to, subject, message, attachmentType, attachmentLabel, blocked } = result;
  return NextResponse.json({ to, subject, message, attachmentType, attachmentLabel, blocked });
}
