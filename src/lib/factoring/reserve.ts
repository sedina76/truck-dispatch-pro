// How much of the reserve the factor still owes the carrier -- the number
// the invoice screen shows as "Reserve Still Due" and uses to decide whether
// "Record Reserve Release" is offered.
//
// Why not just reserve - released ("outstanding_reserve")? With "Deduct fee
// from reserve" the factor keeps the fee out of the reserve, so a complete,
// correct settlement releases (reserve - fee) and the raw figure stays at
// the fee amount forever (e.g. $30 on a $1,000 / 90-3-10 invoice). The
// carrier is owed: (face - fee - other fees) - funded - already released,
// never more than what's left of the reserve. Matches the reconciliation
// rule in migration 0160.
export function reserveStillDue(fi: {
  invoiceFaceValue: number;
  factoringFeeAmount: number;
  otherFees: number;
  reserveAmount: number;
  reserveReleasedAmount: number;
  actualFundedAmount: number | null;
  expectedFundingAmount: number;
}): number {
  const cents = (n: number) => Math.round(Number(n || 0) * 100);
  const netProceeds = cents(fi.invoiceFaceValue) - cents(fi.factoringFeeAmount) - cents(fi.otherFees);
  const funded = cents(fi.actualFundedAmount ?? fi.expectedFundingAmount);
  const owed = netProceeds - funded - cents(fi.reserveReleasedAmount);
  const reserveLeft = cents(fi.reserveAmount) - cents(fi.reserveReleasedAmount);
  return Math.max(0, Math.min(owed, reserveLeft)) / 100;
}
