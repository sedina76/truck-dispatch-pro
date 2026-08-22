export function carrierSetupPackageFilename(legalName: string, date: string, version: number): string {
  const carrier = legalName
    .normalize("NFKD")
    .replace(/[^A-Za-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 80) || "Carrier";
  return `${carrier}-Carrier-Setup-Package-${date}-v${version}.pdf`;
}
