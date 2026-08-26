// Mirrors src/lib/carrier-setup-packages/filename.ts's exact sanitization
// rules -- same reasoning, different label. Not reused directly: the two
// features' filenames are independent by design (see types.ts's header
// comment on why this feature duplicates rather than imports).
export function brokerPacketFilename(brokerLegalName: string, date: string, version: number): string {
  const broker = brokerLegalName
    .normalize("NFKD")
    .replace(/[^A-Za-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 80) || "Broker";
  return `${broker}-Broker-Packet-${date}-v${version}.pdf`;
}
