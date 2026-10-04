// The dispatch panel and page describe money as a dispatch service earns it:
// the load rate is the carrier's, your income is the dispatch fee, and the
// line underneath says who the broker pays.
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const src = (p) => readFileSync(new URL(p, import.meta.url), "utf8");

test("one shared money breakdown, dispatch-service wording, who-pays-whom line", () => {
  const panel = src("./internal-financials-panel.tsx");
  for (const label of ["Load Rate (from broker)", "Carrier's Share", "Your Dispatch Fee ("]) assert.ok(panel.includes(label), label);
  assert.ok(!/Company Gross Margin|Estimated Profit|"Revenue"|Carrier Cost/.test(panel));
  assert.match(panel, /The broker pays the carrier \$\{money\(loadRate\)\}; you bill the carrier your \$\{money\(fee\)\} fee\./);
  assert.match(panel, /The broker pays you \$\{money\(loadRate\)\}; you pay the carrier \$\{money\(share\)\} and keep \$\{money\(fee\)\}\./);
  const drawer = src("./dispatch-drawer.tsx");
  assert.match(drawer, /<InternalFinancialsPanel\s+compact/);
  assert.match(drawer, /brokerPays=\{data\.financials\.brokerPays\}/);
  assert.ok(!/label="Estimated Profit"|label="Revenue"|label="Carrier Cost"|label="Dispatch #"/.test(drawer));
  assert.match(drawer, /rounded-full bg-white px-2 py-0\.5/, "status readable on the blue header");
  const page = src("../../app/(app)/dispatch/[id]/page.tsx");
  assert.match(page, /const \[summary, options, rateConDoc, financialsRes, proceedsRes, notesRes\]/);
  assert.match(page, /brokerPays=\{brokerPays\}/);
  const board = src("../../app/(app)/dispatch/board-actions.ts");
  assert.match(board, /if \(canSeeFinancials\) \{\s+const \{ data: pm, error: pmError \} = await supabase\.from\("dispatches"\)\.select\("proceeds_model"\)/);
});
