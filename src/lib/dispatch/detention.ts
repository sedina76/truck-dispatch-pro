// Detention calculation (display only -- no automatic billing). Reused by
// both the dispatch card exception badge and the drawer's Pickup/Delivery
// sections, so the two can never disagree about whether a stop is in
// detention.
//
// Rule: while the truck is still at the stop (arrived, not yet departed),
// detention = now - arrival - free time. Once departed, it's frozen at
// departure - arrival - free time. Never negative -- under free time
// simply means no detention, not a negative duration.

export type DetentionResult = {
  inDetention: boolean;
  minutes: number;
  label: string; // e.g. "1h 42m"
};

export function calculateDetention(
  arrivedAt: string | null,
  departedAt: string | null,
  freeMinutes: number,
  now: Date = new Date()
): DetentionResult | null {
  if (!arrivedAt) return null; // Never calculated without a real arrival time.

  const arrived = new Date(arrivedAt).getTime();
  const end = departedAt ? new Date(departedAt).getTime() : now.getTime();
  const elapsedMinutes = Math.floor((end - arrived) / 60000);
  const overMinutes = elapsedMinutes - freeMinutes;

  if (overMinutes <= 0) {
    return { inDetention: false, minutes: 0, label: "" };
  }

  return { inDetention: true, minutes: overMinutes, label: formatMinutes(overMinutes) };
}

export function formatMinutes(totalMinutes: number): string {
  const h = Math.floor(totalMinutes / 60);
  const m = totalMinutes % 60;
  if (h === 0) return `${m}m`;
  return `${h}h ${m}m`;
}
