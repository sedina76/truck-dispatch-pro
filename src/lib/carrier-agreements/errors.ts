export class ExecutedAgreementResourceNotFoundError extends Error {
  constructor() {
    super("Executed agreement not found.");
    this.name = "ExecutedAgreementResourceNotFoundError";
  }
}

export class ExecutedAgreementAccessDeniedError extends Error {
  constructor() {
    super("Executed agreement access denied.");
    this.name = "ExecutedAgreementAccessDeniedError";
  }
}
