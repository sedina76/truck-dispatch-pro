// Per-carrier "who does the broker pay?" setting: labels and result text.
import test from "node:test";
import assert from "node:assert/strict";
import { brokerPaysLabel, brokerPaysOf, brokerPaysResultMessage } from "./broker-pays.ts";

test("no setting means the broker pays us", () => {
  assert.equal(brokerPaysOf(null), "dispatcher_receives_funds");
  assert.equal(brokerPaysOf("carrier_paid_directly"), "carrier_paid_directly");
  assert.equal(brokerPaysLabel(undefined), "Broker pays us");
  assert.equal(brokerPaysLabel("carrier_paid_directly"), "Broker pays the carrier");
});

test("result message", () => {
  assert.equal(brokerPaysResultMessage({ loads_switched: 0, broker_drafts_removed: 0, kept: [] }), "No open loads needed to change.");
  assert.equal(
    brokerPaysResultMessage({ loads_switched: 2, broker_drafts_removed: 1, kept: ["LC (already invoiced to the broker)", "LD (already settled or fee-invoiced)"] }),
    "2 open loads moved to the new setting. 1 unsent draft broker invoice was removed. Kept as before: LC (already invoiced to the broker); LD (already settled or fee-invoiced)."
  );
  assert.match(brokerPaysResultMessage({ loads_switched: 1, broker_drafts_removed: 3, kept: [] }), /^1 open load moved.*3 unsent draft broker invoices were removed\.$/);
});
