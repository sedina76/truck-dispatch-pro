// Second safety net: a changed rate must be confirmed before saving; rate changes are logged; blank rate refused.
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { moneyChange, moneyChangeMessage } from "./money-change.ts";

const read = (p) => readFileSync(new URL(p, import.meta.url), "utf8");

test("detects a change of a cent or more, ignores equal/blank values", () => {
  assert.deepEqual(moneyChange("Rate", "7500", "7499.31"), { label: "Rate", from: 7500, to: 7499.31 });
  assert.equal(moneyChange("Rate", "7500", "7500.00"), null);
  assert.equal(moneyChange("Rate", "7500.004", "7500"), null);
  assert.equal(moneyChange("Rate", "", "7500"), null, "new record: nothing to compare");
  assert.equal(moneyChange("Rate", "7500", ""), null, "blank is refused server-side instead");
  assert.equal(moneyChange("Rate", "7500", "abc"), null);
});

test("the question names the field and both amounts", () => {
  assert.equal(moneyChangeMessage([{ label: "The load rate", from: 7500, to: 7499.31 }]),
    "The load rate will change from $7,500.00 to $7,499.31.\n\nSave this change?");
});

test("load edit rate field asks before saving a change; guard runs before React's action", () => {
  assert.match(read("../../app/(app)/loads/[id]/page.tsx"), /name="rate"[^>]*confirmChange="The load rate"/);
  const field = read("../../components/ui/form-field.tsx");
  assert.match(field, /"data-confirm-change": confirmChange, "data-original-value"/);
  const guard = read("../../components/ui/number-wheel-guard.tsx");
  assert.match(guard, /addEventListener\("submit", onSubmit, \{ capture: true \}\)/);
  assert.match(guard, /window\.confirm\(moneyChangeMessage\(changes\)\)/);
  assert.match(guard, /e\.preventDefault\(\);\s*e\.stopImmediatePropagation\(\);/);
});

test("rate changes are logged with old and new amount; a blank rate is refused, never saved as $0", () => {
  const actions = read("../../app/(app)/loads/actions.ts");
  assert.match(actions, /if \(rate === null \|\| rate < 0\) throw new Error\("Enter a valid rate\."\);/);
  assert.match(actions, /p_action: "rate_changed",\s*p_changes: \{ field: "rate", old_value: Number\(previous\.rate\), new_value: rate \}/);
  assert.doesNotMatch(actions, /toNumber\(formData\.get\("rate"\)\) \?\? 0/);
});
