// Shared upload constraints -- deliberately its own tiny module with no
// "use server"/"server-only" directive so BOTH the server action
// (pod-actions.ts) and the client upload form (upload-document-form.tsx)
// import the exact SAME numbers, never two constants that could drift
// apart. The server-side check in pod-actions.ts remains the authoritative
// one (a client-side check alone is never trustworthy); this also lets the
// client pre-check file size BEFORE ever sending the request, which sidesteps
// a real Next.js platform limitation found live: files near/above ~15MB
// hit Next's own generic Server Action body-size error (a safe, non-
// crashing but genericly-worded failure) rather than reaching this app's
// own "File is too large" check at all, even with experimental.
// serverActions.bodySizeLimit configured higher in next.config.ts. Catching
// it client-side, before the oversized request is ever sent, avoids that
// platform boundary entirely.
export const MAX_UPLOAD_BYTES = 15 * 1024 * 1024;
export const ALLOWED_UPLOAD_MIME_TYPES = ["application/pdf", "image/jpeg", "image/png"] as const;
