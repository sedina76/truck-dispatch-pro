// Viewing a carrier document (e.g. an NOA the carrier uploaded during
// onboarding) works even though older onboarding rows recorded the wrong
// storage bucket, and problems are shown as plain text, not the hidden
// "Server Components render" error.
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const src = (p) => readFileSync(new URL(p, import.meta.url), "utf8");

test("the carrier document link verifies the row first, then finds the file in the recorded or known buckets", () => {
  const a = src("./carrier-document-actions.ts");
  const fn = a.slice(a.indexOf("export async function getCarrierDocumentSignedUrl"), a.indexOf("// Delete a carrier document"));
  // RLS-scoped ownership check comes before any service-role use
  assert.ok(fn.indexOf('.from("documents")') < fn.indexOf("createServiceRoleClient()"));
  assert.match(fn, /\.eq\("organization_id", organizationId\)/);
  assert.match(fn, /doc\.file_path\.startsWith\(`\$\{organizationId\}\/`\)/, "never signs a path outside the org's folder");
  assert.match(a, /const KNOWN_DOCUMENT_BUCKETS = \["load-documents", "carrier-onboarding-documents", "documents", "carrier-w9s"\];/);
  assert.ok(!/throw new Error/.test(fn), "returns its problems so they are readable in production");
});

test("onboarding uploads record their real bucket", () => {
  const a = src("../../carrier-onboarding/actions.ts");
  assert.match(a, /storage_bucket: "carrier-onboarding-documents",/);
});

test("the shared document button shows a returned error", () => {
  const b = src("../../../components/drivers/document-link-button.tsx");
  assert.match(b, /getUrl: \(\) => Promise<string \| \{ error: string \}>/);
  assert.match(b, /if \(typeof result !== "string"\) \{\s*setError\(result\.error\);/);
});
