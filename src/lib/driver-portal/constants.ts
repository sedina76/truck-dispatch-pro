// Plain constants shared between the driver-portal server actions
// ("use server" files can only export async functions, never plain
// values) and client components.
export const DRIVER_SUBMITTABLE_CATEGORIES = ["lumper", "fuel", "tolls", "scale_ticket", "parking", "permit", "washout", "other"] as const;
