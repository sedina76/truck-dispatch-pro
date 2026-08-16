import "server-only";
import type { RoutingProvider } from "./types";
import { OsrmProvider } from "./osrm-provider";

// Single place the rest of the app asks "what routing provider is
// configured right now" -- never imports OsrmProvider (or any future
// provider) directly. Set ROUTING_PROVIDER=none to explicitly disable
// route calculation (graceful degrade, spec section 5) without removing
// code; any other value (or unset) uses OSRM.
export function getRoutingProvider(): RoutingProvider | null {
  if (process.env.ROUTING_PROVIDER === "none") return null;
  return new OsrmProvider();
}
