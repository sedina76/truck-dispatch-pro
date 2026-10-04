// Load documents upload in one step: the Upload button opens the file picker
// and the file uploads as soon as it's chosen. The POD box shows POD once.
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const src = (p) => readFileSync(new URL(p, import.meta.url), "utf8");

test("Upload opens the picker and uploads on choose; no visible Choose File input", () => {
  const form = src("./upload-document-form.tsx");
  assert.match(form, /type="file"[^>]*onChange=\{handleChosen\}[^>]*className="hidden"/);
  assert.match(form, /onClick=\{\(\) => inputRef\.current\?\.click\(\)\}/);
  assert.match(form, /await submitFile\(file\)/);
  assert.ok(!/<form onSubmit/.test(form));
  assert.match(form, /"Uploading\.\.\." : label/);
});

test("POD box: one status line, Upload/Replace POD buttons; billing note before delivery", () => {
  const panel = src("../dispatch/documents-panel.tsx");
  assert.match(panel, /<SimpleDocumentSlot\s+buttonsOnly[\s\S]*?label=\{podEntry\?\.doc \? "Replace POD" : "Upload POD"\}/);
  assert.ok(!panel.includes('label="POD File"'));
  assert.match(panel, /isDelivered \? "Documents Needed" : "After delivery \(needs the POD\)"/);
  const slot = src("./simple-document-slot.tsx");
  assert.match(slot, /label=\{buttonsOnly \? label : doc \? "Replace" : "Upload"\}/);
});
