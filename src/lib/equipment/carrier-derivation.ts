// Single shared implementation of the Truck/Trailer -> Carrier derivation
// rule, used across every module that lets staff pick a truck and/or
// trailer and needs the owning carrier to follow automatically: Maintenance
// (EquipmentServiceFields, maintenance-filter-bar.tsx) and Fuel Logs
// (fuel-form-fields.tsx -- truck-only, trailer always passed as null/
// undefined there since fuel_logs has no trailer_id). Mirrors, byte-for-
// byte, the same resolution order enforced server-side by
// guard_maintenance_org() (0050) and guard_fuel_log_org() (0051,
// live-verified):
//   - a truck with its own carrier always resolves that carrier
//   - otherwise a trailer with its own carrier resolves that carrier
//   - a truck AND trailer that resolve to two DIFFERENT real carriers is a
//     hard mismatch -- never silently resolved one way or the other
//   - neither resolving (nothing selected, or selected equipment has no
//     carrier) leaves the carrier a normal, manually-selectable field
//
// This file is a pure, side-effect-free UI-derivation helper only. It does
// not read/write the database, and it must never be treated as the source
// of truth for anything financial -- that remains the DB guard triggers
// named above.
//
// Originally lived at src/lib/maintenance/carrier-derivation.ts; moved
// here (Fuel Recovery task, 0051) once a second, non-maintenance module
// needed the exact same rule -- the logic itself is unchanged.

export type EquipmentCarrierRef = { carrier_id: string | null; carrier_name?: string | null; unit_number?: string } | null | undefined;

export type CarrierDerivation =
  | { kind: "resolved"; carrierId: string; carrierName: string | null; source: "truck" | "trailer"; unitNumber?: string }
  | { kind: "mismatch"; truckCarrierName: string | null; trailerCarrierName: string | null }
  | { kind: "manual" };

export function resolveEquipmentCarrier(truck: EquipmentCarrierRef, trailer: EquipmentCarrierRef): CarrierDerivation {
  const truckCarrierId = truck?.carrier_id ?? null;
  const trailerCarrierId = trailer?.carrier_id ?? null;

  if (truckCarrierId && trailerCarrierId && truckCarrierId !== trailerCarrierId) {
    return { kind: "mismatch", truckCarrierName: truck?.carrier_name ?? null, trailerCarrierName: trailer?.carrier_name ?? null };
  }
  if (truck && truckCarrierId) {
    return { kind: "resolved", carrierId: truckCarrierId, carrierName: truck.carrier_name ?? null, source: "truck", unitNumber: truck.unit_number };
  }
  if (trailer && trailerCarrierId) {
    return { kind: "resolved", carrierId: trailerCarrierId, carrierName: trailer.carrier_name ?? null, source: "trailer", unitNumber: trailer.unit_number };
  }
  return { kind: "manual" };
}
