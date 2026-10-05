// Standard dispatch agreements every subscribing dispatch company can add
// with one click (Carrier Onboarding -> Agreement Templates). They are
// copied into the company's own DRAFT templates with its legal name and
// home state filled in; the company reviews / edits them and publishes
// them itself (publishing locks the text, as for any template).
// Pure -- no I/O.
//
// Written for the money flow this app runs: the broker pays the carrier
// (or its factor) directly and the carrier pays the dispatch company a fee
// on a weekly dispatch fee invoice. Not legal advice -- the page tells every
// company to have a transportation attorney review before publishing.

export type StarterClause = { title: string; body: string; requiresInitials: boolean };
export type StarterTemplate = {
  key: string;
  name: string;
  description: string;
  requiredForOnboarding: boolean;
  requiresSignerTitle: boolean;
  clauses: StarterClause[];
};

/** Left in the text when the company has no state on file; publishing is refused until it is replaced. */
export const STATE_BLANK = "[STATE]";

const C = "{{company}}";
const S = "{{state}}";

export const STARTER_TEMPLATES: StarterTemplate[] = [
  {
    key: "dispatch_service_agreement",
    name: "Dispatch Service Agreement",
    description: `Terms under which ${C} finds and books freight for the Carrier.`,
    requiredForOnboarding: true,
    requiresSignerTitle: true,
    clauses: [
      {
        title: "1. Parties and Purpose",
        body: `This Dispatch Service Agreement is between ${C} ("Dispatcher") and the motor carrier signing below ("Carrier"). Carrier holds its own USDOT number and operating authority and engages Dispatcher to find freight, negotiate rates, book loads and handle related paperwork on Carrier's behalf. Dispatcher is a dispatch service, not a freight broker, and is not a party to any contract of carriage.`,
        requiresInitials: false,
      },
      {
        title: "2. Carrier's Right to Decide",
        body: "Carrier alone decides which loads it accepts. Dispatcher will present each load with its rate, lane, pickup and delivery times before booking, and will book only loads Carrier has approved, by phone, text, email or in Dispatcher's dispatch system. Carrier keeps full control of its drivers, equipment, routes, hours of service and safety.",
        requiresInitials: false,
      },
      {
        title: "3. Dispatch Fee",
        body: "Carrier pays Dispatcher a dispatch fee equal to the percentage of the gross line-haul rate recorded for Carrier in Dispatcher's dispatch system at the time each load is booked, unless a different fee is agreed in writing for a specific load. The fee is earned when the load is delivered. Fuel surcharge, detention, layover, lumper reimbursement and other accessorials are excluded from the fee unless Carrier agrees otherwise in writing.",
        requiresInitials: true,
      },
      {
        title: "4. Invoicing and Payment",
        body: "The broker or shipper pays Carrier, or Carrier's factoring company, directly; Dispatcher does not collect freight payments for Carrier unless agreed in writing. Dispatcher invoices Carrier weekly for the dispatch fees on loads delivered that week, and Carrier pays each invoice within 7 days. Unpaid balances more than 15 days past due may pause dispatch service until paid. If a broker never pays for a load despite reasonable collection efforts, the dispatch fee for that load is waived.",
        requiresInitials: true,
      },
      {
        title: "5. Dispatcher's Duties",
        body: "Dispatcher will: search for and negotiate loads in Carrier's interest; send Carrier the rate confirmation for every booked load; complete broker setup packets with Carrier's documents; track loads and keep brokers updated; prepare and send Carrier's freight invoice and billing paperwork (rate confirmation, bill of lading, proof of delivery) to the broker or Carrier's factoring company when Carrier has asked Dispatcher to do so; and keep Carrier's business information confidential.",
        requiresInitials: false,
      },
      {
        title: "6. Carrier's Duties",
        body: "Carrier will: keep its operating authority, USDOT registration and insurance active and send updated certificates when they renew (at least $1,000,000 auto liability and $100,000 cargo, or more if a broker requires it); use qualified, properly licensed drivers; follow all federal and state rules, including hours of service; deliver loads as booked; and tell Dispatcher at once about delays, accidents, cargo claims, inspections or citations on a booked load.",
        requiresInitials: false,
      },
      {
        title: "7. Costs Carrier Pays",
        body: "Carrier pays all costs of operating its business, including fuel, tolls, permits, scale tickets, maintenance, repairs, driver pay, insurance and taxes. If Dispatcher advances any cost for Carrier (for example a fuel advance or a repair), Carrier repays it on the next weekly invoice.",
        requiresInitials: false,
      },
      {
        title: "8. Paperwork",
        body: "Carrier will upload or send the signed bill of lading and proof of delivery within 24 hours of delivery, using the driver app or email. Delayed paperwork delays the broker's payment to Carrier; Dispatcher is not responsible for that delay.",
        requiresInitials: false,
      },
      {
        title: "9. Independent Contractor",
        body: "Carrier is an independent business. Nothing in this Agreement makes Carrier or its drivers employees, partners or agents of Dispatcher, except for the limited authority Carrier grants in the Limited Authorization to Act for Carrier.",
        requiresInitials: false,
      },
      {
        title: "10. Liability and Claims",
        body: "Carrier is solely responsible for its drivers, equipment, cargo in its care, accidents, cargo loss or damage, fines and penalties. Dispatcher is not liable for any claim arising from Carrier's operations, and its total liability under this Agreement is limited to the dispatch fees Carrier paid in the 3 months before the claim. Each party will defend and hold the other harmless from claims caused by its own negligence or breach.",
        requiresInitials: true,
      },
      {
        title: "11. No Double Brokering or Back-Solicitation",
        body: "Carrier will haul every load booked through Dispatcher with its own authority and equipment and will not re-broker or hand off any such load. For 6 months after a load, Carrier will not avoid the dispatch fee by booking directly with a broker or shipper Dispatcher introduced, on that same lane, without paying the fee.",
        requiresInitials: true,
      },
      {
        title: "12. Term and Termination",
        body: "This Agreement starts on the date signed and continues until either party ends it with 7 days' written notice (email is enough). Either party may end it at once for the other's material breach, fraud or loss of operating authority or insurance. Fees for loads booked before the end date remain due.",
        requiresInitials: false,
      },
      {
        title: "13. Governing Law and Entire Agreement",
        body: `This Agreement is governed by the laws of the State of ${S}. It is the entire agreement on dispatch services, may be changed only in writing signed by both parties, and an electronic signature has the same effect as a handwritten one. If any part is found unenforceable, the rest stays in effect.`,
        requiresInitials: false,
      },
    ],
  },
  {
    key: "limited_authorization",
    name: "Limited Authorization to Act for Carrier",
    description: `What ${C} may sign and send for the Carrier.`,
    requiredForOnboarding: true,
    requiresSignerTitle: true,
    clauses: [
      {
        title: "1. Authority Granted",
        body: `Carrier authorizes ${C} ("Dispatcher") to act for Carrier, in Carrier's name, only to: (a) complete and sign broker and shipper setup packets using Carrier's documents; (b) accept and sign rate confirmations for loads Carrier has approved; (c) send Carrier's W-9, operating authority, certificate of insurance and notice of assignment to brokers; (d) prepare and send Carrier's freight invoices with the rate confirmation, bill of lading and proof of delivery to the broker or to Carrier's factoring company; and (e) talk with brokers and factors about load status and payment on Carrier's behalf.`,
        requiresInitials: false,
      },
      {
        title: "2. Limits",
        body: "Dispatcher may not: receive or deposit freight payments for Carrier, sign checks, take on debt or open accounts in Carrier's name, change Carrier's bank or remittance details with any broker or factor, or accept a load Carrier has not approved. Any change to where Carrier is paid must come from Carrier directly.",
        requiresInitials: true,
      },
      {
        title: "3. Carrier Stays Responsible",
        body: "Carrier is bound by documents Dispatcher signs within this authority, and remains fully responsible for performing every load. Carrier will keep the documents it gives Dispatcher accurate and current.",
        requiresInitials: false,
      },
      {
        title: "4. Ending the Authorization",
        body: "This authorization lasts as long as the Dispatch Service Agreement and ends automatically when it ends. Carrier may also revoke it at any time by written notice to Dispatcher; revocation does not undo documents already signed.",
        requiresInitials: false,
      },
    ],
  },
  {
    key: "tracking_communications_consent",
    name: "Tracking & Communications Consent",
    description: "How load tracking and messages work.",
    requiredForOnboarding: true,
    requiresSignerTitle: false,
    clauses: [
      {
        title: "1. Location Tracking",
        body: `Carrier agrees that its drivers will run Dispatcher's driver app (or share location by another method Dispatcher accepts) while on a load booked through ${C} ("Dispatcher"). Location is used only to estimate arrival times, warn about delays and weather, record arrival and departure at stops, and answer broker check calls. Tracking applies only while a load is active, not when a driver is off duty or between loads.`,
        requiresInitials: false,
      },
      {
        title: "2. Sharing",
        body: "Dispatcher may share a load's location, estimated arrival and status with the broker and shipper for that load. Dispatcher will not sell location data or share it with anyone else, except where the law requires.",
        requiresInitials: false,
      },
      {
        title: "3. Driver Notice",
        body: "Carrier will tell each driver it assigns to Dispatcher's loads about this tracking and get any consent the law requires from them.",
        requiresInitials: false,
      },
      {
        title: "4. Messages",
        body: "Carrier agrees to receive load offers, rate confirmations, invoices and service messages from Dispatcher by phone, text message, email and in-app notifications at the contacts Carrier provides. Message and data rates may apply. Carrier can opt out of marketing messages at any time; service messages about active loads continue while the Dispatch Service Agreement is in effect.",
        requiresInitials: false,
      },
    ],
  },
];

const STATE_NAMES: Record<string, string> = {
  AL: "Alabama", AK: "Alaska", AZ: "Arizona", AR: "Arkansas", CA: "California", CO: "Colorado", CT: "Connecticut", DE: "Delaware",
  DC: "District of Columbia", FL: "Florida", GA: "Georgia", HI: "Hawaii", ID: "Idaho", IL: "Illinois", IN: "Indiana", IA: "Iowa",
  KS: "Kansas", KY: "Kentucky", LA: "Louisiana", ME: "Maine", MD: "Maryland", MA: "Massachusetts", MI: "Michigan", MN: "Minnesota",
  MS: "Mississippi", MO: "Missouri", MT: "Montana", NE: "Nebraska", NV: "Nevada", NH: "New Hampshire", NJ: "New Jersey",
  NM: "New Mexico", NY: "New York", NC: "North Carolina", ND: "North Dakota", OH: "Ohio", OK: "Oklahoma", OR: "Oregon",
  PA: "Pennsylvania", RI: "Rhode Island", SC: "South Carolina", SD: "South Dakota", TN: "Tennessee", TX: "Texas", UT: "Utah",
  VT: "Vermont", VA: "Virginia", WA: "Washington", WV: "West Virginia", WI: "Wisconsin", WY: "Wyoming",
};

/** "TX" / "texas" / "Texas" -> "Texas"; anything unknown -> the [STATE] blank. */
export function stateName(raw: string | null | undefined): string {
  const v = (raw ?? "").trim();
  if (!v) return STATE_BLANK;
  const byCode = STATE_NAMES[v.toUpperCase()];
  if (byCode) return byCode;
  const byName = Object.values(STATE_NAMES).find((n) => n.toLowerCase() === v.toLowerCase());
  return byName ?? STATE_BLANK;
}

/** The starter template with this company's name and state filled in. */
export function renderStarter(t: StarterTemplate, company: { name: string; state: string | null }): StarterTemplate {
  const name = company.name.trim() || "the Dispatcher";
  const fill = (s: string) => s.replaceAll(C, name).replaceAll(S, stateName(company.state));
  return { ...t, description: fill(t.description), clauses: t.clauses.map((c) => ({ ...c, title: fill(c.title), body: fill(c.body) })) };
}

/** Text still holding a blank the company must fill before publishing. */
export function unfilledBlanks(texts: string[]): string[] {
  const found = new Set<string>();
  for (const t of texts) for (const m of t.matchAll(/\[[A-Z][A-Z _]{1,30}\]|\{\{[a-z_]+\}\}/g)) found.add(m[0]);
  return [...found];
}

export function clauseKey(title: string): string {
  return title.toLowerCase().replace(/^\d+\.\s*/, "").replace(/[^a-z0-9]+/g, "_").replace(/^_+|_+$/g, "");
}
