// The nightly backup must only ever upload ENCRYPTED copies, never print
// secrets or file names, never write to the database, and stay documented.
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const read = (p) => readFileSync(new URL(p, import.meta.url), "utf8");
const wf = read("../../../.github/workflows/backup.yml");
const sync = read("../../../scripts/backup/storage_sync.py");
const docs = read("../../../docs/BACKUPS.md");

test("database dump is encrypted before it is uploaded, and the plain copy is removed", () => {
  const enc = wf.indexOf("--symmetric --cipher-algo AES256 -o work/db.tar.gz.gpg");
  const rm = wf.indexOf("rm -rf work/db work/db.tar.gz");
  const up = wf.indexOf('s3://$R2_BUCKET/db/');
  assert.ok(enc > 0 && rm > enc && up > rm, "encrypt -> delete plain -> upload");
  assert.match(wf, /s3:\/\/\$R2_BUCKET\/db\/\$stamp\/db\.tar\.gz\.gpg/);
});

test("files are encrypted one by one and only .gpg copies go to R2", () => {
  assert.match(sync, /def r2_key\(bucket, name\):\n\s+return f"files\/\{bucket\}\/\{name\}\.gpg"/);
  const body = sync.slice(sync.indexOf("def main"));
  assert.ok(body.indexOf("encrypt(plain, sealed)") < body.indexOf("upload(sealed, r2_key(bucket, name))"));
  assert.doesNotMatch(body, /upload\(plain/);
});

test("read-only on the database, no secrets or names in the log", () => {
  assert.doesNotMatch(wf, /\b(insert|update|delete|truncate|drop)\b[^\n]*storage\.objects/i);
  assert.match(wf, /select bucket_id, name/);
  assert.doesNotMatch(wf, /echo[^\n]*\$(BACKUP_PASSPHRASE|SUPABASE_SERVICE_ROLE_KEY|SUPABASE_DB_URL|AWS_SECRET_ACCESS_KEY)/);
  assert.doesNotMatch(sync, /print\([^)]*\bname\b[^)]*\)/);
});

test("runs nightly, can be started by hand, and is documented with a restore guide", () => {
  assert.match(wf, /cron: "17 8 \* \* \*"/);
  assert.match(wf, /workflow_dispatch:/);
  for (const s of ["SUPABASE_DB_URL", "SUPABASE_URL", "SUPABASE_SERVICE_ROLE_KEY", "R2_ACCOUNT_ID", "R2_ACCESS_KEY_ID", "R2_SECRET_ACCESS_KEY", "BACKUP_PASSPHRASE"]) {
    assert.match(wf, new RegExp(`secrets\\.${s}\\b`));
    assert.match(docs, new RegExp("`" + s + "`"));
  }
  assert.match(docs, /## Restore/);
  assert.match(docs, /## Monthly test restore/);
});
