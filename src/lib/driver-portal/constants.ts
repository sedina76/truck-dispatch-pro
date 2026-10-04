// Plain constants shared between the driver-portal server actions
// ("use server" files can only export async functions, never plain
// values) and client components.
export const DRIVER_SUBMITTABLE_CATEGORIES = ["lumper", "fuel", "tolls", "scale_ticket", "parking", "permit", "washout", "other"] as const;

// How the driver paid for fuel -> fuel_logs.paid_by (0051).
export const DRIVER_FUEL_PAID_BY = [
  { value: "carrier", label: "Carrier fuel card" },
  { value: "driver", label: "My own money" },
  { value: "dispatch_company", label: "Dispatch company card / advance" },
  { value: "other", label: "Other" },
] as const;
