export class SetupPackageResourceNotFoundError extends Error {
  constructor() {
    super("Setup package resource not found.");
    this.name = "SetupPackageResourceNotFoundError";
  }
}
