// Number fields must only change when the user TYPES a value.
//
// Browsers step a focused <input type="number"> by its `step` on ArrowUp /
// ArrowDown (and, in some browsers, on mouse-wheel / trackpad scroll), and
// show tiny spinner arrows that do the same. With step="0.01" on every money
// field, pressing or holding the down arrow -- e.g. to move down the page --
// silently turns a 7500.00 load rate into 7499.31 (69 steps), which the form
// then saves. The app-wide guard (components/ui/number-wheel-guard.tsx)
// blocks those steps; globals.css hides the spinners.

type Target = { tagName?: string; type?: string; readOnly?: boolean } | null;

function isNumberInput(t: Target): boolean {
  return !!t && String(t.tagName).toUpperCase() === "INPUT" && String(t.type).toLowerCase() === "number";
}

/** True when this wheel event would change a focused number field's value. */
export function wheelWouldChangeNumber(target: Target, active: unknown): boolean {
  return isNumberInput(target) && target === active;
}

/** True when this key press would step a number field's value. */
export function keyWouldStepNumber(target: Target, key: string): boolean {
  return isNumberInput(target) && (key === "ArrowUp" || key === "ArrowDown" || key === "PageUp" || key === "PageDown");
}
