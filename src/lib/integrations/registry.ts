// The ONE canonical source of provider metadata (spec section 7) -- name,
// category, connection type, capabilities, and whether a real connector
// exists. Nothing else in this app hard-codes a provider's display name or
// decides "does this support Test/Sync/OAuth" independently; every card,
// filter, and detail page reads from here. Per-org DYNAMIC state (enabled,
// last tested, last error) lives in integration_settings (0056) and is
// joined against this by `provider` id at render time.
//
// `implemented` is the single honest gate for the whole UI: false means no
// real API client/OAuth app/webhook exists for this provider in this
// codebase, full stop -- the UI must never offer a setup flow that can't
// actually do anything (spec: "Do NOT fake integrations").

export type IntegrationCategory = "load_boards" | "accounting" | "communications" | "billing" | "telematics" | "compliance";

export type ConnectionType =
  | "api_key" // static API key/token, optionally + webhook
  | "oauth2" // OAuth2 authorization-code flow
  | "webhook_only"
  | "manual" // vendor-approved credentials issued outside any self-serve flow (e.g. DAT partner API)
  | "internal" // not a tenant-configurable connection at all (e.g. platform billing)
  | "coming_soon";

/** Who actually holds the credential. Never mix these (spec section 6). */
export type CredentialScope =
  | "platform" // one shared credential for the whole app (server env var), e.g. Resend
  | "organization" // one credential per tenant, stored/connected per org
  | "not_applicable";

export type ProviderId =
  | "resend"
  | "sendgrid"
  | "quickbooks"
  | "stripe"
  | "twilio"
  | "dat"
  | "truckstop"
  | "loadboard_123"
  | "motive"
  | "samsara"
  | "rmis"
  | "highway"
  | "carrier411";

export type ProviderDefinition = {
  id: ProviderId;
  name: string;
  description: string;
  category: IntegrationCategory;
  connectionType: ConnectionType;
  capabilities: string[];
  /** Is there a real, working connector in this codebase right now? The one flag every "fake it" shortcut must never override. */
  implemented: boolean;
  supportsTest: boolean;
  supportsSync: boolean;
  supportsWebhook: boolean;
  supportsOAuth: boolean;
  credentialScope: CredentialScope;
  /** Plain-language "what you'd need to actually connect this," shown on the detail page whether or not it's implemented. */
  setupRequirements: string[];
  /** Shown to the user in place of a setup flow when implemented=false. Always present when implemented=false. */
  notImplementedReason?: string;
  /** True only for providers explicitly owned by the Platform Console, never tenant-configurable here (spec section 15). */
  managedByPlatform?: boolean;
};

export const PROVIDERS: ProviderDefinition[] = [
  // ---------------------------------------------------------------------
  // Communications
  // ---------------------------------------------------------------------
  {
    id: "resend",
    name: "Resend",
    description: "Transactional email for invoices, receipts, settlements, statements, and profile sharing.",
    category: "communications",
    connectionType: "api_key",
    capabilities: ["transactional_email"],
    implemented: true,
    supportsTest: true,
    supportsSync: false,
    supportsWebhook: false,
    supportsOAuth: false,
    credentialScope: "platform",
    setupRequirements: [
      "RESEND_API_KEY (server environment variable)",
      "A domain added and verified in Resend",
      "EMAIL_FROM using an address on that verified domain",
      "EMAIL_REPLY_TO (optional)",
    ],
  },
  {
    id: "sendgrid",
    name: "SendGrid",
    description: "Not used. Resend is this app's active transactional email provider.",
    category: "communications",
    connectionType: "coming_soon",
    capabilities: ["transactional_email"],
    implemented: false,
    supportsTest: false,
    supportsSync: false,
    supportsWebhook: false,
    supportsOAuth: false,
    credentialScope: "not_applicable",
    setupRequirements: [],
    notImplementedReason: "Not used -- Resend is the configured email provider for this app. No SendGrid client exists in this codebase.",
  },
  {
    id: "twilio",
    name: "Twilio",
    description: "SMS check-calls and alerts.",
    category: "communications",
    connectionType: "api_key",
    capabilities: ["sms"],
    implemented: false,
    supportsTest: false,
    supportsSync: false,
    supportsWebhook: false,
    supportsOAuth: false,
    credentialScope: "organization",
    setupRequirements: ["Twilio Account SID", "Twilio Auth Token", "A Messaging Service SID or a Twilio phone number"],
    notImplementedReason: "No Twilio client is implemented in this codebase yet.",
  },

  // ---------------------------------------------------------------------
  // Accounting
  // ---------------------------------------------------------------------
  {
    id: "quickbooks",
    name: "QuickBooks Online",
    description: "Push invoices and payments, sync customers.",
    category: "accounting",
    connectionType: "oauth2",
    capabilities: ["invoices", "payments", "customers"],
    implemented: false,
    supportsTest: false,
    supportsSync: false,
    supportsWebhook: false,
    supportsOAuth: true,
    credentialScope: "organization",
    setupRequirements: [
      "A registered QuickBooks (Intuit) Developer app",
      "QUICKBOOKS_CLIENT_ID / QUICKBOOKS_CLIENT_SECRET (server env vars -- never NEXT_PUBLIC_*)",
      "QUICKBOOKS_ENVIRONMENT=sandbox and QUICKBOOKS_REDIRECT_URI (server env vars)",
      "Redirect URI registered in Intuit: https://truck-dispatch-pro.vercel.app/api/integrations/quickbooks/callback",
      "Database migration 0116_quickbooks_oauth_foundation.sql applied",
    ],
    // The OAuth foundation (callback route, encrypted token storage design,
    // connect/disconnect flow) exists in the codebase. `implemented` stays
    // false until migration 0116 is applied AND the QUICKBOOKS_* env vars
    // are set -- the /settings/integrations/quickbooks page renders its own
    // QuickBooks connection card regardless and shows exactly what is still
    // needed.
    notImplementedReason: "OAuth foundation is in the codebase but not yet activated for this deployment -- apply migration 0116 and set the QUICKBOOKS_* server environment variables. See the QuickBooks page for the exact steps.",
  },

  // ---------------------------------------------------------------------
  // Billing -- platform-owned, not tenant-configurable (spec section 15)
  // ---------------------------------------------------------------------
  {
    id: "stripe",
    name: "Stripe",
    description: "Platform subscription billing for Truck Dispatch Pro itself.",
    category: "billing",
    connectionType: "internal",
    capabilities: ["platform_subscription_billing"],
    implemented: false,
    supportsTest: false,
    supportsSync: false,
    supportsWebhook: false,
    supportsOAuth: false,
    credentialScope: "platform",
    setupRequirements: [],
    notImplementedReason: "Managed by the Platform Console, not by individual organizations. Tenant admins cannot configure the platform's Stripe secret here.",
    managedByPlatform: true,
  },

  // ---------------------------------------------------------------------
  // Load boards -- all vendor-restricted, no self-serve public API
  // ---------------------------------------------------------------------
  {
    id: "dat",
    name: "DAT",
    description: "Load board search and posting.",
    category: "load_boards",
    connectionType: "manual",
    capabilities: ["load_search", "load_posting"],
    implemented: false,
    supportsTest: false,
    supportsSync: false,
    supportsWebhook: false,
    supportsOAuth: false,
    credentialScope: "organization",
    setupRequirements: ["DAT-approved API access", "DAT Client ID", "DAT Client Secret"],
    notImplementedReason: "DAT's API requires vendor approval and issued credentials. No DAT API client exists in this codebase, and this integration will never scrape or emulate a browser login.",
  },
  {
    id: "truckstop",
    name: "Truckstop",
    description: "Load board search and posting.",
    category: "load_boards",
    connectionType: "manual",
    capabilities: ["load_search", "load_posting"],
    implemented: false,
    supportsTest: false,
    supportsSync: false,
    supportsWebhook: false,
    supportsOAuth: false,
    credentialScope: "organization",
    setupRequirements: ["Truckstop-approved API access", "Vendor-issued API credentials"],
    notImplementedReason: "Truckstop's API requires vendor approval and issued credentials. No connector exists in this codebase.",
  },
  {
    id: "loadboard_123",
    name: "123Loadboard",
    description: "Load board search and posting.",
    category: "load_boards",
    connectionType: "manual",
    capabilities: ["load_search", "load_posting"],
    implemented: false,
    supportsTest: false,
    supportsSync: false,
    supportsWebhook: false,
    supportsOAuth: false,
    credentialScope: "organization",
    setupRequirements: ["123Loadboard API access", "Vendor-issued API credentials"],
    notImplementedReason: "No confirmed API access or connector exists in this codebase yet.",
  },

  // ---------------------------------------------------------------------
  // Telematics / ELD
  // ---------------------------------------------------------------------
  {
    id: "motive",
    name: "Motive",
    description: "ELD and telematics sync -- vehicle location, ELD status, odometer, driver availability.",
    category: "telematics",
    connectionType: "oauth2",
    capabilities: ["vehicle_location", "eld_status", "odometer", "driver_availability"],
    implemented: false,
    supportsTest: false,
    supportsSync: false,
    supportsWebhook: false,
    supportsOAuth: true,
    credentialScope: "organization",
    setupRequirements: [
      "A registered Motive developer application",
      "OAuth Client ID / Client Secret",
      "An explicit external-vehicle-id -> truck_id and external-driver-id -> driver_id mapping before any sync writes canonical data",
    ],
    notImplementedReason: "No Motive connector is implemented yet. When it is, external IDs will be mapped explicitly to truck_id/driver_id -- never auto-matched by name.",
  },
  {
    id: "samsara",
    name: "Samsara",
    description: "ELD and telematics sync -- vehicle location, ELD status, odometer, driver availability.",
    category: "telematics",
    connectionType: "api_key",
    capabilities: ["vehicle_location", "eld_status", "odometer", "driver_availability"],
    implemented: false,
    supportsTest: false,
    supportsSync: false,
    supportsWebhook: false,
    supportsOAuth: false,
    credentialScope: "organization",
    setupRequirements: [
      "A Samsara API token",
      "An explicit external-vehicle-id -> truck_id and external-driver-id -> driver_id mapping before any sync writes canonical data",
    ],
    notImplementedReason: "No Samsara connector is implemented yet. When it is, external IDs will be mapped explicitly to truck_id/driver_id -- never auto-matched by name.",
  },

  // ---------------------------------------------------------------------
  // Carrier compliance / risk
  // ---------------------------------------------------------------------
  {
    id: "rmis",
    name: "RMIS",
    description: "Carrier onboarding and monitoring -- authority, insurance, safety.",
    category: "compliance",
    connectionType: "manual",
    capabilities: ["carrier_authority", "insurance_verification", "safety_monitoring"],
    implemented: false,
    supportsTest: false,
    supportsSync: false,
    supportsWebhook: false,
    supportsOAuth: false,
    credentialScope: "organization",
    setupRequirements: ["RMIS-approved API access", "Vendor-issued API credentials"],
    notImplementedReason: "No RMIS connector exists in this codebase. Any future sync would record source + last-synced timestamp rather than silently overwriting canonical carrier compliance data.",
  },
  {
    id: "highway",
    name: "Highway",
    description: "Carrier identity and fraud monitoring.",
    category: "compliance",
    connectionType: "manual",
    capabilities: ["identity_verification", "fraud_monitoring"],
    implemented: false,
    supportsTest: false,
    supportsSync: false,
    supportsWebhook: false,
    supportsOAuth: false,
    credentialScope: "organization",
    setupRequirements: ["Highway-approved partner access", "Vendor-issued API credentials"],
    notImplementedReason: "No Highway connector exists in this codebase.",
  },
  {
    id: "carrier411",
    name: "Carrier411",
    description: "Carrier risk and safety scores.",
    category: "compliance",
    connectionType: "manual",
    capabilities: ["risk_scoring", "safety_scores"],
    implemented: false,
    supportsTest: false,
    supportsSync: false,
    supportsWebhook: false,
    supportsOAuth: false,
    credentialScope: "organization",
    setupRequirements: ["Carrier411 API access", "Vendor-issued API credentials"],
    notImplementedReason: "No Carrier411 connector exists in this codebase.",
  },
];

export const PROVIDER_BY_ID: Record<ProviderId, ProviderDefinition> = Object.fromEntries(PROVIDERS.map((p) => [p.id, p])) as Record<ProviderId, ProviderDefinition>;

export const CATEGORY_LABEL: Record<IntegrationCategory, string> = {
  load_boards: "Load Boards",
  accounting: "Accounting",
  communications: "Communications",
  billing: "Billing",
  telematics: "Telematics / ELD",
  compliance: "Carrier Compliance",
};

export function isProviderId(value: string): value is ProviderId {
  return value in PROVIDER_BY_ID;
}
