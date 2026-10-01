# Proposal 0156 -- Owner decisions for F-08 (RECORDED) and status of this proposal

**Status of 0156: SUPERSEDED FOR PRODUCTION USE and NOT PROMOTABLE for legacy invoices.** The Owner decided (below) that legacy `invoices` are excluded from automatic factoring. Proposal 0156 (legacy-invoice submission behind a disabled gate) is kept, with its tests and history, but its gate must stay DISABLED forever and it must not be promoted. The carrier-invoice design is **proposal 0157** (`../0157/`). These decisions do NOT authorize production execution, and nothing here is approved.

## Owner decisions (recorded verbatim in substance)
* **D-08a: NO.** A submission-time snapshot is not acceptable as a reconstruction mechanism for legacy `invoices`.
* **D-08b:** Factoring applies ONLY to `carrier_invoices`. Legacy `invoices` remain excluded from automatic factoring.
* **D-08c:** Organization owners/admins, and authorized dispatchers with EXPLICIT access to the invoice's carrier, may submit. The factoring relationship is selected SERVER-SIDE from that carrier's active default relationship. The user may never choose an arbitrary factor or relationship.
* **D-08d:** Dispatch-service fees are separate carrier-to-dispatcher receivables and must never be included in the carrier invoice submitted to the factor.
* **D-08e:** Only `sent` or `viewed` carrier invoices with `amount_paid = 0` qualify; draft, partially paid, paid, void, cancelled, disputed or otherwise ineligible invoices are refused. (*Schema finding:* carrier invoices have no sent/viewed/cancelled/disputed state -- see 0157/OWNER_DECISIONS.md for the mapping that was implemented and the clarification requested.)
* **D-08f:** Carriers classified as non-factoring-eligible or approved for direct billing are refused.
* **D-08g:** The active relationship's advance, fee and reserve terms at submission time are recorded as an immutable snapshot.
* **D-08h:** Only the SQL Editor operator may enable or disable the feature gate, using a recorded Owner decision reference. Disabling blocks NEW submissions but preserves existing submissions and immutable snapshots.
* **D-08i:** Every relevant 0155 review and every applicable legacy factoring conflict must be resolved before the gate may be enabled.

## What this means for 0156
* 0156's legacy gate (`public.factoring_submission_gate`) stays **disabled**; 0157 refuses to apply while it is enabled, and its own gate cannot be enabled while it is enabled.
* 0156's earlier questions D-08a..i are answered by the decisions above; the UI gap it recorded (D-08c) is implemented for carrier invoices in 0157 and is deliberately NOT implemented for legacy invoices (`src/lib/factoring/carrier-invoice-ui-contract.test.mjs` proves the legacy page and action do not reference the new path).
* Legacy invoices that are still unpaid and were factored before 0140, or need factoring going forward, must be **reissued as carrier invoices** through the 0142-0147 workflow (there is still no UI for that workflow -- a separate product task).
* The 0156 tests remain in `../0154/tests.py` and `src/lib/factoring/submission-contract.test.mjs` (history); they do not imply the legacy path may be enabled.
