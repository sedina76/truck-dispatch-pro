export type StorageUploadErrorLike = {
  name?: string;
  message?: string;
  status?: number;
  statusCode?: number | string;
  code?: string;
};

export type StorageObjectConfirmation = "matching" | "absent" | "mismatch" | "unknown";
export type BoundedStorageUploadResult = {
  ok: boolean;
  attempts: number;
  resolution: "uploaded" | "confirmed" | "failed";
};

export function storageUploadErrorStatus(error: StorageUploadErrorLike): number | null {
  const value = error.status ?? error.statusCode;
  const parsed = typeof value === "number" ? value : Number(value);
  return Number.isFinite(parsed) ? parsed : null;
}

export function isRetryableStorageUploadError(error: StorageUploadErrorLike): boolean {
  const status = storageUploadErrorStatus(error);
  if (status === 429 || (status !== null && status >= 500 && status <= 599)) return true;
  if (status !== null && status >= 400 && status <= 499) return false;

  const message = `${error.name ?? ""} ${error.message ?? ""} ${error.code ?? ""}`.toLowerCase();
  if (/already exists|duplicate|invalid|malformed|mime|content.?type|payload too large|too large|unauthorized|forbidden|not found/.test(message)) return false;
  return /fetch failed|network|timeout|timed out|econnreset|connection reset|socket hang up|eai_again|enotfound|connection aborted/.test(message);
}

export async function runBoundedStorageUpload(params: {
  upload: (attempt: number) => Promise<StorageUploadErrorLike | null>;
  confirmObject: () => Promise<StorageObjectConfirmation>;
  delay: () => Promise<void>;
  onAttemptError: (error: StorageUploadErrorLike, attempt: number) => void;
  onRetrySucceeded?: () => void;
  onConfirmedAfterResponseFailure?: (attempt: number) => void;
}): Promise<BoundedStorageUploadResult> {
  for (let attempt = 1; attempt <= 2; attempt += 1) {
    const error = await params.upload(attempt);
    if (!error) {
      if (attempt === 2) params.onRetrySucceeded?.();
      return { ok: true, attempts: attempt, resolution: "uploaded" };
    }
    params.onAttemptError(error, attempt);
    if (!isRetryableStorageUploadError(error)) return { ok: false, attempts: attempt, resolution: "failed" };

    const confirmation = await params.confirmObject();
    if (confirmation === "matching") {
      params.onConfirmedAfterResponseFailure?.(attempt);
      return { ok: true, attempts: attempt, resolution: "confirmed" };
    }
    if (confirmation !== "absent" || attempt === 2) return { ok: false, attempts: attempt, resolution: "failed" };
    await params.delay();
  }
  return { ok: false, attempts: 2, resolution: "failed" };
}
