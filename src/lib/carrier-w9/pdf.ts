import "server-only";
import { readFile } from "node:fs/promises";
import path from "node:path";
import { PDFDocument, StandardFonts, rgb } from "pdf-lib";
import type { CarrierW9Row } from "./types";

// =============================================================================
// Official-form PDF strategy (2N.2 section 15/16): FILLS the real IRS Form
// W-9 (Rev. March 2024) AcroForm rather than recreating the form visually,
// per the phase's stated strong preference.
//
// Empirically verified before writing this file, not assumed:
//   - Downloaded directly from https://www.irs.gov/pub/irs-pdf/fw9.pdf and
//     inspected with this exact pdf-lib version. Result: pdf-lib logs
//     "Removing XFA form data as pdf-lib does not support reading or
//     writing XFA" on load -- the live PDF DOES carry an XFA packet
//     alongside its AcroForm layer (a common IRS "hybrid" LiveCycle
//     export), confirming the prior architecture audit's XFA concern was
//     correct. pdf-lib strips it automatically and non-destructively; the
//     AcroForm layer beneath -- the one virtually every non-Adobe-XFA
//     viewer (Chrome, most PDF readers, and Acrobat itself when it falls
//     back to AcroForm rendering) actually uses -- loads and fills
//     correctly.
//   - Exactly 23 AcroForm fields exist: 15 text fields (f1_01..f1_15) and
//     8 checkboxes (7 for line 3a's classification + 1 for the NEW line
//     3b foreign-partners checkbox this exact revision introduced). Field
//     purposes below were derived from each widget's live rectangle
//     (position on the page), independently cross-checked by rendering a
//     filled test copy and visually inspecting it -- not guessed from
//     field names alone.
//   - There is NO fillable field for the Part II "Sign Here" signature/
//     date line -- the official form leaves that as blank space for a
//     wet or Acrobat-native signature. This module draws the certifier's
//     typed name and certification date directly onto page 1 at that
//     line's coordinates (derived from a coordinate-grid overlay render
//     of the real page, read directly, not estimated from memory).
//
// Per the approved design (section 17), the final PDF contains ONLY the
// legally appropriate W-9 information and the certification signature/
// date -- no internal notes, DB ids, hashes, storage paths, or reveal
// reasons are ever drawn onto it. Real-viewer verification (Chrome,
// Acrobat Reader) was NOT performed in this environment -- see this
// phase's report, item "24. XFA findings" / "50. Known limitations": this
// is honestly reported as part of required post-apply acceptance, not
// claimed here.
// =============================================================================

const TEMPLATE_PATH = path.join(process.cwd(), "src/lib/carrier-w9/assets/irs-form-w9-2024-03.pdf");

// Live widget field name -> purpose map (see header comment for how this
// was derived and verified).
const FIELD = {
  nameOnTaxReturn: "f1_01[0]", // Line 1
  businessName: "f1_02[0]", // Line 2
  llcClassificationLetter: "f1_03[0]", // Line 3a LLC classification (C/S/P)
  otherDescription: "f1_04[0]", // Line 3a "Other" description
  exemptPayeeCode: "f1_05[0]", // Line 4
  fatcaExemptionCode: "f1_06[0]", // Line 4
  addressLine1: "f1_07[0]", // Line 5
  cityStateZip: "f1_08[0]", // Line 6
  requesterNameAddress: "f1_09[0]", // Optional boxed area
  accountNumbers: "f1_10[0]", // Line 7
  ssn1: "f1_11[0]", // Part I SSN group 1 (3 digits)
  ssn2: "f1_12[0]", // Part I SSN group 2 (2 digits)
  ssn3: "f1_13[0]", // Part I SSN group 3 (4 digits)
  ein1: "f1_14[0]", // Part I EIN group 1 (2 digits)
  ein2: "f1_15[0]", // Part I EIN group 2 (7 digits)
} as const;

// Line 3a classification checkboxes, in the exact left-to-right/top-to-
// bottom order the live widgets appear in: Individual/sole proprietor,
// C corporation, S corporation, Partnership, Trust/estate, LLC, Other.
const CLASSIFICATION_CHECKBOX_INDEX: Record<string, number> = {
  individual_sole_proprietor: 0,
  c_corporation: 1,
  s_corporation: 2,
  partnership: 3,
  trust_estate: 4,
  llc: 5,
  other: 6,
};
const FOREIGN_PARTNERS_CHECKBOX_NAME = "c1_2[0]"; // Line 3b

export type GeneratedW9 = { bytes: Uint8Array; pageCount: number };

// Phase 2Q.2B: widened from CarrierW9Row to exactly the fields this
// renderer actually reads, so it can be reused as-is for a Driver W-9
// (driver_w9s carries the identical field names/types by design -- see
// that table's own migration comment) without copy/pasting a second W-9
// PDF renderer. This is the ONE and only IRS Form W-9 filler in the
// codebase, for either subject.
export type W9FormFields = Pick<
  CarrierW9Row,
  | "name_on_tax_return" | "business_name" | "tax_classification" | "llc_classification" | "other_classification_description"
  | "has_foreign_partners_owners" | "exempt_payee_code" | "fatca_exemption_code" | "address_line1" | "city" | "state" | "postal_code"
  | "requester_name_address" | "account_numbers" | "tin_type" | "certified_name"
>;

export async function renderCarrierW9Pdf(
  w9: W9FormFields,
  plaintextTin: string,
  certifiedAt: Date
): Promise<GeneratedW9> {
  const templateBytes = await readFile(TEMPLATE_PATH);
  const pdf = await PDFDocument.load(templateBytes);

  // The official template is 6 pages: page 1 is the fillable form itself,
  // pages 2-6 are the IRS's own General Instructions (reference material,
  // not part of what a requester/broker needs from a completed W-9). All
  // 23 AcroForm fields live on page 1 only (confirmed live) -- removing
  // the instruction pages here, before any field access, is safe and
  // produces a clean, single-page completed form.
  for (let i = pdf.getPageCount() - 1; i >= 1; i--) pdf.removePage(i);

  const form = pdf.getForm();

  const text = (short: string, value: string | null | undefined) => {
    const field = form.getFieldMaybe(findFullName(form, short));
    if (field && "setText" in field) (field as import("pdf-lib").PDFTextField).setText(value ?? "");
  };
  const check = (short: string, checked: boolean) => {
    const field = form.getFieldMaybe(findFullName(form, short));
    if (field && "check" in field) {
      if (checked) (field as import("pdf-lib").PDFCheckBox).check();
      else (field as import("pdf-lib").PDFCheckBox).uncheck();
    }
  };
  const checkClassificationBox = (index: number) => {
    const boxes = form.getFields().filter((f) => /Boxes3a-b_ReadOrder\[0\]\.c1_1\[\d\]$/.test(f.getName()));
    boxes.sort((a, b) => Number(a.getName().match(/c1_1\[(\d)\]/)![1]) - Number(b.getName().match(/c1_1\[(\d)\]/)![1]));
    const target = boxes[index];
    if (target && "check" in target) (target as import("pdf-lib").PDFCheckBox).check();
  };

  text(FIELD.nameOnTaxReturn, w9.name_on_tax_return);
  text(FIELD.businessName, w9.business_name);
  if (w9.tax_classification) {
    const index = CLASSIFICATION_CHECKBOX_INDEX[w9.tax_classification];
    if (index !== undefined) checkClassificationBox(index);
  }
  text(FIELD.llcClassificationLetter, w9.llc_classification);
  text(FIELD.otherDescription, w9.other_classification_description);
  check(FOREIGN_PARTNERS_CHECKBOX_NAME, w9.has_foreign_partners_owners);
  text(FIELD.exemptPayeeCode, w9.exempt_payee_code);
  text(FIELD.fatcaExemptionCode, w9.fatca_exemption_code);
  text(FIELD.addressLine1, w9.address_line1);
  text(FIELD.cityStateZip, [w9.city, w9.state, w9.postal_code].filter(Boolean).join(", "));
  text(FIELD.requesterNameAddress, w9.requester_name_address);
  text(FIELD.accountNumbers, w9.account_numbers);

  const digits = plaintextTin.replace(/[^0-9]/g, "");
  if (w9.tin_type === "ssn" && digits.length === 9) {
    text(FIELD.ssn1, digits.slice(0, 3));
    text(FIELD.ssn2, digits.slice(3, 5));
    text(FIELD.ssn3, digits.slice(5, 9));
  } else if (w9.tin_type === "ein" && digits.length === 9) {
    text(FIELD.ein1, digits.slice(0, 2));
    text(FIELD.ein2, digits.slice(2, 9));
  }

  form.updateFieldAppearances();

  // Part II signature line: the official form has no fillable field here
  // (see header comment) -- draw the certifier's typed name and
  // certification date directly, at coordinates read off a real
  // coordinate-grid render of this exact page (see header comment).
  // Nothing else is drawn on the PDF: no internal ids, no hashes, no
  // system metadata, per the approved design.
  //
  // Alignment repair: the original (x:105/395, y:214) values placed both
  // strings a full line ABOVE the "Sign Here" box entirely, overlapping
  // the last line of Certification instructions and the box's own top
  // border -- confirmed by rendering an actual filled PDF at 300dpi and
  // inspecting it pixel-by-pixel (not assumed). The "Sign Here" box's
  // printed labels ("Signature of" / "U.S. person" and "Date") sit on two
  // internal text rows spanning y=203 (upper) to y=195 (lower) in this
  // exact template; the empty space to fill is beside the lower row, not
  // above the box. Re-measured with a coordinate-grid overlay render:
  // "U.S. person" ends at x=185, "Date" ends at x=445 -- x:200/460 clear
  // both labels with comfortable margin. y:195 sits on that same lower
  // row's baseline, inside the box, below the "Signature of" line and
  // above the box's bottom border (y=190) -- verified with no overlap
  // against the certification text, the top border, the "Signature of
  // U.S. person" label, or the "Date" label at 11pt/10pt (unchanged font
  // sizes; the fix was purely positional, not a scaling problem).
  const page = pdf.getPages()[0];
  const font = await pdf.embedFont(StandardFonts.Helvetica);
  page.drawText(w9.certified_name ?? "", { x: 200, y: 195, size: 11, font, color: rgb(0.07, 0.15, 0.24) });
  page.drawText(formatCertifiedDate(certifiedAt), { x: 460, y: 195, size: 10, font, color: rgb(0.07, 0.15, 0.24) });

  // Flatten: this is a FINAL, immutable, already-certified document -- the
  // recipient must never be able to re-edit the fields (2N.2 section 15's
  // "whether flattening is safe" -- yes, deliberately, for exactly this
  // reason).
  form.flatten();

  const bytes = await pdf.save({ useObjectStreams: true });
  return { bytes, pageCount: pdf.getPageCount() };
}

function findFullName(form: ReturnType<PDFDocument["getForm"]>, shortName: string): string {
  const match = form.getFields().find((f) => f.getName().endsWith(shortName));
  return match ? match.getName() : shortName;
}

function formatCertifiedDate(date: Date) {
  return new Intl.DateTimeFormat("en-US", { month: "2-digit", day: "2-digit", year: "numeric", timeZone: "UTC" }).format(date);
}
