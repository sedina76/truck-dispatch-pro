#!/usr/bin/env node
// =============================================================================
// scripts/cleanup-test-org-files.mjs
//
// Deletes the stored files (Supabase Storage) belonging to the 57 TEST-*
// fixture organizations listed below, so that
// supabase/archive/one-off-sql/CLEANUP_TEST_ORGS_2026_09.sql (completed 2026-09-30) removed their database rows.
// Supabase does not allow deleting storage files from SQL, so this uses the
// Storage REST API with the service-role key. No npm packages needed.
//
// DRY RUN by default -- lists what it would delete and changes nothing:
//   node --env-file=.env.local scripts/cleanup-test-org-files.mjs
// Real run:
//   node --env-file=.env.local scripts/cleanup-test-org-files.mjs --commit
//
// Needs NEXT_PUBLIC_SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY (from your
// .env.local). Only paths whose FIRST folder is one of these exact org ids are
// ever touched -- every app upload path starts with the organization id.
// =============================================================================

const TEST_ORG_IDS = [
  "cff1741f-482c-4dec-ae56-9aa96b437222",
  "77573b3e-b592-4a57-873d-730691e46664",
  "c8c54b0d-2884-4834-b157-fcf21b3771f4",
  "e0e1b6b7-a500-4f20-9c4a-19c90b4c9f4e",
  "f4fad9a1-361f-4b0c-8b46-b7a48375e834",
  "67fcdf5a-81af-46f2-b49a-2f299ea32933",
  "8e5d429d-f42e-493a-989d-6a8bfeeedc8f",
  "fb679df5-855a-461f-ba37-93372e20af84",
  "ab7acc7b-88c2-4bcd-8a9e-1aa885075a04",
  "3b447641-ae2e-41f9-95f2-4812fee76379",
  "29006a77-b880-4824-a92a-071f36ee2bbc",
  "1d6b5a35-c873-4b60-afe0-8a0e4511b0f8",
  "0f6dde3a-318b-4dca-ac8c-077144988468",
  "70a8b305-f4e4-41f4-996b-d8e0c10bfca9",
  "048151a4-e631-43d1-9cd7-016c33d77441",
  "5882ee05-468b-4bde-ac80-29c2a765e5f4",
  "253ea23e-2d5c-4526-8d4c-f97e485d2a24",
  "8b954676-1d2c-45e6-b782-50a6a18be673",
  "4c317e8e-63ea-4be4-b257-2fd66a2ed19f",
  "46e4b9f5-4b75-4804-b86f-4c763e69d3cf",
  "5e5c6fc1-ef93-4c96-98b2-33d2fcf98467",
  "90011a38-da5e-49c0-85a8-d28d59ff38f0",
  "b0b7d39a-538c-4025-b27d-8cf005cca265",
  "5cab052d-e873-42eb-a983-b5e82f609f85",
  "0595592d-bb41-45b4-b975-2e350b3f1c8f",
  "d5406dde-e16e-481d-9bca-50e384920316",
  "80345581-6e8f-494d-95e0-928e56cfc607",
  "b336c6eb-d663-4dd2-a9a9-ec329ba23578",
  "21cec5aa-b1cf-4351-8e57-184351d675c1",
  "87d3daae-73c3-4489-ab53-b2f8840478e2",
  "08e86b20-1c93-4cc3-b19c-ac949e96ed21",
  "6003480c-4b2d-42ac-9920-e4ee7567df16",
  "4eaaf343-a644-4359-88b7-0ce903a2d2d6",
  "cf4a79d6-aa11-4e76-bed0-3fadca473935",
  "21bb7b0c-8e74-460c-bd17-5c59d8ea77ae",
  "6543132f-8c8a-4bd9-bdc6-a9ab91cacd3b",
  "d8dd013f-5856-4911-b095-ef3520cad379",
  "64df4ebc-4c24-4b76-9be3-92ae05e9b052",
  "1a5cf430-c8e3-4e39-be13-ccdea79f37ce",
  "3ab05428-d4fb-4bcd-90c0-fe24642cfc6f",
  "4c7bf062-35ee-4c27-8ec3-ae402dc293cf",
  "096afba5-c76c-4092-8b9b-59146a6b8b61",
  "80b9f8e3-6958-4ac7-b6a3-401c7ff77022",
  "6023cf3b-d66d-4e20-871f-2837483261c6",
  "0adb64d6-4917-4c70-9afd-a4ab1c0e003e",
  "7378100f-9e42-4fce-87b7-8142bc10d754",
  "188f9b7d-caaf-4ae5-aab8-d85d759af681",
  "a1dea96d-5a30-4b76-bdec-3910d9bd29db",
  "f5040e1f-2986-449f-a747-2004bf295db3",
  "3839e890-f055-4dca-952d-0de0b1fdd789",
  "0dff921c-e114-4e73-a697-1e45eb7b80be",
  "47a44ff3-cacb-4f98-b548-6130df618d6b",
  "b8ac115b-0251-471a-8f66-e0fb71e6e03c",
  "a24bc06e-c381-436a-b1c0-1cf961269fc7",
  "84e06630-db6b-4826-8903-1e17ae8b7408",
  "0c52867f-86fb-4cad-b0a4-f845426aa86f",
  "1f2200b8-146e-4ea4-94fb-8e78b92002b9"
];

const COMMIT = process.argv.includes("--commit");
const URL_BASE = (process.env.SUPABASE_URL || process.env.NEXT_PUBLIC_SUPABASE_URL || "").replace(/\/$/, "");
const KEY = process.env.SUPABASE_SERVICE_ROLE_KEY || "";

if (!URL_BASE || !KEY) {
  console.error("Missing NEXT_PUBLIC_SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY. Run with --env-file=<path to .env.local>.");
  process.exit(1);
}
if (TEST_ORG_IDS.length !== 57 || new Set(TEST_ORG_IDS).size !== 57) {
  console.error(`Safety stop: expected exactly 57 unique org ids, found ${TEST_ORG_IDS.length}.`);
  process.exit(1);
}
const ID_SET = new Set(TEST_ORG_IDS);

const headers = { Authorization: `Bearer ${KEY}`, apikey: KEY, "Content-Type": "application/json" };

async function api(method, path, body) {
  const res = await fetch(`${URL_BASE}/storage/v1${path}`, { method, headers, body: body ? JSON.stringify(body) : undefined });
  const text = await res.text();
  if (!res.ok) throw new Error(`${method} ${path} -> HTTP ${res.status}: ${text.slice(0, 300)}`);
  return text ? JSON.parse(text) : null;
}

// Recursively list every file under `prefix` in `bucket`.
async function listAll(bucket, prefix) {
  const files = [];
  const PAGE = 1000;
  for (let offset = 0; ; offset += PAGE) {
    const entries = await api("POST", `/object/list/${encodeURIComponent(bucket)}`, {
      prefix, limit: PAGE, offset, sortBy: { column: "name", order: "asc" },
    });
    for (const e of entries) {
      const full = `${prefix}/${e.name}`;
      if (e.id === null || e.id === undefined) files.push(...(await listAll(bucket, full))); // folder
      else files.push({ path: full, size: e.metadata?.size ?? 0 });
    }
    if (entries.length < PAGE) break;
  }
  return files;
}

const host = new URL(URL_BASE).host;
console.log(`Project: ${host}`);
console.log(COMMIT ? "MODE: COMMIT (files WILL be deleted)\n" : "MODE: DRY RUN (nothing will be deleted)\n");

const buckets = await api("GET", "/bucket");
let total = 0;
const plan = [];
for (const b of buckets) {
  for (const orgId of TEST_ORG_IDS) {
    const files = await listAll(b.id, orgId);
    for (const f of files) {
      // Belt and braces: the first path segment must be exactly a target org id.
      if (!ID_SET.has(f.path.split("/")[0])) throw new Error(`Refusing unexpected path ${f.path}`);
      plan.push({ bucket: b.id, path: f.path });
      total++;
    }
  }
}

const byBucket = {};
for (const p of plan) byBucket[p.bucket] = (byBucket[p.bucket] || 0) + 1;
for (const p of plan) console.log(`  ${p.bucket}/${p.path}`);
console.log(`\n${total} file(s) across ${Object.keys(byBucket).length} bucket(s): ${JSON.stringify(byBucket)}`);

if (!COMMIT) {
  console.log("\nDRY RUN complete -- nothing was deleted. Re-run with --commit to delete these files.");
  process.exit(0);
}

let deleted = 0;
for (const [bucket] of Object.entries(byBucket)) {
  const paths = plan.filter((p) => p.bucket === bucket).map((p) => p.path);
  for (let i = 0; i < paths.length; i += 100) {
    const batch = paths.slice(i, i + 100);
    const res = await api("DELETE", `/object/${encodeURIComponent(bucket)}`, { prefixes: batch });
    deleted += Array.isArray(res) ? res.length : 0;
  }
}
console.log(`\nDeleted ${deleted} of ${total} file(s).`);

// Verify nothing is left.
let left = 0;
for (const b of buckets) for (const orgId of TEST_ORG_IDS) left += (await listAll(b.id, orgId)).length;
console.log(left === 0 ? "Verified: 0 files remain for these organizations." : `WARNING: ${left} file(s) still remain -- run again.`);
process.exit(left === 0 ? 0 : 2);
